const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");

const anthropic_version = "2023-06-01";

const ImageSource = struct {
    type: []const u8 = "base64",
    media_type: []const u8,
    data: []const u8,
};

const ImageBlock = struct {
    type: []const u8 = "image",
    source: ImageSource,
};

const TextBlock = struct { type: []const u8 = "text", text: []const u8 };

const ThinkingBlock = struct {
    type: []const u8 = "thinking",
    thinking: []const u8,
    signature: []const u8,
};

const ToolUseBlock = struct {
    type: []const u8 = "tool_use",
    id: []const u8,
    name: []const u8,
    input: api.Raw,
};

const ResultContent = union(enum) {
    text: TextBlock,
    image: ImageBlock,

    pub fn jsonStringify(self: ResultContent, jws: anytype) !void {
        switch (self) {
            inline else => |v| try jws.write(v),
        }
    }
};

const ToolResultBlock = struct {
    type: []const u8 = "tool_result",
    tool_use_id: []const u8,
    is_error: ?bool = null,
    content: Content,
    const Content = union(enum) {
        text: []const u8,
        parts: []const ResultContent,

        pub fn jsonStringify(self: Content, jws: anytype) !void {
            switch (self) {
                .text => |v| try jws.write(v),
                .parts => |v| try jws.write(v),
            }
        }
    };
};

const AssistantBlock = union(enum) {
    text: TextBlock,
    thinking: ThinkingBlock,
    plain: TextBlock,
    tool_use: ToolUseBlock,

    pub fn jsonStringify(self: AssistantBlock, jws: anytype) !void {
        switch (self) {
            inline else => |v| try jws.write(v),
        }
    }
};

const AssistantMessage = struct {
    role: []const u8 = "assistant",
    content: []const AssistantBlock,
};

const Message = union(enum) {
    user_text: struct { role: []const u8 = "user", content: []const TextBlock },
    user_results: struct { role: []const u8 = "user", content: []const ToolResultBlock },
    assistant: AssistantMessage,

    pub fn jsonStringify(self: Message, jws: anytype) !void {
        switch (self) {
            inline else => |v| try jws.write(v),
        }
    }
};

const Thinking = struct { type: []const u8 = "enabled", budget_tokens: u64 };

const Body = struct {
    model: []const u8,
    max_tokens: u64,
    stream: bool = true,
    system: ?[]const u8 = null,
    thinking: ?Thinking = null,
    messages: []const Message,
    tools: ?api.Tools = null,
};

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

fn resultContent(a: std.mem.Allocator, t: types.ToolResultMessage) !ToolResultBlock.Content {
    if (t.images.len == 0) return .{ .text = t.text };
    var parts: std.ArrayList(ResultContent) = .empty;
    try parts.append(a, .{ .text = .{ .text = t.text } });
    for (t.images) |img| {
        try parts.append(a, .{ .image = .{ .source = .{ .media_type = img.mime_type, .data = img.data } } });
    }
    return .{ .parts = parts.items };
}

fn assistantBlocks(a: std.mem.Allocator, am: *const types.AssistantMessage) ![]const AssistantBlock {
    var blocks: std.ArrayList(AssistantBlock) = .empty;
    for (am.content.items) |block| switch (block) {
        .text => |t| try blocks.append(a, .{ .text = .{ .text = t } }),
        .thinking => |t| {
            if (t.signature) |sig| {
                if (sig.len > 0) {
                    try blocks.append(a, .{ .thinking = .{ .thinking = t.text, .signature = sig } });
                    continue;
                }
            }
            try blocks.append(a, .{ .plain = .{ .text = t.text } });
        },
        .tool_call => |c| try blocks.append(a, .{ .tool_use = .{
            .id = c.id,
            .name = c.name,
            .input = .{ .bytes = api.argumentsOrObject(c.arguments) },
        } }),
    };
    return blocks.items;
}

fn buildMessages(a: std.mem.Allocator, req: api.Request) ![]const Message {
    var out: std.ArrayList(Message) = .empty;
    var i: usize = 0;
    while (i < req.messages.len) {
        if (req.messages[i] == .tool_result) {
            var blocks: std.ArrayList(ToolResultBlock) = .empty;
            while (i < req.messages.len and req.messages[i] == .tool_result) : (i += 1) {
                const t = req.messages[i].tool_result;
                try blocks.append(a, .{
                    .tool_use_id = t.tool_call_id,
                    .is_error = if (t.is_error) true else null,
                    .content = try resultContent(a, t),
                });
            }
            try out.append(a, .{ .user_results = .{ .content = blocks.items } });
            continue;
        }
        switch (req.messages[i]) {
            .user => |u| {
                const blocks = try a.alloc(TextBlock, 1);
                blocks[0] = .{ .text = u.content };
                try out.append(a, .{ .user_text = .{ .content = blocks } });
            },
            .assistant => |am| try out.append(a, .{ .assistant = .{
                .content = try assistantBlocks(a, am),
            } }),
            .tool_result => unreachable,
        }
        i += 1;
    }
    return out.items;
}

