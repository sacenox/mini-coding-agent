//! OpenAI Responses API streaming adapter. The wire format behind every
//! customProvider with api "openai-responses".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const json = @import("../json.zig");

fn streamIndex(obj: std.json.ObjectMap, fallback: usize) usize {
    const v = obj.get("output_index") orelse return fallback;
    return switch (v) {
        .integer => |n| if (n < 0 or n > api.max_stream_index) fallback else @intCast(n),
        else => fallback,
    };
}

// ---- request building -----------------------------------------------------

fn writeInput(w: *std.Io.Writer, msg: types.Message) !void {
    switch (msg) {
        .tool_result => |t| {
            try w.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try json.writeString(w, t.tool_call_id);
            try w.writeAll(",\"output\":");
            try json.writeString(w, t.text);
            try w.writeByte('}');
        },
        .user => |u| {
            try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try json.writeString(w, u.content);
            try w.writeAll("}]}");
        },
        .assistant => |am| {
            var first = true;
            for (am.content.items) |block| switch (block) {
                .text => |t| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try json.writeString(w, t);
                    try w.writeAll("}]}");
                },
                .tool_call => |c| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try w.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try json.writeString(w, c.id);
                    try w.writeAll(",\"name\":");
                    try json.writeString(w, c.name);
                    try w.writeAll(",\"arguments\":");
                    try json.writeString(w, api.argumentsOrObject(c.arguments));
                    try w.writeByte('}');
                },
                .thinking => {},
            };
        },
    }
}

fn buildBody(req: api.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(req.scratch);
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try json.writeString(w, req.model.id);
    try w.writeAll(",\"stream\":true,\"store\":false");
    if (req.system_prompt.len > 0) {
        try w.writeAll(",\"instructions\":");
        try json.writeString(w, req.system_prompt);
    }
    // OpenAI Responses rejects max_output_tokens below 16.
    if (req.model.max_tokens > 0) {
        try w.writeAll(",\"max_output_tokens\":");
        try json.writeNum(w, if (req.model.max_tokens > 16) req.model.max_tokens else 16);
    }
    if (req.effort.len > 0 and !std.mem.eql(u8, req.effort, "off")) {
        try w.writeAll(",\"reasoning\":{\"effort\":");
        try json.writeString(w, req.effort);
        try w.writeByte('}');
    }

    try w.writeAll(",\"input\":[");
    for (req.messages, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        try writeInput(w, msg);
    }
    try w.writeByte(']');

    try api.writeTools(w, req.scratch, req.tools_json, .{
        .open = ",\"tools\":[",
        .entry = "{\"type\":\"function\",",
        .params_key = "parameters",
        .entry_close = "}",
        .close = "]",
    });
    try w.writeByte('}');
    return out.written();
}

// ---- streaming state ------------------------------------------------------

