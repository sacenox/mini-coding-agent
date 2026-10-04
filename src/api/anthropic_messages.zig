//! Anthropic Messages API streaming adapter. The wire format behind every
//! customProvider with api "anthropic-messages".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const http = @import("../http.zig");
const json = @import("../json.zig");

const Value = std.json.Value;
const anthropic_version = "2023-06-01";

/// An untrusted stream index is a hint, never a size. Anything past this is
/// treated like a missing index so a hostile chunk cannot force an allocation.
const max_stream_index = 10_000;

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
        .image => |img| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeImage(w, img);
        },
        .tool_call => |c| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"type\":\"tool_use\",\"id\":");
            try json.writeString(w, c.id);
            try w.writeAll(",\"name\":");
            try json.writeString(w, c.name);
            try w.writeAll(",\"input\":");
            try w.writeAll(if (c.arguments.len > 0) c.arguments else "{}");
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

fn writeTools(w: *std.Io.Writer, a: std.mem.Allocator, tools_json: []const u8, params_key: []const u8) !void {
    if (tools_json.len == 0) return;
    const root = std.json.parseFromSliceLeaky(Value, a, tools_json, .{}) catch return;
    if (root != .array) return;
    try w.writeAll(",\"tools\":[");
    for (root.array.items, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        const obj = tool.object;
        try w.writeAll("{\"name\":");
        try json.writeString(w, obj.get("name").?.string);
        try w.writeAll(",\"description\":");
        try json.writeString(w, obj.get("description").?.string);
        try w.writeAll(",\"");
        try w.writeAll(params_key);
        try w.writeAll("\":");
        try std.json.Stringify.value(obj.get("parameters").?, .{}, w);
        try w.writeByte('}');
    }
    try w.writeByte(']');
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
    try json.writeUint(w, max_tokens);
    try w.writeAll(",\"stream\":true");
    if (req.system_prompt.len > 0) {
        try w.writeAll(",\"system\":");
        try json.writeString(w, req.system_prompt);
    }
    if (budget > 0) {
        try w.writeAll(",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
        try json.writeUint(w, budget);
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

    try writeTools(w, req.scratch, req.tools_json, "input_schema");
    try w.writeByte('}');
    return out.written();
}

fn buildUrl(a: std.mem.Allocator, base: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/v1/messages", .{std.mem.trimEnd(u8, base, "/")});
}

fn headers(a: std.mem.Allocator, req: api.Request, key: []const u8) ![]http.Header {
    var list: std.ArrayList(http.Header) = .empty;
    errdefer list.deinit(a);
    try list.append(a, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(a, .{ .name = "Accept", .value = "text/event-stream" });
    try list.append(a, .{ .name = "anthropic-version", .value = anthropic_version });
    if (key.len > 0) try list.append(a, .{ .name = "x-api-key", .value = key });
    for (req.model.headers) |kv| try list.append(a, .{ .name = kv[0], .value = kv[1] });
    if (req.session_id) |sid| {
        if (req.model.session_header) |name| {
            if (sid.len > 0) try list.append(a, .{ .name = name, .value = sid });
        }
    }
    return list.toOwnedSlice(a);
}

// ---- streaming state ------------------------------------------------------

const BlockKind = enum { text, thinking, tool };

const Block = struct {
    kind: BlockKind = .text,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
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
    blocks: std.ArrayList(Block) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    reasoning_tokens: ?u64 = null,
    stop_reason: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
};

fn blockAt(st: *State, index: i64) !*Block {
    const idx: usize = if (index >= 0 and index <= max_stream_index)
        @intCast(index)
    else
        st.blocks.items.len;
    while (st.blocks.items.len <= idx) try st.blocks.append(st.req.pers, .{});
    return &st.blocks.items[idx];
}

fn num(v: Value) u64 {
    return switch (v) {
        .integer => |n| @intCast(@max(n, 0)),
        .float => |f| @intFromFloat(@max(f, 0)),
        else => 0,
    };
}

fn numField(obj: std.json.ObjectMap, key: []const u8) u64 {
    return num(obj.get(key) orelse return 0);
}

fn applyCost(model: *const types.Model, u: *types.Usage) void {
    const m = 1_000_000.0;
    u.cost_input = @as(f64, @floatFromInt(u.input)) * model.cost_input / m;
    u.cost_output = @as(f64, @floatFromInt(u.output)) * model.cost_output / m;
    u.cost_cache_read = @as(f64, @floatFromInt(u.cache_read)) * model.cost_cache_read / m;
    u.cost_cache_write = 0;
    u.cost_total = u.cost_input + u.cost_output + u.cost_cache_read + u.cost_cache_write;
}

fn handle(st: *State, obj: std.json.ObjectMap) !void {
    const event_type = switch (obj.get("type") orelse Value{ .null = {} }) {
        .string => |s| s,
        else => "",
    };

    if (std.mem.eql(u8, event_type, "error")) {
        if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, errorMessage(obj));
        return;
    }

    if (std.mem.eql(u8, event_type, "message_start")) {
        const message = obj.get("message") orelse return;
        if (message != .object) return;
        const message_obj = message.object;
        if (st.msg.response_id == null) {
            if (message_obj.get("id")) |v| {
                if (v == .string) st.msg.response_id = try st.req.pers.dupe(u8, v.string);
            }
        }
        if (message_obj.get("usage")) |usage| {
            if (usage == .object) {
                st.tokens_in = numField(usage.object, "input_tokens");
                st.tokens_out = numField(usage.object, "output_tokens");
                st.cache_read = numField(usage.object, "cache_read_input_tokens");
                st.cache_write = numField(usage.object, "cache_creation_input_tokens");
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const raw: i64 = switch (obj.get("index") orelse Value{ .null = {} }) {
            .integer => |n| n,
            else => -1,
        };
        if (raw < 0 or raw > max_stream_index) return;
        const block = try blockAt(st, raw);
        const cb = obj.get("content_block") orelse return;
        if (cb != .object) return;
        const bt = switch (cb.object.get("type") orelse Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, bt, "tool_use")) {
            block.kind = .tool;
            if (cb.object.get("id")) |id| {
                if (id == .string) block.id = try st.req.pers.dupe(u8, id.string);
            }
            if (cb.object.get("name")) |name| {
                if (name == .string) block.name = try st.req.pers.dupe(u8, name.string);
            }
            if (!block.started and block.name.len > 0) {
                block.started = true;
                st.sink.emit(.{ .tool_start = block.name });
            }
        } else if (std.mem.eql(u8, bt, "thinking") or std.mem.eql(u8, bt, "redacted_thinking")) {
            block.kind = .thinking;
            if (std.mem.eql(u8, bt, "redacted_thinking")) {
                if (cb.object.get("data")) |d| {
                    if (d == .string) try block.signature.appendSlice(st.req.pers, d.string);
                }
            }
        } else {
            block.kind = .text;
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const idx: i64 = switch (obj.get("index") orelse Value{ .null = {} }) {
            .integer => |n| n,
            else => return,
        };
        const delta = obj.get("delta") orelse return;
        if (delta != .object) return;
        if (idx < 0 or idx >= st.blocks.items.len) return;
        const block = &st.blocks.items[@intCast(idx)];
        const dt = switch (delta.object.get("type") orelse Value{ .null = {} }) {
            .string => |s| s,
            else => "",
        };
        if (std.mem.eql(u8, dt, "text_delta")) {
            if (stringField(delta.object, "text")) |s| {
                try block.text.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .text = s });
            }
        } else if (std.mem.eql(u8, dt, "thinking_delta")) {
            if (stringField(delta.object, "thinking")) |s| {
                try block.text.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .reasoning = s });
            }
        } else if (std.mem.eql(u8, dt, "signature_delta")) {
            if (stringField(delta.object, "signature")) |s| {
                try block.signature.appendSlice(st.req.pers, s);
            }
        } else if (std.mem.eql(u8, dt, "input_json_delta")) {
            if (stringField(delta.object, "partial_json")) |s| {
                try block.args.appendSlice(st.req.pers, s);
            }
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        if (obj.get("delta")) |delta| {
            if (delta == .object) {
                if (stringField(delta.object, "stop_reason")) |s| {
                    st.stop_reason = try st.req.pers.dupe(u8, s);
                }
            }
        }
        if (obj.get("usage")) |usage| {
            if (usage == .object) {
                if (usage.object.get("input_tokens") != null) st.tokens_in = numField(usage.object, "input_tokens");
                if (usage.object.get("output_tokens") != null) st.tokens_out = numField(usage.object, "output_tokens");
                if (usage.object.get("cache_read_input_tokens") != null) st.cache_read = numField(usage.object, "cache_read_input_tokens");
                if (usage.object.get("cache_creation_input_tokens") != null) st.cache_write = numField(usage.object, "cache_creation_input_tokens");
                if (usage.object.get("output_tokens_details")) |details| {
                    if (details == .object and details.object.get("thinking_tokens") != null) {
                        st.reasoning_tokens = numField(details.object, "thinking_tokens");
                    }
                }
            }
        }
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

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn errorMessage(obj: std.json.ObjectMap) []const u8 {
    const err = obj.get("error") orelse return "stream: provider error";
    return switch (err) {
        .object => |o| stringField(o, "message") orelse "stream: provider error",
        else => "stream: provider error",
    };
}

fn mapStopReason(st: *State) void {
    var has_calls = false;
    for (st.blocks.items) |block| {
        if (block.kind == .tool and block.name.len > 0) has_calls = true;
    }
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
    for (st.blocks.items) |block| {
        if (block.kind != .tool or block.name.len == 0) continue;
        const arguments = if (block.args.items.len > 0) block.args.items else "{}";
        try st.msg.content.append(a, .{ .tool_call = .{
            .id = block.id,
            .name = block.name,
            .arguments = arguments,
        } });
        st.sink.emit(.{ .tool_call = .{
            .id = block.id,
            .name = block.name,
            .arguments = arguments,
        } });
    }

    var usage = types.Usage{};
    usage.input = st.tokens_in;
    usage.output = st.tokens_out;
    usage.cache_read = st.cache_read;
    usage.cache_write = st.cache_write;
    usage.reasoning = st.reasoning_tokens;
    usage.total_tokens = st.tokens_in + st.tokens_out + st.cache_read + st.cache_write;
    applyCost(st.req.model, &usage);
    st.msg.usage = usage;

    st.msg.raw_stop_reason = st.stop_reason;
    mapStopReason(st);
}

pub fn stream(req: api.Request, sink: api.Sink) std.mem.Allocator.Error!types.AssistantMessage {
    var msg = api.newAssistant(req);

    var arena = std.heap.ArenaAllocator.init(req.scratch);
    defer arena.deinit();

    const body = buildBody(req) catch return error.OutOfMemory;
    const url = buildUrl(req.scratch, req.model.base_url) catch return error.OutOfMemory;
    const key = req.model.api_key orelse "";
    const hdrs = headers(req.scratch, req, key) catch return error.OutOfMemory;

    var st = State{ .req = req, .sink = sink, .arena = &arena, .msg = &msg };
    var err_body: ?[]const u8 = null;

    http.postSse(req.scratch, url, hdrs, body, .{ .ctx = &st, .onEvent = onData }, req.cancel, &err_body) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (e == error.Aborted or req.cancel.load(.acquire)) {
            msg.stop_reason = .aborted;
        } else {
            msg.stop_reason = .err;
            const message = switch (e) {
                error.HttpStatus => err_body orelse "provider returned an error status",
                error.ReadFailed => "stream read failed",
                else => "request failed",
            };
            msg.error_message = try req.pers.dupe(u8, message);
        }
        return msg;
    };

    if (req.cancel.load(.acquire)) {
        msg.stop_reason = .aborted;
        return msg;
    }
    if (st.stream_error) |message| {
        msg.stop_reason = .err;
        msg.error_message = try req.pers.dupe(u8, message);
        return msg;
    }

    try finalize(&st);
    return msg;
}
