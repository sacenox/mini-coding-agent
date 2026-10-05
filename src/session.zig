//! Append-only JSONL session log. One record per line, fsynced on write.
//! Committed lines are never rewritten or deleted; a write failure is returned
//! to the caller so it can stop the turn.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");
const types = @import("types.zig");

const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

/// A value written byte-for-byte as it stands, never re-encoded. The struct
/// field that holds it supplies the key, so only the value is written here.
const Raw = struct {
    bytes: []const u8 = "",
    pub fn jsonStringify(self: Raw, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.bytes);
        jws.endWriteRaw();
    }
};

const StopReason = enum {
    pending,
    stop,
    length,
    tool_use,
    err,
    aborted,

    pub fn jsonStringify(self: StopReason, jws: anytype) !void {
        try jws.write(@as([]const u8, switch (self) {
            .pending => "pending",
            .stop => "stop",
            .length => "length",
            .tool_use => "toolUse",
            .err => "error",
            .aborted => "aborted",
        }));
    }

    fn fromWire(reason: types.StopReason) StopReason {
        return switch (reason) {
            .pending => .pending,
            .stop => .stop,
            .length => .length,
            .tool_use => .tool_use,
            .err => .err,
            .aborted => .aborted,
        };
    }
};

const ThinkingBlock = struct {
    type: []const u8 = "thinking",
    thinking: []const u8,
    thinkingSignature: ?[]const u8 = null,
};
const CallBlock = struct {
    type: []const u8 = "toolCall",
    id: []const u8,
    name: []const u8,
    arguments: Raw,
    thoughtSignature: ?[]const u8 = null,
};
const Block = union(enum) {
    text: TextPart,
    thinking: ThinkingBlock,
    tool_call: CallBlock,

    pub fn jsonStringify(self: Block, jws: anytype) !void {
        switch (self) {
            .text => |v| try jws.write(v),
            .thinking => |v| try jws.write(v),
            .tool_call => |v| try jws.write(v),
        }
    }
};

const UserRecord = struct {
    role: []const u8 = "user",
    content: []const u8,
    timestamp: i64,
};

const TextPart = struct { type: []const u8 = "text", text: []const u8 };
const ImagePart = struct { type: []const u8 = "image", data: []const u8, mimeType: []const u8 };
const Part = union(enum) {
    text: TextPart,
    image: ImagePart,

    pub fn jsonStringify(self: Part, jws: anytype) !void {
        switch (self) {
            .text => |v| try jws.write(v),
            .image => |v| try jws.write(v),
        }
    }
};

const ToolResultRecord = struct {
    role: []const u8 = "toolResult",
    toolCallId: []const u8,
    toolName: []const u8,
    content: []const Part,
    isError: bool,
    timestamp: i64,
};

/// A number written byte-for-byte, so a non-finite cost becomes `null` rather
/// than the string `"nan"` std would emit.
const Number = struct {
    value: f64 = 0,
    pub fn jsonStringify(self: Number, jws: anytype) !void {
        if (!std.math.isFinite(self.value)) return jws.write(null);
        try jws.write(self.value);
    }
};

const UsageRecord = struct {
    input: u64 = 0,
    output: u64 = 0,
    cacheRead: u64 = 0,
    cacheWrite: u64 = 0,
    reasoning: ?u64 = null,
    totalTokens: u64 = 0,
    cost: struct {
        input: Number = .{},
        output: Number = .{},
        cacheRead: Number = .{},
        total: Number = .{},
    } = .{},
};

const AssistantRecord = struct {
    role: []const u8 = "assistant",
    content: []const Block,
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    usage: UsageRecord,
    stopReason: StopReason,
    timestamp: i64,
    responseId: ?[]const u8 = null,
    responseModel: ?[]const u8 = null,
    rawStopReason: ?[]const u8 = null,
    errorMessage: ?[]const u8 = null,
};