const State = struct {
    req: api.Request,
    sink: api.Sink,
    arena: *std.heap.ArenaAllocator,
    msg: *types.AssistantMessage,
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(api.Call) = .empty,
    usage: types.Usage = .{},
    status: ?[]const u8 = null,
    incomplete: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
    /// Set by `run` when the stream did not run to completion.
    failed: bool = false,

    pub fn handle(st: *State, obj: std.json.ObjectMap) !void {
        const event_type = api.stringField(obj, "type") orelse "";

        if (std.mem.eql(u8, event_type, "error")) {
            const message = api.stringField(obj, "message") orelse
                api.errorMessage(obj, "error") orelse "stream: provider error";
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
            return;
        }

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (api.objField(obj, "response")) |resp| {
                if (st.msg.response_id == null) {
                    if (api.stringField(resp, "id")) |id| {
                        st.msg.response_id = try st.req.pers.dupe(u8, id);
                    }
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = api.objField(obj, "item") orelse return;
            if (!std.mem.eql(u8, api.stringField(item, "type") orelse "", "function_call")) return;
            const index = streamIndex(obj, st.calls.items.len);
            const call = try api.blockAt(api.Call, &st.calls, st.req.pers, @intCast(index));
            if (api.stringField(item, "call_id")) |id| call.id = try st.req.pers.dupe(u8, id);
            try call.announce(st.req.pers, st.sink, api.stringField(item, "name") orelse "");
            return;
        }

        if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            if (api.stringField(obj, "delta")) |s| {
                try st.text.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .text = s });
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            if (api.stringField(obj, "delta")) |s| {
                try st.reasoning.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .reasoning = s });
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const index = streamIndex(obj, st.calls.items.len);
            if (index < st.calls.items.len) {
                if (api.stringField(obj, "delta")) |s| try st.calls.items[index].args.appendSlice(st.req.pers, s);
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const index = streamIndex(obj, st.calls.items.len);
            if (index < st.calls.items.len) {
                if (api.stringField(obj, "arguments")) |s| {
                    st.calls.items[index].args.clearRetainingCapacity();
                    try st.calls.items[index].args.appendSlice(st.req.pers, s);
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = api.objField(obj, "item") orelse return;
            if (!std.mem.eql(u8, api.stringField(item, "type") orelse "", "function_call")) return;
            const index = streamIndex(obj, st.calls.items.len);
            if (index >= st.calls.items.len) return;
            const call = &st.calls.items[index];
            if (api.stringField(item, "call_id")) |id| call.id = try st.req.pers.dupe(u8, id);
            if (api.stringField(item, "name")) |name| call.name = try st.req.pers.dupe(u8, name);
            if (!call.started and call.name.len > 0) {
                call.started = true;
                st.sink.emit(.{ .tool_start = call.name });
            }
            if (call.args.items.len == 0) {
                if (api.stringField(item, "arguments")) |s| try call.args.appendSlice(st.req.pers, s);
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            const resp = api.objField(obj, "response") orelse return;
            if (api.stringField(resp, "status")) |s| st.status = try st.req.pers.dupe(u8, s);
            if (api.objField(resp, "incomplete_details")) |details| {
                if (api.stringField(details, "reason")) |r| st.incomplete = try st.req.pers.dupe(u8, r);
            }
            if (api.objField(resp, "usage")) |u| {
                st.usage.input = api.numField(u, "input_tokens");
                st.usage.output = api.numField(u, "output_tokens");
                st.usage.total_tokens = api.numField(u, "total_tokens");
                if (api.objField(u, "input_tokens_details")) |d| {
                    st.usage.cache_read = api.numField(d, "cached_tokens");
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.failed")) {
            const resp = api.objField(obj, "response") orelse return;
            const message = api.errorMessage(resp, "error") orelse "response failed";
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
            return;
        }
    }
};

fn finalize(st: *State) !void {
    const a = st.req.pers;
    if (st.reasoning.items.len > 0) try st.msg.content.append(a, .{ .thinking = .{ .text = st.reasoning.items } });
    if (st.text.items.len > 0) try st.msg.content.append(a, .{ .text = st.text.items });

    // A broken stream leaves arguments truncated; running them would be a
    // call the model never finished making.
    const has_calls = try api.appendCalls(st.msg, st.sink, a, st.calls.items, st.failed);

    var usage = st.usage;
    usage.input = st.usage.input -| st.usage.cache_read;
    api.finishUsage(st.msg, st.req.model, usage);

    if (st.status) |status| {
        if (std.mem.eql(u8, status, "incomplete")) {
            if (st.incomplete) |reason| {
                if (std.mem.eql(u8, reason, "max_output_tokens")) {
                    st.msg.stop_reason = .length;
                } else {
                    st.msg.stop_reason = .err;
                    st.msg.error_message = try a.dupe(u8, reason);
                }
            } else {
                st.msg.stop_reason = .length;
            }
            return;
        }
        if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) {
            st.msg.stop_reason = .err;
            st.msg.error_message = st.stream_error orelse "response failed";
            return;
        }
    }
    st.msg.stop_reason = if (has_calls) .tool_use else .stop;
}

const wire = api.Wire{
    .key_header = "Authorization",
    .key_prefix = "Bearer ",
    .path = "/responses",
    .build_body = buildBody,
};

pub fn stream(req: api.Request, sink: api.Sink) std.mem.Allocator.Error!types.AssistantMessage {
    return api.run(State, wire, req, sink, finalize);
}
