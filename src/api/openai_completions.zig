//! OpenAI-compatible chat completions with streaming. The wire format behind
//! opencode-go and every customProvider with api "openai-completions".

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

fn writeAssistant(w: *std.Io.Writer, am: *const types.AssistantMessage, a: std.mem.Allocator) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":");
    var text: std.ArrayList(u8) = .empty;
    for (am.content.items) |block| switch (block) {
        .text => |t| text.appendSlice(a, t) catch return error.OutOfMemory,
        else => {},
    };
    try json.writeString(w, text.items);

    var calls: usize = 0;
    for (am.content.items) |block| {
        if (block != .tool_call) continue;
        if (calls == 0) try w.writeAll(",\"tool_calls\":[") else try w.writeByte(',');
        calls += 1;
        const call = block.tool_call;
        try w.writeAll("{\"id\":");
        try json.writeString(w, call.id);
        try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
        try json.writeString(w, call.name);
        try w.writeAll(",\"arguments\":");
        try json.writeString(w, if (call.arguments.len > 0) call.arguments else "{}");
        try w.writeAll("}}");
    }
    if (calls > 0) try w.writeByte(']');
    try w.writeByte('}');
}

fn hasImage(msg: types.Message) bool {
    return msg == .tool_result and msg.tool_result.images.len > 0;
}

fn writeToolResult(w: *std.Io.Writer, t: types.ToolResultMessage) !void {
    try w.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
    try json.writeString(w, t.tool_call_id);
    try w.writeAll(",\"content\":");
    const content = if (t.text.len > 0 or t.images.len == 0) t.text else "(see attached image)";
    try json.writeString(w, content);
    try w.writeByte('}');
}

fn writeImages(w: *std.Io.Writer, run: []const types.Message) !void {
    try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Attached image(s) from tool result:\"}");
    for (run) |msg| {
        for (msg.tool_result.images) |img| {
            try w.writeAll(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
            try w.writeAll(img.mime_type);
            try w.writeAll(";base64,");
            try w.writeAll(img.data);
            try w.writeAll("\"}}");
        }
    }
    try w.writeAll("]}");
}

fn buildBody(req: api.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(req.scratch);
    const w = &out.writer;

    try w.writeAll("{\"model\":");
    try json.writeString(w, req.model.id);
    try w.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true}");
    if (req.effort.len > 0 and !std.mem.eql(u8, req.effort, "off")) {
        try w.writeAll(",\"reasoning_effort\":");
        try json.writeString(w, req.effort);
    }

    try w.writeAll(",\"messages\":[");
    var first = true;
    if (req.system_prompt.len > 0) {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try json.writeString(w, req.system_prompt);
        try w.writeByte('}');
        first = false;
    }
    var i: usize = 0;
    while (i < req.messages.len) {
        if (req.messages[i] == .tool_result) {
            // A run of tool results lands together. Any images among them are
            // sent as one following user message, because a tool message's
            // content is a string and a user message between a call and its
            // results is rejected.
            const start = i;
            var images = false;
            while (i < req.messages.len and req.messages[i] == .tool_result) : (i += 1) {
                if (!first) try w.writeByte(',');
                first = false;
                try writeToolResult(w, req.messages[i].tool_result);
                if (hasImage(req.messages[i])) images = true;
            }
            if (images) {
                if (!first) try w.writeByte(',');
                first = false;
                try writeImages(w, req.messages[start..i]);
            }
            continue;
        }
        if (!first) try w.writeByte(',');
        first = false;
        switch (req.messages[i]) {
            .user => |u| {
                try w.writeAll("{\"role\":\"user\",\"content\":");
                try json.writeString(w, u.content);
                try w.writeByte('}');
            },
            .assistant => |am| try writeAssistant(w, am, req.scratch),
            .tool_result => unreachable,
        }
        i += 1;
    }
    try w.writeByte(']');
    try writeTools(w, req.scratch, req.tools_json);
    try w.writeByte('}');
    return out.written();
}

/// The tool schemas as chat completions wants them: each wrapped in a
/// `function` object. The flat form recorded in the session is not the wire
/// form here.
fn writeTools(w: *std.Io.Writer, a: std.mem.Allocator, tools_json: []const u8) !void {
    if (tools_json.len == 0) return;
    const root = std.json.parseFromSliceLeaky(Value, a, tools_json, .{}) catch return;
    if (root != .array) return;
    try w.writeAll(",\"tools\":[");
    for (root.array.items, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        const obj = tool.object;
        try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try json.writeString(w, obj.get("name").?.string);
        try w.writeAll(",\"description\":");
        try json.writeString(w, obj.get("description").?.string);
        try w.writeAll(",\"parameters\":");
        try std.json.Stringify.value(obj.get("parameters").?, .{}, w);
        try w.writeAll("}}");
    }
    try w.writeByte(']');
}

