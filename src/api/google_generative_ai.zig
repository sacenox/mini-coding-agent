const std = @import("std");
const api = @import("../api.zig");
const types = @import("../types.zig");

const Part = struct {
    text: ?[]const u8 = null,
    @"inlineData": ?struct { @"mimeType": []const u8, data: []const u8 } = null,
    @"functionCall": ?struct { name: []const u8, args: api.Raw, @"thoughtSignature": ?[]const u8 = null } = null,
    @"functionResponse": ?struct {
        name: []const u8,
        response: Response,
        const Response = struct { output: ?[]const u8 = null, @"error": ?[]const u8 = null };
    } = null,
};

const Content = struct {
    role: []const u8,
    parts: []const Part,
};

const SystemInstruction = struct { parts: []const Part };

const GenerationConfig = struct {
    @"maxOutputTokens": ?u64 = null,
    @"thinkingConfig": ?struct { @"includeThoughts": bool = true, @"thinkingBudget": u64 } = null,
};

const Body = struct {
    contents: []const Content,
    @"systemInstruction": ?SystemInstruction = null,
    tools: ?api.Tools = null,
    @"generationConfig": ?GenerationConfig = null,
};

fn textPart(text: []const u8) Part {
    return .{ .text = text };
}

fn contentParts(a: std.mem.Allocator, msg: types.Message) ![]const Part {
    switch (msg) {
        .user => |u| {
            const parts = try a.alloc(Part, 1);
            parts[0] = textPart(u.content);
            return parts;
        },
        .assistant => |am| {
            var parts: std.ArrayList(Part) = .empty;
            for (am.content.items) |block| switch (block) {
                .text => |t| try parts.append(a, textPart(t)),
                .tool_call => |c| try parts.append(a, .{ .@"functionCall" = .{
                    .name = c.name,
                    .args = .{ .bytes = api.argumentsOrObject(c.arguments) },
                    .@"thoughtSignature" = c.thought_signature,
                } }),
                .thinking => {},
            };
            return parts.items;
        },
        .tool_result => unreachable,
    }
}

fn toolResultContent(a: std.mem.Allocator, run: []const types.Message) !Content {
    const parts = try a.alloc(Part, run.len);
    for (run, parts) |msg, *part| {
        const t = msg.tool_result;
        part.* = .{ .@"functionResponse" = .{ .name = t.tool_name, .response = if (t.is_error)
            .{ .@"error" = t.text }
        else
            .{ .output = t.text } } };
    }
    return .{ .role = "user", .parts = parts };
}

fn buildContents(a: std.mem.Allocator, req: api.Request) ![]const Content {
    var out: std.ArrayList(Content) = .empty;
    var i: usize = 0;
    while (i < req.messages.len) {
        if (req.messages[i] == .tool_result) {
            const start = i;
            while (i < req.messages.len and req.messages[i] == .tool_result) : (i += 1) {}
            try out.append(a, try toolResultContent(a, req.messages[start..i]));
            continue;
        }
        const msg = req.messages[i];
        try out.append(a, .{
            .role = if (msg == .assistant) "model" else "user",
            .parts = try contentParts(a, msg),
        });
        i += 1;
    }
    return out.items;
}

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
    const a = req.scratch;
    const budget = budgetFor(req.effort);
    const config: ?GenerationConfig = if (req.model.max_tokens > 0 or budget != null) .{
        .@"maxOutputTokens" = if (req.model.max_tokens > 0) req.model.max_tokens else null,
        .@"thinkingConfig" = if (budget) |b| .{ .@"includeThoughts" = b > 0, .@"thinkingBudget" = b } else null,
    } else null;
    const sys = if (req.system_prompt.len > 0) blk: {
        const parts = try a.alloc(Part, 1);
        parts[0] = textPart(req.system_prompt);
        break :blk SystemInstruction{ .parts = parts };
    } else null;
    const body = Body{
        .contents = try buildContents(a, req),
        .@"systemInstruction" = sys,
        .tools = if (req.tools_json.len > 0) .{ .a = a, .json = req.tools_json, .form = .{
            .open = "[{\"functionDeclarations\":[",
            .entry = "{",
            .params_key = "parametersJsonSchema",
            .entry_close = "}",
            .close = "]}]",
        } } else null,
        .@"generationConfig" = config,
    };
    return std.json.Stringify.valueAlloc(a, body, .{ .emit_null_optional_fields = false });
}

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

const Chunk = struct {
    @"error": ?api.ErrField = null,
    candidates: []const Candidate = &.{},
    @"usageMetadata": ?Usage = null,

    const Candidate = struct {
        content: ?struct { parts: []const Piece = &.{} } = null,
        @"finishReason": ?[]const u8 = null,
    };

    const Piece = struct {
        text: ?[]const u8 = null,
        thought: ?bool = null,
        @"functionCall": ?Function = null,
        @"thoughtSignature": ?[]const u8 = null,
        const Function = struct { name: ?[]const u8 = null, args: ?std.json.Value = null };
    };

    const Usage = struct {
        @"promptTokenCount": api.Count = .{},
        @"candidatesTokenCount": api.Count = .{},
        @"thoughtsTokenCount": api.Count = .{},
        @"totalTokenCount": api.Count = .{},
    };
};

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
    failed: bool = false,

    pub fn handle(st: *State, chunk: Chunk) !void {
        if (chunk.@"error") |err| {
            if (err.message) |m| {
                if (st.stream_error == null) st.stream_error = try st.req.pers.dupe(u8, m);
                return;
            }
        }

        if (chunk.candidates.len > 0) {
            const candidate = chunk.candidates[0];
            if (candidate.content) |content| {
                for (content.parts) |part| {
                    if (part.@"functionCall" != null) {
                        try addCall(st, part);
                        continue;
                    }
                    const text = part.text orelse continue;
                    if (part.thought orelse false) {
                        try st.reasoning.appendSlice(st.req.pers, text);
                        st.sink.emit(.{ .reasoning = text });
                    } else {
                        try st.text.appendSlice(st.req.pers, text);
                        st.sink.emit(.{ .text = text });
                    }
                }
            }
            if (candidate.@"finishReason") |fr| {
                if (fr.len > 0) st.finish = try st.req.pers.dupe(u8, fr);
            }
        }

        if (chunk.@"usageMetadata") |u| {
            st.usage.input = u.@"promptTokenCount".value;
            st.usage.output = u.@"candidatesTokenCount".value + u.@"thoughtsTokenCount".value;
            st.usage.total_tokens = u.@"totalTokenCount".value;
        }
    }
};

fn addCall(st: *State, part: Chunk.Piece) !void {
    const fc = part.@"functionCall" orelse return;
    const call = try st.calls.addOne(st.req.pers);
    call.* = .{};
    if (part.@"thoughtSignature") |sig| {
        if (sig.len > 0) call.thought_signature = try st.req.pers.dupe(u8, sig);
    }
    try call.announce(st.req.pers, st.sink, fc.name orelse "");
    if (fc.args) |args| {
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
    return api.run(State, Chunk, wire, req, sink, finalize);
}
