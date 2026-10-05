const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");

const ToolCall = struct {
    id: []const u8,
    @"type": []const u8 = "function",
    function: struct { name: []const u8, arguments: []const u8 },
};

const Assistant = struct {
    role: []const u8 = "assistant",
    content: []const u8,
    tool_calls: ?[]const ToolCall = null,
};

const Tool = struct {
    role: []const u8 = "tool",
    @"tool_call_id": []const u8,
    content: []const u8,
};

const TextPart = struct { @"type": []const u8 = "text", text: []const u8 };
const UrlImagePart = struct {
    @"type": []const u8 = "image_url",
    @"image_url": struct { url: []const u8 },
};

const Part = union(enum) {
    text: TextPart,
    image: UrlImagePart,

    pub fn jsonStringify(self: Part, jws: anytype) !void {
        switch (self) {
            inline else => |v| try jws.write(v),
        }
    }
};

const Images = struct {
    role: []const u8 = "user",
    content: []const Part,
};

const Message = union(enum) {
    system: struct { role: []const u8 = "system", content: []const u8 },
    user: struct { role: []const u8 = "user", content: []const u8 },
    assistant: Assistant,
    tool: Tool,
    images: Images,

    pub fn jsonStringify(self: Message, jws: anytype) !void {
        switch (self) {
            inline else => |v| try jws.write(v),
        }
    }
};

const Body = struct {
    model: []const u8,
    stream: bool = true,
    @"stream_options": struct { @"include_usage": bool = true } = .{},
    @"reasoning_effort": ?[]const u8 = null,
    messages: []const Message,
    tools: ?api.Tools = null,
};

fn toolCall(block: types.ContentBlock, a: std.mem.Allocator) !?ToolCall {
    if (block != .tool_call) return null;
    const c = block.tool_call;
    _ = a;
    return .{ .id = c.id, .function = .{ .name = c.name, .arguments = api.argumentsOrObject(c.arguments) } };
}

fn imageParts(a: std.mem.Allocator, run: []const types.Message) ![]const Part {
    var parts: std.ArrayList(Part) = .empty;
    try parts.append(a, .{ .text = .{ .text = "Attached image(s) from tool result:" } });
    for (run) |msg| {
        for (msg.tool_result.images) |img| {
            try parts.append(a, .{ .image = .{ .@"image_url" = .{
                .url = try std.fmt.allocPrint(a, "data:{s};base64,{s}", .{ img.mime_type, img.data }),
            } } });
        }
    }
    return parts.items;
}

fn buildMessages(a: std.mem.Allocator, req: api.Request) ![]const Message {
    var out: std.ArrayList(Message) = .empty;
    if (req.system_prompt.len > 0) {
        try out.append(a, .{ .system = .{ .content = req.system_prompt } });
    }
    var i: usize = 0;
    while (i < req.messages.len) {
        if (req.messages[i] == .tool_result) {
            const start = i;
            var images = false;
            while (i < req.messages.len and req.messages[i] == .tool_result) : (i += 1) {
                const t = req.messages[i].tool_result;
                try out.append(a, .{ .tool = .{
                    .@"tool_call_id" = t.tool_call_id,
                    .content = if (t.text.len > 0 or t.images.len == 0) t.text else "(see attached image)",
                } });
                if (t.images.len > 0) images = true;
            }
            if (images) try out.append(a, .{ .images = .{ .content = try imageParts(a, req.messages[start..i]) } });
            continue;
        }
        switch (req.messages[i]) {
            .user => |u| try out.append(a, .{ .user = .{ .content = u.content } }),
            .assistant => |am| {
                var calls: std.ArrayList(ToolCall) = .empty;
                for (am.content.items) |block| {
                    if (try toolCall(block, a)) |c| try calls.append(a, c);
                }
                try out.append(a, .{ .assistant = .{
                    .content = try types.assistantText(a, am),
                    .tool_calls = if (calls.items.len > 0) calls.items else null,
                } });
            },
            .tool_result => unreachable,
        }
        i += 1;
    }
    return out.items;
}

fn buildBody(req: api.Request) ![]u8 {
    const a = req.scratch;
    const effort = if (req.effort.len > 0 and !std.mem.eql(u8, req.effort, "off")) req.effort else null;
    const body = Body{
        .model = req.model.id,
        .@"reasoning_effort" = effort,
        .messages = try buildMessages(a, req),
        .tools = if (req.tools_json.len > 0) .{ .a = a, .json = req.tools_json, .form = .{
            .open = "[",
            .entry = "{\"type\":\"function\",\"function\":{",
            .params_key = "parameters",
            .entry_close = "}}",
            .close = "]",
        } } else null,
    };
    return std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false });
}

