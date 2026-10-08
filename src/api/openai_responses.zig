const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");

const InputItem = struct {
    type: []const u8,
    role: ?[]const u8 = null,
    content: ?[]const ContentPart = null,
    call_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    output: ?[]const u8 = null,
    summary: ?[]const SummaryPart = null,
    encrypted_content: ?[]const u8 = null,

    const ContentPart = struct { type: []const u8 = "input_text", text: []const u8 };
    const SummaryPart = struct { type: []const u8 = "summary_text", text: []const u8 };
};

const Body = struct {
    model: []const u8,
    stream: bool = true,
    store: bool = false,
    instructions: ?[]const u8 = null,
    max_output_tokens: ?u64 = null,
    reasoning: ?struct { effort: []const u8 } = null,
    input: []const InputItem,
    tools: ?api.Tools = null,
};

fn buildInput(a: std.mem.Allocator, req: api.Request) ![]const InputItem {
    var out: std.ArrayList(InputItem) = .empty;
    for (req.messages) |msg| {
        switch (msg) {
            .tool_result => |t| try out.append(a, .{
                .type = "function_call_output",
                .call_id = t.tool_call_id,
                .output = t.text,
            }),
            .user => |u| {
                const content = try a.alloc(InputItem.ContentPart, 1);
                content[0] = .{ .text = u.content };
                try out.append(a, .{ .type = "message", .role = "user", .content = content });
            },
            .assistant => |am| {
                for (am.content.items) |block| switch (block) {
                    .text => |t| {
                        const content = try a.alloc(InputItem.ContentPart, 1);
                        content[0] = .{ .type = "output_text", .text = t };
                        try out.append(a, .{ .type = "message", .role = "assistant", .content = content });
                    },
                    .tool_call => |c| try out.append(a, .{
                        .type = "function_call",
                        .call_id = c.id,
                        .name = c.name,
                        .arguments = api.argumentsOrObject(c.arguments),
                    }),
                    .thinking => |t| {
                        const enc = t.signature orelse continue;
                        const summary = try a.alloc(InputItem.SummaryPart, if (t.text.len > 0) 1 else 0);
                        if (t.text.len > 0) summary[0] = .{ .text = t.text };
                        try out.append(a, .{
                            .type = "reasoning",
                            .encrypted_content = enc,
                            .summary = summary,
                        });
                    },
                };
            },
        }
    }
    return out.items;
}

fn buildBody(req: api.Request) ![]u8 {
    const a = req.scratch;
    const max_tokens: ?u64 = if (req.model.sends_max_output and req.model.max_tokens > 0)
        (if (req.model.max_tokens > 16) req.model.max_tokens else 16)
    else
        null;
    const effort = if (req.effort.len > 0 and !std.mem.eql(u8, req.effort, "off")) req.effort else null;
    const body = Body{
        .model = req.model.id,
        .instructions = if (req.system_prompt.len > 0) req.system_prompt else null,
        .max_output_tokens = max_tokens,
        .reasoning = if (effort) |e| .{ .effort = e } else null,
        .input = try buildInput(a, req),
        .tools = if (req.tools_json.len > 0) .{ .a = a, .json = req.tools_json, .form = .{
            .open = "[",
            .entry = "{\"type\":\"function\",",
            .params_key = "parameters",
            .entry_close = "}",
            .close = "]",
        } } else null,
    };
    return std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false });
}

const Chunk = struct {
    type: ?[]const u8 = null,
    message: ?[]const u8 = null,
    @"error": ?api.ErrField = null,
    output_index: ?i64 = null,
    delta: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    item: ?Item = null,
    response: ?Response = null,

    const Item = struct {
        type: ?[]const u8 = null,
        call_id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
        encrypted_content: ?[]const u8 = null,
    };

    const Response = struct {
        id: ?[]const u8 = null,
        status: ?[]const u8 = null,
        incomplete_details: ?struct { reason: ?[]const u8 = null } = null,
        usage: ?Usage = null,
        @"error": ?api.ErrField = null,
    };

    const Usage = struct {
        input_tokens: api.Count = .{},
        output_tokens: api.Count = .{},
        total_tokens: api.Count = .{},
        input_tokens_details: ?struct { cached_tokens: api.Count = .{} } = null,
    };
};

