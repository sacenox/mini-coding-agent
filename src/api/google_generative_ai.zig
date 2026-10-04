//! Google Generative AI (Gemini) streaming adapter. The wire format behind
//! every customProvider with api "google-generative-ai".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const json = @import("../json.zig");

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
    try w.writeAll(api.argumentsOrObject(c.arguments));
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
                .thinking => {},
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

    try api.writeTools(w, req.scratch, req.tools_json, .{
        .open = ",\"tools\":[{\"functionDeclarations\":[",
        .entry = "{",
        .params_key = "parametersJsonSchema",
        .entry_close = "}",
        .close = "]}]",
    });

    // `generationConfig` holds max tokens and, when the model thinks, the
    // thinking budget. It is written only when it has at least one field.
    if (req.model.max_tokens > 0 or budgetFor(req.effort) != null) {
        try w.writeAll(",\"generationConfig\":{");
        if (req.model.max_tokens > 0) {
            try w.writeAll("\"maxOutputTokens\":");
            try json.writeNum(w, req.model.max_tokens);
        }
        if (budgetFor(req.effort)) |budget| {
            if (req.model.max_tokens > 0) try w.writeByte(',');
            try w.writeAll("\"thinkingConfig\":{");
            if (budget > 0) try w.writeAll("\"includeThoughts\":true,");
            try w.writeAll("\"thinkingBudget\":");
            try json.writeNum(w, budget);
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
    try w.writeByte('}');
    return out.written();
}

/// Google addresses a model by path, not by a query parameter, and streams
/// through `:streamGenerateContent`. A model id that already names its path is
/// not prefixed twice.
fn buildUrl(a: std.mem.Allocator, req: api.Request) ![]u8 {
    const model = if (std.mem.startsWith(u8, req.model.id, "models/"))
        req.model.id
    else
        try std.fmt.allocPrint(a, "models/{s}", .{req.model.id});
    return std.fmt.allocPrint(a, "{s}/{s}:streamGenerateContent?alt=sse", .{
        std.mem.trimEnd(u8, req.model.base_url, "/"),
        model,
    });
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
    finish: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
    /// Set by `run` when the stream did not run to completion.
    failed: bool = false,

    pub fn handle(st: *State, obj: std.json.ObjectMap) !void {
        if (api.errorMessage(obj, "error")) |message| {
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
            return;
        }

        if (api.firstObjField(obj, "candidates")) |candidate| {
            if (api.objField(candidate, "content")) |content| {
                if (content.get("parts")) |parts| {
                    if (parts == .array) {
                        for (parts.array.items) |part| {
                            if (part != .object) continue;
                            if (part.object.get("functionCall") != null) {
                                try addCall(st, part.object);
                                continue;
                            }
                            const text = api.stringField(part.object, "text") orelse continue;
                            if (api.boolField(part.object, "thought", false)) {
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
            if (api.stringField(candidate, "finishReason")) |fr| {
                st.finish = try st.req.pers.dupe(u8, fr);
            }
        }

        if (api.objField(obj, "usageMetadata")) |u| {
            st.usage.input = api.numField(u, "promptTokenCount");
            st.usage.output = api.numField(u, "candidatesTokenCount") + api.numField(u, "thoughtsTokenCount");
            st.usage.total_tokens = api.numField(u, "totalTokenCount");
        }
    }
};

/// Google sends a whole call in one part, so a call is appended, not grown in
/// place. The id is derived from the name and order because Google omits one.
fn addCall(st: *State, part: std.json.ObjectMap) !void {
    const fc = api.objField(part, "functionCall") orelse return;
    const call = try st.calls.addOne(st.req.pers);
    call.* = .{};
    if (api.stringField(part, "thoughtSignature")) |sig| call.thought_signature = try st.req.pers.dupe(u8, sig);
    try call.announce(st.req.pers, st.sink, api.stringField(fc, "name") orelse "");
    if (fc.get("args")) |args| {
        if (args != .null) {
            var out: std.Io.Writer.Allocating = .init(st.req.pers);
            try std.json.Stringify.value(args, .{}, &out.writer);
            try call.args.appendSlice(st.req.pers, out.written());
        }
    }
}

fn finalize(st: *State) !void {
    const a = st.req.pers;
    if (st.reasoning.items.len > 0) try st.msg.content.append(a, .{ .thinking = .{ .text = st.reasoning.items } });
    if (st.text.items.len > 0) try st.msg.content.append(a, .{ .text = st.text.items });

    const has_calls = try api.appendCalls(st.msg, st.sink, a, st.calls.items, st.failed);

    api.finishUsage(st.msg, st.req.model, st.usage);

    st.msg.raw_stop_reason = st.finish;
    if (st.finish) |finish| {
        if (std.mem.eql(u8, finish, "MAX_TOKENS")) {
            st.msg.stop_reason = .length;
            return;
        }
    }
    st.msg.stop_reason = if (has_calls) .tool_use else .stop;
}

const wire = api.Wire{
    .key_header = "x-goog-api-key",
    .build_url = buildUrl,
    .build_body = buildBody,
};

pub fn stream(req: api.Request, sink: api.Sink) std.mem.Allocator.Error!types.AssistantMessage {
    return api.run(State, wire, req, sink, finalize);
}
