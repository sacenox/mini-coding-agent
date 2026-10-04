//! Anthropic Messages API streaming adapter. The wire format behind every
//! customProvider with api "anthropic-messages".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const json = @import("../json.zig");

const anthropic_version = "2023-06-01";

// ---- request building -----------------------------------------------------

fn writeImage(w: *std.Io.Writer, img: types.ImageContent) !void {
    try w.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try json.writeString(w, img.mime_type);
    try w.writeAll(",\"data\":");
    try json.writeString(w, img.data);
    try w.writeAll("}}");
}

/// A tool result is one block of a user message. Its content is a string when
/// there is only text, and an array when images must ride along.
fn writeToolResult(w: *std.Io.Writer, t: types.ToolResultMessage) !void {
    try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try json.writeString(w, t.tool_call_id);
    if (t.is_error) try w.writeAll(",\"is_error\":true");
    if (t.images.len == 0) {
        try w.writeAll(",\"content\":");
        try json.writeString(w, t.text);
    } else {
        try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
        try json.writeString(w, t.text);
        try w.writeByte('}');
        for (t.images) |img| {
            try w.writeByte(',');
            try writeImage(w, img);
        }
        try w.writeByte(']');
    }
    try w.writeByte('}');
}

/// An assistant turn as content blocks. Thinking blocks carry their signature
/// back so the provider's continuation data survives the round trip; a
/// thinking block without a signature becomes plain text.
fn writeAssistant(w: *std.Io.Writer, am: *const types.AssistantMessage) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":[");
    var first = true;
    for (am.content.items) |block| switch (block) {
        .text => |t| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try json.writeString(w, t);
            try w.writeByte('}');
        },
        .thinking => |t| {
            if (!first) try w.writeByte(',');
            first = false;
            if (t.signature) |sig| {
                if (sig.len > 0) {
                    try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
                    try json.writeString(w, t.text);
                    try w.writeAll(",\"signature\":");
                    try json.writeString(w, sig);
                    try w.writeByte('}');
                    continue;
                }
            }
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try json.writeString(w, t.text);
            try w.writeByte('}');
        },
        .tool_call => |c| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try json.writeString(w, c.id);
            try w.writeAll(",\"name\":");
            try json.writeString(w, c.name);
            try w.writeAll(",\"input\":");
            try w.writeAll(api.argumentsOrObject(c.arguments));
            try w.writeByte('}');
        },
    };
    try w.writeAll("]}");
}

fn writeUser(w: *std.Io.Writer, u: types.Message) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try json.writeString(w, u.user.content);
    try w.writeAll("}]}");
}

/// Anthropic thinking budget per effort. Anthropic requires max_tokens to
/// exceed the budget, so the caller raises max_tokens when it does not.
fn budgetFor(effort: []const u8) u64 {
    const map = .{
        .{ "minimal", 1024 },
        .{ "low", 2048 },
        .{ "medium", 4096 },
        .{ "high", 8192 },
        .{ "xhigh", 16384 },
        .{ "max", 32768 },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, effort, entry[0])) return entry[1];
    }
    return 0;
}