fn streamIndex(chunk: Chunk, fallback: usize) usize {
    const v = chunk.output_index orelse return fallback;
    return if (v < 0 or v > api.max_stream_index) fallback else @intCast(v);
}

const State = struct {
    req: api.Request,
    sink: api.Sink,
    arena: *std.heap.ArenaAllocator,
    msg: *types.AssistantMessage,
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    encrypted: ?[]const u8 = null,
    calls: std.ArrayList(api.Call) = .empty,
    usage: types.Usage = .{},
    status: ?[]const u8 = null,
    incomplete: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
    failed: bool = false,

    pub fn handle(st: *State, chunk: Chunk) !void {
        const event_type = chunk.type orelse "";

        if (std.mem.eql(u8, event_type, "error")) {
            const message = chunk.message orelse
                (if (chunk.@"error") |e| e.message orelse "stream: provider error" else "stream: provider error");
            try api.keepString(&st.stream_error, st.req.pers, message);
            return;
        }

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (chunk.response) |resp| {
                try api.keepString(&st.msg.response_id, st.req.pers, resp.id);
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = chunk.item orelse return;
            if (!std.mem.eql(u8, item.type orelse "", "function_call")) return;
            const index = streamIndex(chunk, st.calls.items.len);
            const call = try api.blockAt(api.Call, &st.calls, st.req.pers, @intCast(index));
            if (item.call_id) |id| call.id = try st.req.pers.dupe(u8, id);
            try call.announce(st.req.pers, st.sink, item.name orelse "");
            return;
        }

        if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            if (chunk.delta) |s| {
                try st.text.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .text = s });
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            if (chunk.delta) |s| {
                try st.reasoning.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .reasoning = s });
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const index = streamIndex(chunk, st.calls.items.len);
            if (index < st.calls.items.len) {
                if (chunk.delta) |s| try st.calls.items[index].grow(st.req.pers, st.sink, s);
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const index = streamIndex(chunk, st.calls.items.len);
            if (index < st.calls.items.len) {
                if (chunk.arguments) |s| {
                    st.calls.items[index].args.clearRetainingCapacity();
                    try st.calls.items[index].grow(st.req.pers, st.sink, s);
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = chunk.item orelse return;
            if (std.mem.eql(u8, item.type orelse "", "reasoning")) {
                try api.keepString(&st.encrypted, st.req.pers, item.encrypted_content);
                return;
            }
            if (!std.mem.eql(u8, item.type orelse "", "function_call")) return;
            const index = streamIndex(chunk, st.calls.items.len);
            if (index >= st.calls.items.len) return;
            const call = &st.calls.items[index];
            if (item.call_id) |id| call.id = try st.req.pers.dupe(u8, id);
            if (item.name) |name| call.name = try st.req.pers.dupe(u8, name);
            if (!call.started and call.name.len > 0) {
                call.started = true;
                st.sink.emit(.{ .tool_start = call.name });
            }
            if (call.args.items.len == 0) {
                if (item.arguments) |s| try call.grow(st.req.pers, st.sink, s);
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            const resp = chunk.response orelse return;
            if (resp.status) |s| {
                if (s.len > 0) st.status = try st.req.pers.dupe(u8, s);
            }
            if (resp.incomplete_details) |details| {
                if (details.reason) |r| st.incomplete = try st.req.pers.dupe(u8, r);
            }
            if (resp.usage) |u| {
                st.usage.input = u.input_tokens.value;
                st.usage.output = u.output_tokens.value;
                st.usage.total_tokens = u.total_tokens.value;
                if (u.input_tokens_details) |d| st.usage.cache_read = d.cached_tokens.value;
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "response.failed")) {
            const resp = chunk.response orelse return;
            const message = if (resp.@"error") |e| e.message orelse "response failed" else "response failed";
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
            return;
        }
    }
};

fn finalize(st: *State) !void {
    const a = st.req.pers;
    if (st.reasoning.items.len > 0 or st.encrypted != null) {
        try st.msg.content.append(a, .{ .thinking = .{
            .text = st.reasoning.items,
            .signature = st.encrypted,
        } });
    }
    if (st.text.items.len > 0) try st.msg.content.append(a, .{ .text = st.text.items });

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
    return api.run(State, Chunk, wire, req, sink, finalize);
}