fn buildUrl(a: std.mem.Allocator, base: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/chat/completions", .{std.mem.trimEnd(u8, base, "/")});
}

fn headers(a: std.mem.Allocator, req: api.Request, auth: []const u8) ![]http.Header {
    var list: std.ArrayList(http.Header) = .empty;
    errdefer list.deinit(a);
    try list.append(a, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(a, .{ .name = "Accept", .value = "text/event-stream" });
    if (auth.len > 0) try list.append(a, .{ .name = "Authorization", .value = auth });
    for (req.model.headers) |kv| try list.append(a, .{ .name = kv[0], .value = kv[1] });
    if (req.session_id) |sid| {
        if (req.model.session_header) |name| {
            if (sid.len > 0) try list.append(a, .{ .name = name, .value = sid });
        }
    }
    return list.toOwnedSlice(a);
}

// ---- streaming state ------------------------------------------------------

const PendingCall = struct {
    index: i64,
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
    thinking: std.ArrayList(u8) = .empty,
    signature: ?[]const u8 = null,
    calls: std.ArrayList(PendingCall) = .empty,
    finish_reason: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
};

fn ensureCall(st: *State, index: i64) !*PendingCall {
    const idx: usize = if (index >= 0 and index <= max_stream_index)
        @intCast(index)
    else
        st.calls.items.len;
    while (st.calls.items.len <= idx) {
        try st.calls.append(st.req.pers, .{ .index = @intCast(st.calls.items.len) });
    }
    return &st.calls.items[idx];
}

fn deltaString(delta: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = delta.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn handleDelta(st: *State, delta: std.json.ObjectMap) !void {
    if (deltaString(delta, "content")) |s| {
        try st.text.appendSlice(st.req.pers, s);
        st.sink.emit(.{ .text = s });
    }

    const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    for (reasoning_fields) |field| {
        if (deltaString(delta, field)) |s| {
            if (st.signature == null) st.signature = field;
            try st.thinking.appendSlice(st.req.pers, s);
            st.sink.emit(.{ .reasoning = s });
            break;
        }
    }

    const tcs = delta.get("tool_calls") orelse return;
    if (tcs != .array) return;
    for (tcs.array.items) |tc| {
        if (tc != .object) continue;
        const index: i64 = switch (tc.object.get("index") orelse .null) {
            .integer => |n| n,
            else => -1,
        };
        const call = try ensureCall(st, index);
        if (tc.object.get("id")) |id| {
            if (id == .string and call.id.len == 0) call.id = try st.req.pers.dupe(u8, id.string);
        }
        const fn_ = tc.object.get("function") orelse continue;
        if (fn_ != .object) continue;
        if (fn_.object.get("name")) |name| {
            if (name == .string and name.string.len > 0) {
                if (call.name.len == 0) call.name = try st.req.pers.dupe(u8, name.string);
                if (!call.started) {
                    call.started = true;
                    st.sink.emit(.{ .tool_start = call.name });
                }
            }
        }
        if (fn_.object.get("arguments")) |args| {
            if (args == .string) try call.args.appendSlice(st.req.pers, args.string);
        }
    }
}

fn num(v: Value) u64 {
    return switch (v) {
        .integer => |i| @intCast(@max(i, 0)),
        .float => |f| @intFromFloat(@max(f, 0)),
        else => 0,
    };
}

fn numField(obj: std.json.ObjectMap, key: []const u8) u64 {
    const v = obj.get(key) orelse return 0;
    return num(v);
}

fn parseUsage(st: *State, usage: std.json.ObjectMap) void {
    var u = types.Usage{};
    const prompt = numField(usage, "prompt_tokens");
    var cache_read: u64 = 0;
    if (usage.get("prompt_tokens_details")) |details| {
        if (details == .object) cache_read = numField(details.object, "cached_tokens");
    }
    if (cache_read == 0) cache_read = numField(usage, "cached_tokens");
    var cache_write: u64 = 0;
    if (usage.get("prompt_tokens_details")) |details| {
        if (details == .object) cache_write = numField(details.object, "cache_write_tokens");
    }
    const output = numField(usage, "completion_tokens");
    if (usage.get("completion_tokens_details")) |details| {
        if (details == .object) {
            if (details.object.get("reasoning_tokens") != null) {
                u.reasoning = numField(details.object, "reasoning_tokens");
            }
        }
    }
    u.input = prompt -| cache_read -| cache_write;
    u.output = output;
    u.cache_read = cache_read;
    u.cache_write = cache_write;
    u.total_tokens = u.input + output + cache_read + cache_write;
    applyCost(st.req.model, &u);
    st.msg.usage = u;
}

fn applyCost(model: *const types.Model, u: *types.Usage) void {
    const m = 1_000_000.0;
    u.cost_input = @as(f64, @floatFromInt(u.input)) * model.cost_input / m;
    u.cost_output = @as(f64, @floatFromInt(u.output)) * model.cost_output / m;
    u.cost_cache_read = @as(f64, @floatFromInt(u.cache_read)) * model.cost_cache_read / m;
    u.cost_cache_write = 0;
    u.cost_total = u.cost_input + u.cost_output + u.cost_cache_read + u.cost_cache_write;
}

fn errorMessageFrom(root: std.json.ObjectMap) ?[]const u8 {
    const err = root.get("error") orelse return null;
    return switch (err) {
        .object => |o| blk: {
            const m = o.get("message") orelse break :blk null;
            break :blk switch (m) {
                .string => |s| s,
                else => null,
            };
        },
        .string => |s| s,
        else => null,
    };
}

fn onData(ctx: *anyopaque, data: []const u8) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    const a = st.arena.allocator();
    defer _ = st.arena.reset(.retain_capacity);

    const trimmed = std.mem.trim(u8, data, " \r\n");
    if (std.mem.eql(u8, trimmed, "[DONE]")) return;

    const root = std.json.parseFromSliceLeaky(Value, a, data, .{}) catch {
        if (st.stream_error == null) st.stream_error = "stream: invalid JSON chunk";
        return;
    };
    if (root != .object) return;

    if (errorMessageFrom(root.object)) |message| {
        if (st.stream_error == null) st.stream_error = st.req.pers.dupe(u8, message) catch null;
        return;
    }

    if (st.msg.response_id == null) {
        if (root.object.get("id")) |v| {
            if (v == .string) st.msg.response_id = st.req.pers.dupe(u8, v.string) catch null;
        }
    }
    if (st.msg.response_model == null) {
        if (root.object.get("model")) |v| {
            if (v == .string and !std.mem.eql(u8, v.string, st.req.model.id)) {
                st.msg.response_model = st.req.pers.dupe(u8, v.string) catch null;
            }
        }
    }

    if (root.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("delta")) |delta| {
                    if (delta == .object) {
                        handleDelta(st, delta.object) catch {
                            if (st.stream_error == null) st.stream_error = "stream: out of memory";
                        };
                    }
                }
                if (choice.object.get("finish_reason")) |fr| {
                    if (fr == .string) st.finish_reason = st.req.pers.dupe(u8, fr.string) catch null;
                }
            }
        }
    }

    if (root.object.get("usage")) |usage| {
        if (usage == .object) parseUsage(st, usage.object);
    }
}