fn buildBody(req: api.Request) ![]u8 {
    const a = req.scratch;
    const budget = budgetFor(req.effort);
    var max_tokens: u64 = if (req.model.max_tokens > 0) req.model.max_tokens else 8192;
    if (budget > 0 and max_tokens <= budget) max_tokens = budget + 4096;
    const body = Body{
        .model = req.model.id,
        .max_tokens = max_tokens,
        .system = if (req.system_prompt.len > 0) req.system_prompt else null,
        .thinking = if (budget > 0) .{ .budget_tokens = budget } else null,
        .messages = try buildMessages(a, req),
        .tools = if (req.tools_json.len > 0) .{ .a = a, .json = req.tools_json, .form = .{
            .open = "[",
            .entry = "{",
            .params_key = "input_schema",
            .entry_close = "}",
            .close = "]",
        } } else null,
    };
    return std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false });
}

const BlockKind = enum { text, thinking, tool };

const Block = struct {
    kind: BlockKind = .text,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    call: usize = 0,
};

const Chunk = struct {
    type: ?[]const u8 = null,
    @"error": ?api.ErrField = null,
    index: ?i64 = null,
    message: ?MessageStart = null,
    content_block: ?BlockStart = null,
    delta: ?Delta = null,
    usage: ?Usage = null,

    const MessageStart = struct {
        id: ?[]const u8 = null,
        usage: ?Usage = null,
    };

    const BlockStart = struct {
        type: ?[]const u8 = null,
        id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        data: ?[]const u8 = null,
    };

    const Delta = struct {
        type: ?[]const u8 = null,
        text: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        signature: ?[]const u8 = null,
        partial_json: ?[]const u8 = null,
        stop_reason: ?[]const u8 = null,
    };

    const Usage = struct {
        input_tokens: api.Count = .{},
        output_tokens: api.Count = .{},
        cache_read_input_tokens: api.Count = .{},
        cache_creation_input_tokens: api.Count = .{},
        output_tokens_details: ?struct { thinking_tokens: api.Count = .{} } = null,
    };
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
    failed: bool = false,

    pub fn handle(st: *State, chunk: Chunk) !void {
        const event_type = chunk.type orelse "";

        if (std.mem.eql(u8, event_type, "error")) {
            const message = if (chunk.@"error") |e| e.message orelse "stream: provider error" else "stream: provider error";
            try api.keepString(&st.stream_error, st.req.pers, message);
            return;
        }

        if (std.mem.eql(u8, event_type, "message_start")) {
            const message = chunk.message orelse return;
            try api.keepString(&st.msg.response_id, st.req.pers, message.id);
            if (message.usage) |u| {
                st.usage.input = u.input_tokens.value;
                st.usage.output = u.output_tokens.value;
                st.usage.cache_read = u.cache_read_input_tokens.value;
                st.usage.cache_write = u.cache_creation_input_tokens.value;
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_start")) {
            const block = try api.blockAt(Block, &st.blocks, st.req.pers, chunk.index orelse -1);
            const cb = chunk.content_block orelse return;
            const bt = cb.type orelse "";
            if (std.mem.eql(u8, bt, "tool_use")) {
                block.kind = .tool;
                block.call = st.calls.items.len;
                const call = try st.calls.addOne(st.req.pers);
                call.* = .{};
                if (cb.id) |id| {
                    if (id.len > 0) call.id = try st.req.pers.dupe(u8, id);
                }
                try call.announce(st.req.pers, st.sink, cb.name orelse "");
            } else if (std.mem.eql(u8, bt, "thinking") or std.mem.eql(u8, bt, "redacted_thinking")) {
                block.kind = .thinking;
                if (std.mem.eql(u8, bt, "redacted_thinking")) {
                    if (cb.data) |d| try block.signature.appendSlice(st.req.pers, d);
                }
            } else {
                block.kind = .text;
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "content_block_delta")) {
            const idx = chunk.index orelse -1;
            if (idx < 0 or idx >= st.blocks.items.len) return;
            const delta = chunk.delta orelse return;
            const block = &st.blocks.items[@intCast(idx)];
            const call = if (block.kind == .tool) &st.calls.items[block.call] else null;
            const dt = delta.type orelse "";
            if (std.mem.eql(u8, dt, "text_delta")) {
                if (delta.text) |s| {
                    try block.text.appendSlice(st.req.pers, s);
                    st.sink.emit(.{ .text = s });
                }
            } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                if (delta.thinking) |s| {
                    try block.text.appendSlice(st.req.pers, s);
                    st.sink.emit(.{ .reasoning = s });
                }
            } else if (std.mem.eql(u8, dt, "signature_delta")) {
                if (delta.signature) |s| try block.signature.appendSlice(st.req.pers, s);
            } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                if (call) |c| {
                    if (delta.partial_json) |s| try c.args.appendSlice(st.req.pers, s);
                }
            }
            return;
        }

        if (std.mem.eql(u8, event_type, "message_delta")) {
            if (chunk.delta) |delta| {
                if (delta.stop_reason) |s| {
                    if (s.len > 0) st.stop_reason = try st.req.pers.dupe(u8, s);
                }
            }
            if (chunk.usage) |u| {
                st.usage.input = u.input_tokens.value;
                st.usage.output = u.output_tokens.value;
                st.usage.cache_read = u.cache_read_input_tokens.value;
                st.usage.cache_write = u.cache_creation_input_tokens.value;
                if (u.output_tokens_details) |d| st.usage.reasoning = d.thinking_tokens.value;
            }
            return;
        }
    }
};

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
    return api.run(State, Chunk, wire, req, sink, finalize);
}