fn buildBody(req: api.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(req.scratch);
    const w = &out.writer;

    const budget = budgetFor(req.effort);
    var max_tokens: u64 = if (req.model.max_tokens > 0) req.model.max_tokens else 8192;
    if (budget > 0 and max_tokens <= budget) max_tokens = budget + 4096;

    try w.writeAll("{\"model\":");
    try json.writeString(w, req.model.id);
    try w.writeAll(",\"max_tokens\":");
    try json.writeNum(w, max_tokens);
    try w.writeAll(",\"stream\":true");
    if (req.system_prompt.len > 0) {
        try w.writeAll(",\"system\":");
        try json.writeString(w, req.system_prompt);
    }
    if (budget > 0) {
        try w.writeAll(",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
        try json.writeNum(w, budget);
        try w.writeByte('}');
    }

    try w.writeAll(",\"messages\":[");
    var first = true;
    var i: usize = 0;
    while (i < req.messages.len) {
        if (req.messages[i] == .tool_result) {
            // Every result of one assistant turn shares a single user message.
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"role\":\"user\",\"content\":[");
            var first_block = true;
            while (i < req.messages.len and req.messages[i] == .tool_result) : (i += 1) {
                if (!first_block) try w.writeByte(',');
                first_block = false;
                try writeToolResult(w, req.messages[i].tool_result);
            }
            try w.writeAll("]}");
            continue;
        }
        if (!first) try w.writeByte(',');
        first = false;
        switch (req.messages[i]) {
            .user => try writeUser(w, req.messages[i]),
            .assistant => |am| try writeAssistant(w, am),
            .tool_result => unreachable,
        }
        i += 1;
    }
    try w.writeByte(']');

    try api.writeTools(w, req.scratch, req.tools_json, .{
        .open = ",\"tools\":[",
        .entry = "{",
        .params_key = "input_schema",
        .entry_close = "}",
        .close = "]",
    });
    try w.writeByte('}');
    return out.written();
}

// ---- streaming state ------------------------------------------------------

const BlockKind = enum { text, thinking, tool };

const Block = struct {
    kind: BlockKind = .text,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    /// The call this block's arguments belong to, when `kind` is `.tool`.
    call: usize = 0,
};

const State = struct {
    req: api.Request,
    sink: api.Sink,
    arena: *std.heap.ArenaAllocator,
    msg: *types.AssistantMessage,
    blocks: std.ArrayList(Block) = .empty,
    calls: std.ArrayList(api.Call) = .empty,
    usage: types.Usage = .{},
    stop_reason: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
    /// Set by `run` when the stream did not run to completion.
    failed: bool = false,

    pub fn handle(st: *State, obj: std.json.ObjectMap) !void {
        const event_type = api.stringField(obj, "type") orelse "";

        if (std.mem.eql(u8, event_type, "error")) {
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, api.errorMessage(obj, "error") orelse "stream: provider error");
            return;
        }

        if (std.mem.eql(u8, event_type, "message_start")) {
            const message = api.objField(obj, "message") orelse return;
            if (st.msg.response_id == null) {
                if (api.stringField(message, "id")) |id| st.msg.response_id = try st.req.pers.dupe(u8, id);
            }
            if (api.objField(message, "usage")) |u| {
                st.usage.input = api.numField(u, "input_tokens");
                st.usage.output = api.numField(u, "output_tokens");
                st.usage.cache_read = api.numField(u, "cache_read_input_tokens");
                st.usage.cache_write = api.numField(u, "cache_creation_input_tokens");
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const block = try api.blockAt(Block, &st.blocks, st.req.pers, api.intOr(obj, "index", -1));
            const cb = api.objField(obj, "content_block") orelse return;
            const bt = api.stringField(cb, "type") orelse "";
            if (std.mem.eql(u8, bt, "tool_use")) {
                block.kind = .tool;
                block.call = st.calls.items.len;
                const call = try st.calls.addOne(st.req.pers);
                call.* = .{};
                if (api.stringField(cb, "id")) |id| call.id = try st.req.pers.dupe(u8, id);
                try call.announce(st.req.pers, st.sink, api.stringField(cb, "name") orelse "");
            } else if (std.mem.eql(u8, bt, "thinking") or std.mem.eql(u8, bt, "redacted_thinking")) {
                block.kind = .thinking;
                if (std.mem.eql(u8, bt, "redacted_thinking")) {
                    if (api.stringField(cb, "data")) |d| try block.signature.appendSlice(st.req.pers, d);
                }
            } else {
                block.kind = .text;
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const idx = api.intOr(obj, "index", -1);
            if (idx < 0 or idx >= st.blocks.items.len) return;
            const delta = api.objField(obj, "delta") orelse return;
            const block = &st.blocks.items[@intCast(idx)];
            const call = if (block.kind == .tool) &st.calls.items[block.call] else null;
            const dt = api.stringField(delta, "type") orelse "";
            if (std.mem.eql(u8, dt, "text_delta")) {
                if (api.stringField(delta, "text")) |s| {
                    try block.text.appendSlice(st.req.pers, s);
                    st.sink.emit(.{ .text = s });
                }
            } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                if (api.stringField(delta, "thinking")) |s| {
                    try block.text.appendSlice(st.req.pers, s);
                    st.sink.emit(.{ .reasoning = s });
                }
            } else if (std.mem.eql(u8, dt, "signature_delta")) {
                if (api.stringField(delta, "signature")) |s| {
                    try block.signature.appendSlice(st.req.pers, s);
                }
            } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                if (call) |c| {
                    if (api.stringField(delta, "partial_json")) |s| try c.args.appendSlice(st.req.pers, s);
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "message_delta")) {
            if (api.objField(obj, "delta")) |delta| {
                if (api.stringField(delta, "stop_reason")) |s| {
                    st.stop_reason = try st.req.pers.dupe(u8, s);
                }
            }
            if (api.objField(obj, "usage")) |u| {
                if (api.optNumField(u, "input_tokens")) |v| st.usage.input = v;
                if (api.optNumField(u, "output_tokens")) |v| st.usage.output = v;
                if (api.optNumField(u, "cache_read_input_tokens")) |v| st.usage.cache_read = v;
                if (api.optNumField(u, "cache_creation_input_tokens")) |v| st.usage.cache_write = v;
                if (api.objField(u, "output_tokens_details")) |d| {
                    st.usage.reasoning = api.optNumField(d, "thinking_tokens");
                }
            }
            return;
        }
    }
};

