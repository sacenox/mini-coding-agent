//! Google Generative AI (Gemini) streaming adapter. The wire format behind
//! every customProvider with api "google-generative-ai".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const http = @import("../http.zig");
const json = @import("../json.zig");

const Value = std.json.Value;

// ---- request building -----------------------------------------------------

fn writeText(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"text\":");
    try json.writeString(w, text);
    try w.writeByte('}');
}

fn writeImage(w: *std.Io.Writer, img: types.ImageContent) !void {
    try w.writeAll("{\"inlineData\":{\"mimeType\":");
    try json.writeString(w, img.mime_type);
    try w.writeAll(",\"data\":");
    try json.writeString(w, img.data);
    try w.writeAll("}}");
}

fn writeFunctionCall(w: *std.Io.Writer, c: types.ToolCall) !void {
    try w.writeAll("{\"functionCall\":{\"name\":");
    try json.writeString(w, c.name);
    try w.writeAll(",\"args\":");
    try w.writeAll(if (c.arguments.len > 0) c.arguments else "{}");
    try w.writeByte('}');
    if (c.thought_signature) |sig| {
        try w.writeAll(",\"thoughtSignature\":");
        try json.writeString(w, sig);
    }
    try w.writeByte('}');
}

/// A user or assistant message as a content object.
fn writeContent(w: *std.Io.Writer, msg: types.Message) !void {
    switch (msg) {
        .user => |u| {
            try w.writeAll("{\"role\":\"user\",\"parts\":[");
            try writeText(w, u.content);
            try w.writeAll("]}");
        },
        .assistant => |am| {
            try w.writeAll("{\"role\":\"model\",\"parts\":[");
            var first = true;
            for (am.content.items) |block| switch (block) {
                .text => |t| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeText(w, t);
                },
                .tool_call => |c| {
                    if (!first) try w.writeByte(',');
                    first = false;
                    try writeFunctionCall(w, c);
                },
                .thinking, .image => {},
            };
            try w.writeAll("]}");
        },
        .tool_result => unreachable,
    }
}

/// A run of tool results becomes one user turn of functionResponse parts. The
/// response key is "error" when the tool failed and "output" otherwise.
fn writeToolResults(w: *std.Io.Writer, run: []const types.Message) !void {
    try w.writeAll("{\"role\":\"user\",\"parts\":[");
    for (run, 0..) |msg, i| {
        if (i > 0) try w.writeByte(',');
        const t = msg.tool_result;
        try w.writeAll("{\"functionResponse\":{\"name\":");
        try json.writeString(w, t.tool_name);
        try w.writeAll(",\"response\":{\"");
        try w.writeAll(if (t.is_error) "error" else "output");
        try w.writeAll("\":");
        try json.writeString(w, t.text);
        try w.writeAll("}}}");
    }
    try w.writeAll("]}");
}

fn writeTools(w: *std.Io.Writer, a: std.mem.Allocator, tools_json: []const u8) !void {
    if (tools_json.len == 0) return;
    const root = std.json.parseFromSliceLeaky(Value, a, tools_json, .{}) catch return;
    if (root != .array) return;
    try w.writeAll(",\"tools\":[{\"functionDeclarations\":[");
    for (root.array.items, 0..) |tool, i| {
        if (i > 0) try w.writeByte(',');
        const obj = tool.object;
        try w.writeAll("{\"name\":");
        try json.writeString(w, obj.get("name").?.string);
        try w.writeAll(",\"description\":");
        try json.writeString(w, obj.get("description").?.string);
        try w.writeAll(",\"parametersJsonSchema\":");
        try std.json.Stringify.value(obj.get("parameters").?, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("]}]");
}

/// Thinking budget per effort. `off` disables thinking entirely.
fn budgetFor(effort: []const u8) ?u64 {
    const map = .{
        .{ "off", 0 },
        .{ "minimal", 512 },
        .{ "low", 1024 },
        .{ "medium", 4096 },
        .{ "high", 8192 },
        .{ "xhigh", 16384 },
        .{ "max", 24576 },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, effort, entry[0])) return entry[1];
    }
    return null;
}

fn buildBody(req: api.Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(req.scratch);
    const w = &out.writer;

    try w.writeAll("{\"contents\":[");
    var first = true;
    var i: usize = 0;
    while (i < req.messages.len) {
        if (req.messages[i] == .tool_result) {
            const start = i;
            while (i < req.messages.len and req.messages[i] == .tool_result) : (i += 1) {}
            if (!first) try w.writeByte(',');
            first = false;
            try writeToolResults(w, req.messages[start..i]);
            continue;
        }
        if (!first) try w.writeByte(',');
        first = false;
        try writeContent(w, req.messages[i]);
        i += 1;
    }
    try w.writeByte(']');

    if (req.system_prompt.len > 0) {
        try w.writeAll(",\"systemInstruction\":{\"parts\":[");
        try writeText(w, req.system_prompt);
        try w.writeAll("]}");
    }

    try writeTools(w, req.scratch, req.tools_json);

    var generation = false;
    if (req.model.max_tokens > 0) {
        try w.writeAll(",\"generationConfig\":{\"maxOutputTokens\":");
        try json.writeUint(w, req.model.max_tokens);
        generation = true;
    }
    if (budgetFor(req.effort)) |budget| {
        if (!generation) {
            try w.writeAll(",\"generationConfig\":{");
        } else {
            try w.writeByte(',');
        }
        try w.writeAll("\"thinkingConfig\":{");
        if (budget > 0) try w.writeAll("\"includeThoughts\":true,");
        try w.writeAll("\"thinkingBudget\":");
        try json.writeUint(w, budget);
        try w.writeByte('}');
        generation = true;
    }
    if (generation) try w.writeByte('}');
    try w.writeByte('}');
    return out.written();
}