const MessageRecord = union(enum) {
    user: UserRecord,
    tool_result: ToolResultRecord,
    assistant: AssistantRecord,

    pub fn jsonStringify(self: MessageRecord, jws: anytype) !void {
        switch (self) {
            .user => |v| try jws.write(v),
            .tool_result => |v| try jws.write(v),
            .assistant => |v| try jws.write(v),
        }
    }
};

const MessageLine = struct {
    type: []const u8 = "message",
    at: []const u8,
    message: MessageRecord,
};

const RequestLine = struct {
    type: []const u8 = "request",
    at: []const u8,
    provider: []const u8,
    model: []const u8,
    api: []const u8,
    thinkingEffort: []const u8,
    systemPrompt: []const u8,
    tools: Raw,
};

const HeaderLine = struct {
    type: []const u8 = "session",
    version: u32 = 1,
    id: []const u8,
    cwd: []const u8,
    createdAt: []const u8,
    title: []const u8,
};

fn stringify(a: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false });
}

pub const Request = struct {
    provider: []const u8,
    model: []const u8,
    api: []const u8,
    thinking_effort: []const u8,
    system_prompt: []const u8,
    /// A pre-serialized JSON array of tool schemas, written verbatim.
    tools_json: []const u8,
};

pub const Session = struct {
    a: std.mem.Allocator,
    sessions_dir: []const u8,
    cwd: []const u8,
    /// The session directory name; the header of the request carries it.
    id: ?[]const u8 = null,
    file: ?std.Io.File = null,
    closed: bool = false,

    pub fn init(a: std.mem.Allocator, sessions_dir: []const u8, cwd: []const u8) Session {
        return .{ .a = a, .sessions_dir = sessions_dir, .cwd = cwd };
    }

    pub fn appendMessage(self: *Session, scratch: std.mem.Allocator, message: types.Message) !void {
        if (self.closed) return;
        try self.ensure(if (message == .user) util.slugify(self.a, message.user.content) else "session");

        var arena = std.heap.ArenaAllocator.init(scratch);
        defer arena.deinit();
        const a = arena.allocator();
        const line = try stringify(a, MessageLine{
            .at = util.isoAlloc(a),
            .message = try messageRecord(a, message),
        });
        try self.commitLine(scratch, line);
    }

    pub fn appendRequest(self: *Session, scratch: std.mem.Allocator, req: Request) !void {
        if (self.closed) return;
        try self.ensure("session");

        var arena = std.heap.ArenaAllocator.init(scratch);
        defer arena.deinit();
        const a = arena.allocator();
        const line = try stringify(a, RequestLine{
            .at = util.isoAlloc(a),
            .provider = req.provider,
            .model = req.model,
            .api = req.api,
            .thinkingEffort = req.thinking_effort,
            .systemPrompt = req.system_prompt,
            // A tool array is replayed verbatim; an absent one is an empty array.
            .tools = .{ .bytes = if (req.tools_json.len > 0) req.tools_json else "[]" },
        });
        try self.commitLine(scratch, line);
    }

    /// Appends the terminating newline to one serialized record and commits it.
    fn commitLine(self: *Session, scratch: std.mem.Allocator, line: []const u8) !void {
        var out: std.Io.Writer.Allocating = .init(scratch);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll(line);
        try w.writeByte('\n');
        try self.commit(out.written());
    }

    pub fn close(self: *Session) void {
        self.closed = true;
        if (self.file) |f| {
            f.close(platform.io);
            self.file = null;
        }
    }

    fn ensure(self: *Session, title: []const u8) !void {
        if (self.file != null) return;
        std.Io.Dir.cwd().createDirPath(platform.io, self.sessions_dir) catch {};
        var stamp_buf: [15]u8 = undefined;
        const stamp = util.stamp(&stamp_buf, util.nowMs());

        var attempt: usize = 0;
        while (attempt < 16) : (attempt += 1) {
            var id_buf: [6]u8 = undefined;
            shortId(&id_buf);
            const name = try std.fmt.allocPrint(self.a, "{s}-{s}-{s}", .{ stamp, title, &id_buf });
            const dir = try util.join(self.a, &.{ self.sessions_dir, name });
            std.Io.Dir.cwd().createDir(platform.io, dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => return e,
            };
            const log_path = try util.join(self.a, &.{ dir, "session.jsonl" });
            // The id is published only once the log is open, so a failure here
            // leaves the session retryable rather than naming a session whose
            // log does not exist.
            const file = try std.Io.Dir.cwd().createFile(platform.io, log_path, .{ .truncate = false });
            self.id = name;
            self.file = file;
            var header_buf: std.Io.Writer.Allocating = .init(self.a);
            defer header_buf.deinit();
            const w = &header_buf.writer;
            try w.writeAll(try stringify(self.a, HeaderLine{
                .id = name,
                .cwd = self.cwd,
                .createdAt = util.isoAlloc(self.a),
                .title = title,
            }));
            try w.writeByte('\n');
            try self.commit(header_buf.written());
            return;
        }
        return error.SessionDirectory;
    }

    fn commit(self: *Session, line: []const u8) !void {
        const f = self.file orelse return error.SessionNotOpen;
        try f.writeStreamingAll(platform.io, line);
        try f.sync(platform.io);
    }

    fn shortId(buf: *[6]u8) void {
        var bytes: [6]u8 = undefined;
        util.randomBytes(&bytes);
        for (bytes, 0..) |b, i| buf[i] = alphabet[b % 36];
    }
};