/// A stream that produced finished calls is a tool turn, not a stop. A broken
/// stream reports none, and `run` restores the transport's own reason.
fn mapStopReason(st: *State, has_calls: bool) void {
    if (has_calls) {
        st.msg.stop_reason = .tool_use;
        return;
    }
    const reason = st.stop_reason orelse {
        st.msg.stop_reason = .stop;
        return;
    };
    if (std.mem.eql(u8, reason, "max_tokens")) {
        st.msg.stop_reason = .length;
    } else if (std.mem.eql(u8, reason, "tool_use")) {
        st.msg.stop_reason = .tool_use;
    } else if (std.mem.eql(u8, reason, "refusal")) {
        st.msg.stop_reason = .err;
        st.msg.error_message = "Provider stop_reason: refusal";
    } else if (std.mem.eql(u8, reason, "sensitive")) {
        st.msg.stop_reason = .err;
        st.msg.error_message = "Provider stop_reason: sensitive";
    } else {
        st.msg.stop_reason = .stop;
    }
}

fn finalize(st: *State) !void {
    const a = st.req.pers;
    for (st.blocks.items) |block| {
        if (block.kind != .thinking) continue;
        if (block.text.items.len == 0 and block.signature.items.len == 0) continue;
        try st.msg.content.append(a, .{ .thinking = .{
            .text = block.text.items,
            .signature = if (block.signature.items.len > 0) block.signature.items else null,
        } });
    }
    for (st.blocks.items) |block| {
        if (block.kind != .text) continue;
        if (block.text.items.len == 0) continue;
        try st.msg.content.append(a, .{ .text = block.text.items });
    }
    const has_calls = try api.appendCalls(st.msg, st.sink, a, st.calls.items, st.failed);
    api.finishUsage(st.msg, st.req.model, st.usage);

    st.msg.raw_stop_reason = st.stop_reason;
    mapStopReason(st, has_calls);
}

const wire = api.Wire{
    .key_header = "x-api-key",
    .version = .{ "anthropic-version", anthropic_version },
    .path = "/messages",
    .build_body = buildBody,
};

pub fn stream(req: api.Request, sink: api.Sink) std.mem.Allocator.Error!types.AssistantMessage {
    return api.run(State, wire, req, sink, finalize);
}
