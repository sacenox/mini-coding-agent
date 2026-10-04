//! OpenAI Responses API streaming adapter. The wire format behind every
//! customProvider with api "openai-responses".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const http = @import("../http.zig");
const json = @import("../json.zig");

const Value = std.json.Value;

/// An untrusted stream index is a hint, never a size. Anything past this is
/// treated like a missing index so a hostile chunk cannot force an allocation.
const max_stream_index = 10_000;

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
                    try json.writeString(w, if (c.arguments.len > 0) c.arguments else "{}");
                    try w.writeByte('}');
                },
                .thinking, .image => {},
            };
        },
    }
}

fn writeTools(w: *std.Io.Writer, a: std.mem.Allocator, tools_json: []const u8) !void {
    const tools = api.parseTools(a, tools_json) orelse return;
    try w.writeAll(",\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"function\",");
        try api.writeToolBody(w, tool.object, "parameters");
        try w.writeByte('}');
    }
    try w.writeByte(']');
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
        try json.writeUint(w, if (req.model.max_tokens > 16) req.model.max_tokens else 16);
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

    try writeTools(w, req.scratch, req.tools_json);
    try w.writeByte('}');
    return out.written();
}

fn buildUrl(a: std.mem.Allocator, base: []const u8) ![]u8 {
    return api.buildUrl(a, base, "/responses");
}

fn headers(a: std.mem.Allocator, req: api.Request, auth: []const u8) ![]http.Header {
    return api.headers(a, req, &.{.{ "Authorization", auth }});
}

// ---- streaming state ------------------------------------------------------

const Call = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
    started: bool = false,
};

const State = struct {
    req: api.Request,
    sink: api.Sink,
    arena: *std.heap.ArenaAllocator,
    msg: *types.AssistantMessage,
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    tokens_total: u64 = 0,
    cache_read: u64 = 0,
    status: ?[]const u8 = null,
    incomplete: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
};

fn grow(st: *State, count: usize) !void {
    while (st.calls.items.len < count) try st.calls.append(st.req.pers, .{});
}

fn streamIndex(obj: std.json.ObjectMap, fallback: usize) usize {
    const v = obj.get("output_index") orelse return fallback;
    return switch (v) {
        .integer => |n| if (n < 0 or n > max_stream_index) fallback else @intCast(n),
        else => fallback,
    };
}

