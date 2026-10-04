//! OpenAI-compatible chat completions with streaming. The wire format behind
//! opencode-go and every customProvider with api "openai-completions".

const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");
const json = @import("../json.zig");


// ---- request building -----------------------------------------------------

/// An assistant turn: its text, then one `tool_calls` entry per call. The
/// `tool_calls` key is written only when there is a call.
fn writeAssistant(w: *std.Io.Writer, am: *const types.AssistantMessage, a: std.mem.Allocator) !void {
    try w.writeAll("{\"role\":\"assistant\",\"content\":");
    try json.writeString(w, try types.assistantText(a, am));

    var calls: usize = 0;
    for (am.content.items) |block| {
        if (block != .tool_call) continue;
        if (calls > 0) try w.writeByte(',') else try w.writeAll(",\"tool_calls\":[");
        calls += 1;
        const call = block.tool_call;
        try w.writeAll("{\"id\":");
        try json.writeString(w, call.id);
        try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
        try json.writeString(w, call.name);
        try w.writeAll(",\"arguments\":");
        try json.writeString(w, api.argumentsOrObject(call.arguments));
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
    try api.writeTools(w, req.scratch, req.tools_json, .{
        .open = ",\"tools\":[",
        .entry = "{\"type\":\"function\",\"function\":{",
        .params_key = "parameters",
        .entry_close = "}}",
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
    thinking: std.ArrayList(u8) = .empty,
    signature: ?[]const u8 = null,
    calls: std.ArrayList(api.Call) = .empty,
    usage: types.Usage = .{},
    finish_reason: ?[]const u8 = null,
    stream_error: ?[]const u8 = null,
    /// Set by `run` when the stream did not run to completion.
    failed: bool = false,

    /// One payload, already parsed. Everything this wire records about the
    /// response it learns here; `run` owns the life cycle around it.
    pub fn handle(st: *State, obj: std.json.ObjectMap) !void {
        if (api.errorMessage(obj, "error")) |message| {
            if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, message);
            return;
        }

        if (st.msg.response_id == null) {
            if (api.stringField(obj, "id")) |v| st.msg.response_id = try st.req.pers.dupe(u8, v);
        }
        if (st.msg.response_model == null) {
            if (api.stringField(obj, "model")) |v| {
                if (!std.mem.eql(u8, v, st.req.model.id)) st.msg.response_model = try st.req.pers.dupe(u8, v);
            }
        }

        if (api.firstObjField(obj, "choices")) |choice| {
            if (api.objField(choice, "delta")) |delta| try handleDelta(st, delta);
            if (api.stringField(choice, "finish_reason")) |fr| {
                st.finish_reason = try st.req.pers.dupe(u8, fr);
            }
        }

        if (api.objField(obj, "usage")) |u| st.usage = usageOf(u);
    }
};

fn handleDelta(st: *State, delta: std.json.ObjectMap) !void {
    if (api.stringField(delta, "content")) |s| {
        try st.text.appendSlice(st.req.pers, s);
        st.sink.emit(.{ .text = s });
    }

    const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    for (reasoning_fields) |field| {
        if (api.stringField(delta, field)) |s| {
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
        const call = try api.blockAt(api.Call, &st.calls, st.req.pers, index);
        if (tc.object.get("id")) |id| {
            if (id == .string and call.id.len == 0) call.id = try st.req.pers.dupe(u8, id.string);
        }
        const fn_ = tc.object.get("function") orelse continue;
        if (fn_ != .object) continue;
        if (api.stringField(fn_.object, "name")) |name| {
            try call.announce(st.req.pers, st.sink, name);
        }
        if (fn_.object.get("arguments")) |args| {
            if (args == .string) try call.args.appendSlice(st.req.pers, args.string);
        }
    }
}

/// The usage facts one chunk carries. Every field is a delta on the running
/// total except the counts themselves, which the provider sends whole. A
/// prompt that is mostly a cache hit is billed as the difference, so the
/// cached and written-back tokens come out of `input`.
fn usageOf(u: std.json.ObjectMap) types.Usage {
    const details = api.objField(u, "prompt_tokens_details");
    var cache_read: u64 = if (details) |d| api.numField(d, "cached_tokens") else 0;
    if (cache_read == 0) cache_read = api.numField(u, "cached_tokens");
    const cache_write: u64 = if (details) |d| api.numField(d, "cache_write_tokens") else 0;
    var usage = types.Usage{
        .input = api.numField(u, "prompt_tokens") -| cache_read -| cache_write,
        .output = api.numField(u, "completion_tokens"),
        .cache_read = cache_read,
        .cache_write = cache_write,
    };
    if (api.objField(u, "completion_tokens_details")) |d| {
        usage.reasoning = api.optNumField(d, "reasoning_tokens");
    }
    return usage;
}

/// A stream that produced finished calls is a tool turn, not a stop. A broken
/// stream reports none, and `run` restores the transport's own reason.
fn mapStopReason(st: *State, has_calls: bool) void {
    if (has_calls) {
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
    const has_calls = try api.appendCalls(st.msg, st.sink, a, st.calls.items, st.failed);
    api.finishUsage(st.msg, st.req.model, st.usage);
    st.msg.raw_stop_reason = st.finish_reason;
    mapStopReason(st, has_calls);
}

const wire = api.Wire{
    .key_header = "Authorization",
    .key_prefix = "Bearer ",
    .path = "/chat/completions",
    .build_body = buildBody,
};

pub fn stream(req: api.Request, sink: api.Sink) std.mem.Allocator.Error!types.AssistantMessage {
    return api.run(State, wire, req, sink, finalize);
}