const Chunk = struct {
    id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    @"error": ?api.ErrField = null,
    usage: ?Usage = null,
    choices: []const Choice = &.{},

    const Choice = struct {
        delta: ?Delta = null,
        @"finish_reason": ?[]const u8 = null,
    };

    const Delta = struct {
        content: ?[]const u8 = null,
        @"reasoning_content": ?[]const u8 = null,
        reasoning: ?[]const u8 = null,
        @"reasoning_text": ?[]const u8 = null,
        @"tool_calls": ?[]const ToolCallDelta = null,
    };

    const ToolCallDelta = struct {
        index: ?i64 = null,
        id: ?[]const u8 = null,
        function: ?Function = null,
        const Function = struct { name: ?[]const u8 = null, arguments: ?[]const u8 = null };
    };

    const Usage = struct {
        @"prompt_tokens": api.Count = .{},
        @"completion_tokens": api.Count = .{},
        @"prompt_tokens_details": ?Detail = null,
        @"cached_tokens": api.Count = .{},
        @"completion_tokens_details": ?Reasoning = null,

        const Detail = struct {
            @"cached_tokens": api.Count = .{},
            @"cache_write_tokens": api.Count = .{},
        };
        const Reasoning = struct { @"reasoning_tokens": ?api.Count = null };
    };
};

const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };

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
    failed: bool = false,

    pub fn handle(st: *State, chunk: Chunk) !void {
        if (chunk.@"error") |err| {
            if (err.message) |m| {
                if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, m);
                return;
            }
        }

        if (st.msg.response_id == null) {
            if (chunk.id) |v| {
                if (v.len > 0) st.msg.response_id = try st.req.pers.dupe(u8, v);
            }
        }
        if (st.msg.response_model == null) {
            if (chunk.model) |v| {
                if (v.len > 0 and !std.mem.eql(u8, v, st.req.model.id)) {
                    st.msg.response_model = try st.req.pers.dupe(u8, v);
                }
            }
        }

        if (chunk.choices.len > 0) {
            const choice = chunk.choices[0];
            if (choice.delta) |delta| try handleDelta(st, delta);
            if (choice.@"finish_reason") |fr| {
                if (fr.len > 0) st.finish_reason = try st.req.pers.dupe(u8, fr);
            }
        }

        if (chunk.usage) |u| st.usage = usageOf(u);
    }
};

fn handleDelta(st: *State, delta: Chunk.Delta) !void {
    if (delta.content) |s| {
        if (s.len > 0) {
            try st.text.appendSlice(st.req.pers, s);
            st.sink.emit(.{ .text = s });
        }
    }

    inline for (reasoning_fields) |field| {
        if (@field(delta, field)) |s| {
            if (s.len > 0) {
                if (st.signature == null) st.signature = field;
                try st.thinking.appendSlice(st.req.pers, s);
                st.sink.emit(.{ .reasoning = s });
                break;
            }
        }
    }

    for (delta.@"tool_calls" orelse &.{}) |tc| {
        const call = try api.blockAt(api.Call, &st.calls, st.req.pers, tc.index orelse -1);
        if (tc.id) |id| {
            if (id.len > 0 and call.id.len == 0) call.id = try st.req.pers.dupe(u8, id);
        }
        const fn_ = tc.function orelse continue;
        if (fn_.name) |name| {
            if (name.len > 0) try call.announce(st.req.pers, st.sink, name);
        }
        if (fn_.arguments) |args| try call.args.appendSlice(st.req.pers, args);
    }
}

fn usageOf(u: Chunk.Usage) types.Usage {
    var cache_read = if (u.@"prompt_tokens_details") |d| d.@"cached_tokens".value else 0;
    if (cache_read == 0) cache_read = u.@"cached_tokens".value;
    const cache_write = if (u.@"prompt_tokens_details") |d| d.@"cache_write_tokens".value else 0;
    var usage = types.Usage{
        .input = u.@"prompt_tokens".value -| cache_read -| cache_write,
        .output = u.@"completion_tokens".value,
        .cache_read = cache_read,
        .cache_write = cache_write,
    };
    if (u.@"completion_tokens_details") |d| {
        if (d.@"reasoning_tokens") |r| usage.reasoning = r.value;
    }
    return usage;
}

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
    return api.run(State, Chunk, wire, req, sink, finalize);
}