fn handle(st: *State, obj: std.json.ObjectMap) !void {
    const event_type = api.stringField(obj, "type") orelse "";

    if (std.mem.eql(u8, event_type, "error")) {
        const message = api.stringField(obj, "message") orelse blk: {
            const e = obj.get("error") orelse break :blk "stream: provider error";
            break :blk switch (e) {
                .object => |o| api.stringField(o, "message") orelse "stream: provider error",
                else => "stream: provider error",
            };
        };
        if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
        return;
    }

    if (std.mem.eql(u8, event_type, "response.created")) {
        if (obj.get("response")) |resp| {
            if (resp == .object and st.msg.response_id == null) {
                if (api.stringField(resp.object, "id")) |id| {
                    st.msg.response_id = try st.req.pers.dupe(u8, id);
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        const item = obj.get("item") orelse return;
        if (item != .object) return;
        if (!std.mem.eql(u8, api.stringField(item.object, "type") orelse "", "function_call")) return;
        const index = streamIndex(obj, st.calls.items.len);
        try grow(st, index + 1);
        const call = &st.calls.items[index];
        if (api.stringField(item.object, "call_id")) |id| call.id = try st.req.pers.dupe(u8, id);
        if (api.stringField(item.object, "name")) |name| call.name = try st.req.pers.dupe(u8, name);
        if (!call.started and call.name.len > 0) {
            call.started = true;
            st.sink.emit(.{ .tool_start = call.name });
        }
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
        const item = obj.get("item") orelse return;
        if (item != .object) return;
        if (!std.mem.eql(u8, api.stringField(item.object, "type") orelse "", "function_call")) return;
        const index = streamIndex(obj, st.calls.items.len);
        if (index >= st.calls.items.len) return;
        const call = &st.calls.items[index];
        if (api.stringField(item.object, "call_id")) |id| call.id = try st.req.pers.dupe(u8, id);
        if (api.stringField(item.object, "name")) |name| call.name = try st.req.pers.dupe(u8, name);
        if (!call.started and call.name.len > 0) {
            call.started = true;
            st.sink.emit(.{ .tool_start = call.name });
        }
        if (call.args.items.len == 0) {
            if (api.stringField(item.object, "arguments")) |s| try call.args.appendSlice(st.req.pers, s);
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.incomplete"))
    {
        const resp = obj.get("response") orelse return;
        if (resp != .object) return;
        if (api.stringField(resp.object, "status")) |s| st.status = try st.req.pers.dupe(u8, s);
        if (resp.object.get("incomplete_details")) |details| {
            if (details == .object) {
                if (api.stringField(details.object, "reason")) |r| st.incomplete = try st.req.pers.dupe(u8, r);
            }
        }
        if (resp.object.get("usage")) |usage| {
            if (usage == .object) {
                st.tokens_in = api.numField(usage.object, "input_tokens");
                st.tokens_out = api.numField(usage.object, "output_tokens");
                st.tokens_total = api.numField(usage.object, "total_tokens");
                if (usage.object.get("input_tokens_details")) |d| {
                    if (d == .object) st.cache_read = api.numField(d.object, "cached_tokens");
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "response.failed")) {
        const resp = obj.get("response") orelse return;
        if (resp != .object) return;
        const err = resp.object.get("error") orelse return;
        const message = switch (err) {
            .object => |o| api.stringField(o, "message") orelse "response failed",
            else => "response failed",
        };
        if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
        return;
    }
}

fn onData(ctx: *anyopaque, data: []const u8) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    const a = st.arena.allocator();
    defer _ = st.arena.reset(.retain_capacity);

    const root = std.json.parseFromSliceLeaky(Value, a, data, .{}) catch {
        if (st.stream_error == null) st.stream_error = "stream: invalid JSON chunk";
        return;
    };
    if (root != .object) return;
    handle(st, root.object) catch {
        if (st.stream_error == null) st.stream_error = "stream: out of memory";
    };
}

fn finalize(st: *State) !void {
    const a = st.req.pers;
    if (st.reasoning.items.len > 0) try st.msg.content.append(a, .{ .thinking = .{ .text = st.reasoning.items } });
    if (st.text.items.len > 0) try st.msg.content.append(a, .{ .text = st.text.items });

    var has_calls = false;
    for (st.calls.items) |call| {
        if (call.name.len == 0) continue;
        has_calls = true;
        const arguments = if (call.args.items.len > 0) call.args.items else "{}";
        try st.msg.content.append(a, .{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = arguments,
        } });
        st.sink.emit(.{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = arguments,
        } });
    }

    var usage = types.Usage{};
    usage.input = st.tokens_in -| st.cache_read;
    usage.output = st.tokens_out;
    usage.cache_read = st.cache_read;
    usage.total_tokens = if (st.tokens_total > 0) st.tokens_total else st.tokens_in + st.tokens_out;
    api.applyCost(st.req.model, &usage);
    st.msg.usage = usage;

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

pub fn stream(req: api.Request, sink: api.Sink) std.mem.Allocator.Error!types.AssistantMessage {
    var msg = api.newAssistant(req);

    var arena = std.heap.ArenaAllocator.init(req.scratch);
    defer arena.deinit();

    const body = buildBody(req) catch return error.OutOfMemory;
    const url = buildUrl(req.scratch, req.model.base_url) catch return error.OutOfMemory;

    const auth = if (req.model.api_key) |key|
        std.fmt.allocPrint(req.scratch, "Bearer {s}", .{key}) catch return error.OutOfMemory
    else
        "";
    const hdrs = headers(req.scratch, req, auth) catch return error.OutOfMemory;

    var st = State{ .req = req, .sink = sink, .arena = &arena, .msg = &msg };

    if (!try api.post(req, url, hdrs, body, .{ .ctx = &st, .onEvent = onData }, &msg)) return msg;

    if (st.stream_error) |message| {
        msg.stop_reason = .err;
        msg.error_message = try req.pers.dupe(u8, message);
        return msg;
    }

    try finalize(&st);
    return msg;
}