fn buildUrl(a: std.mem.Allocator, base: []const u8, id: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const model = if (std.mem.startsWith(u8, id, "models/")) id else try std.fmt.allocPrint(a, "models/{s}", .{id});
    return std.fmt.allocPrint(a, "{s}/{s}:streamGenerateContent?alt=sse", .{ trimmed, model });
}

fn headers(a: std.mem.Allocator, req: api.Request, key: []const u8) ![]http.Header {
    var list: std.ArrayList(http.Header) = .empty;
    errdefer list.deinit(a);
    try list.append(a, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(a, .{ .name = "Accept", .value = "text/event-stream" });
    if (key.len > 0) try list.append(a, .{ .name = "x-goog-api-key", .value = key });
    for (req.model.headers) |kv| try list.append(a, .{ .name = kv[0], .value = kv[1] });
    if (req.session_id) |sid| {
        if (req.model.session_header) |name| {
            if (sid.len > 0) try list.append(a, .{ .name = name, .value = sid });
        }
    }
    return list.toOwnedSlice(a);
}

// ---- streaming state ------------------------------------------------------

const Call = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
    thought_signature: ?[]const u8 = null,
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
    finish: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
};

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

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn applyCost(model: *const types.Model, u: *types.Usage) void {
    const m = 1_000_000.0;
    u.cost_input = @as(f64, @floatFromInt(u.input)) * model.cost_input / m;
    u.cost_output = @as(f64, @floatFromInt(u.output)) * model.cost_output / m;
    u.cost_cache_read = @as(f64, @floatFromInt(u.cache_read)) * model.cost_cache_read / m;
    u.cost_cache_write = 0;
    u.cost_total = u.cost_input + u.cost_output + u.cost_cache_read + u.cost_cache_write;
}

fn addCall(st: *State, part: std.json.ObjectMap) !void {
    const fc = part.get("functionCall") orelse return;
    if (fc != .object) return;
    const name = stringField(fc.object, "name") orelse "";
    const call = try st.calls.addOne(st.req.pers);
    call.* = .{ .name = try st.req.pers.dupe(u8, name) };
    // Google omits a call id, so derive a stable one from the name and order.
    call.id = try std.fmt.allocPrint(st.req.pers, "{s}_{d}", .{ call.name, st.calls.items.len });
    if (stringField(part, "thoughtSignature")) |sig| {
        call.thought_signature = try st.req.pers.dupe(u8, sig);
    }
    if (call.name.len > 0) st.sink.emit(.{ .tool_start = call.name });
    if (fc.object.get("args")) |args| {
        if (args != .null) {
            var out: std.Io.Writer.Allocating = .init(st.req.pers);
            try std.json.Stringify.value(args, .{}, &out.writer);
            try call.args.appendSlice(st.req.pers, out.written());
        }
    }
}

fn handle(st: *State, obj: std.json.ObjectMap) !void {
    if (obj.get("error")) |err| {
        if (err == .object) {
            const message = stringField(err.object, "message") orelse "stream: provider error";
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
        }
        return;
    }

    if (obj.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const candidate = candidates.array.items[0];
            if (candidate == .object) {
                if (candidate.object.get("content")) |content| {
                    if (content == .object) {
                        if (content.object.get("parts")) |parts| {
                            if (parts == .array) {
                                for (parts.array.items) |part| {
                                    if (part != .object) continue;
                                    if (part.object.get("functionCall")) |fc| {
                                        if (fc == .object) try addCall(st, part.object);
                                        continue;
                                    }
                                    const text = stringField(part.object, "text") orelse continue;
                                    const thought = part.object.get("thought") orelse Value{ .null = {} };
                                    if (thought == .bool and thought.bool) {
                                        try st.reasoning.appendSlice(st.req.pers, text);
                                        st.sink.emit(.{ .reasoning = text });
                                    } else {
                                        try st.text.appendSlice(st.req.pers, text);
                                        st.sink.emit(.{ .text = text });
                                    }
                                }
                            }
                        }
                    }
                }
                if (stringField(candidate.object, "finishReason")) |fr| {
                    st.finish = try st.req.pers.dupe(u8, fr);
                }
            }
        }
    }

    if (obj.get("usageMetadata")) |usage| {
        if (usage == .object) {
            st.tokens_in = numField(usage.object, "promptTokenCount");
            st.tokens_out = numField(usage.object, "candidatesTokenCount") + numField(usage.object, "thoughtsTokenCount");
            st.tokens_total = numField(usage.object, "totalTokenCount");
        }
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
        has_calls = true;
        const arguments = if (call.args.items.len > 0) call.args.items else "{}";
        try st.msg.content.append(a, .{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = arguments,
            .thought_signature = call.thought_signature,
        } });
        st.sink.emit(.{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = arguments,
        } });
    }

    var usage = types.Usage{};
    usage.input = st.tokens_in;
    usage.output = st.tokens_out;
    usage.total_tokens = if (st.tokens_total > 0) st.tokens_total else st.tokens_in + st.tokens_out;
    applyCost(st.req.model, &usage);
    st.msg.usage = usage;

    st.msg.raw_stop_reason = st.finish;
    if (st.finish) |finish| {
        if (std.mem.eql(u8, finish, "MAX_TOKENS")) {
            st.msg.stop_reason = .length;
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
    const url = buildUrl(req.scratch, req.model.base_url, req.model.id) catch return error.OutOfMemory;
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