fn mapStopReason(st: *State) void {
    if (st.calls.items.len > 0) {
        st.msg.stop_reason = .tool_use;
        return;
    }
    const reason = st.finish_reason orelse {
        st.msg.stop_reason = .stop;
        return;
    };
    if (std.mem.eql(u8, reason, "length")) {
        st.msg.stop_reason = .length;
    } else if (std.mem.eql(u8, reason, "function_call") or std.mem.eql(u8, reason, "tool_calls")) {
        st.msg.stop_reason = .tool_use;
    } else if (std.mem.eql(u8, reason, "content_filter")) {
        st.msg.stop_reason = .err;
        st.msg.error_message = "Provider finish_reason: content_filter";
    } else {
        st.msg.stop_reason = .stop;
    }
}

fn finalize(st: *State) !void {
    const a = st.req.pers;
    if (st.thinking.items.len > 0) {
        try st.msg.content.append(a, .{ .thinking = .{
            .text = st.thinking.items,
            .signature = st.signature,
        } });
    }
    if (st.text.items.len > 0) try st.msg.content.append(a, .{ .text = st.text.items });
    for (st.calls.items) |call| {
        if (call.name.len == 0) continue;
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
    st.msg.raw_stop_reason = st.finish_reason;
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
    mapStopReason(&st);
    return msg;
}