fn messageRecord(a: std.mem.Allocator, message: types.Message) !MessageRecord {
    switch (message) {
        .user => |u| return .{ .user = .{ .content = u.content, .timestamp = u.timestamp } },
        .tool_result => |t| {
            var parts: std.ArrayList(Part) = .empty;
            try parts.append(a, .{ .text = .{ .text = t.text } });
            for (t.images) |img| {
                try parts.append(a, .{ .image = .{ .data = img.data, .mimeType = img.mime_type } });
            }
            return .{ .tool_result = .{
                .toolCallId = t.tool_call_id,
                .toolName = t.tool_name,
                .content = try parts.toOwnedSlice(a),
                .isError = t.is_error,
                .timestamp = t.timestamp,
            } };
        },
        .assistant => |m| {
            var blocks: std.ArrayList(Block) = .empty;
            for (m.content.items) |block| try blocks.append(a, switch (block) {
                .text => |t| .{ .text = .{ .text = t } },
                .thinking => |t| .{ .thinking = .{ .thinking = t.text, .thinkingSignature = t.signature } },
                .tool_call => |c| .{ .tool_call = .{
                    .id = c.id,
                    .name = c.name,
                    .arguments = .{ .bytes = c.arguments },
                    .thoughtSignature = c.thought_signature,
                } },
            });
            return .{ .assistant = .{
                .content = try blocks.toOwnedSlice(a),
                .api = m.api,
                .provider = m.provider,
                .model = m.model,
                .usage = .{
                    .input = m.usage.input,
                    .output = m.usage.output,
                    .cacheRead = m.usage.cache_read,
                    .cacheWrite = m.usage.cache_write,
                    .reasoning = m.usage.reasoning,
                    .totalTokens = m.usage.total_tokens,
                    .cost = .{
                        .input = .{ .value = m.usage.cost_input },
                        .output = .{ .value = m.usage.cost_output },
                        .cacheRead = .{ .value = m.usage.cost_cache_read },
                        .total = .{ .value = m.usage.cost_total },
                    },
                },
                .stopReason = .fromWire(m.stop_reason),
                .timestamp = m.timestamp,
                .responseId = m.response_id,
                .responseModel = m.response_model,
                .rawStopReason = m.raw_stop_reason,
                .errorMessage = m.error_message,
            } };
        },
    }
}
