//! Append-only JSONL session log. One record per line, fsynced on write.
//! Committed lines are never rewritten or deleted; a write failure is returned
//! to the caller so it can stop the turn.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");
const json = @import("json.zig");
const types = @import("types.zig");

const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";

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
    id: ?[]const u8 = null,
    file: ?std.Io.File = null,
    closed: bool = false,

    pub fn init(a: std.mem.Allocator, sessions_dir: []const u8, cwd: []const u8) Session {
        return .{ .a = a, .sessions_dir = sessions_dir, .cwd = cwd };
    }

    pub fn appendMessage(self: *Session, scratch: std.mem.Allocator, message: types.Message) !void {
        if (self.closed) return;
        try self.ensure(if (message == .user) util.slugify(self.a, message.user.content) else "session");

        var out: std.Io.Writer.Allocating = .init(scratch);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"message\",\"at\":");
        try json.writeString(w, util.isoAlloc(scratch));
        try w.writeAll(",\"message\":");
        try writeMessage(w, message);
        try w.writeAll("}\n");
        try self.commit(out.written());
    }

    pub fn appendRequest(self: *Session, scratch: std.mem.Allocator, req: Request) !void {
        if (self.closed) return;
        try self.ensure("session");

        var out: std.Io.Writer.Allocating = .init(scratch);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"type\":\"request\",\"at\":");
        try json.writeString(w, util.isoAlloc(scratch));
        try w.writeAll(",\"provider\":");
        try json.writeString(w, req.provider);
        try w.writeAll(",\"model\":");
        try json.writeString(w, req.model);
        try w.writeAll(",\"api\":");
        try json.writeString(w, req.api);
        try w.writeAll(",\"thinkingEffort\":");
        try json.writeString(w, req.thinking_effort);
        try w.writeAll(",\"systemPrompt\":");
        try json.writeString(w, req.system_prompt);
        try w.writeAll(",\"tools\":");
        try w.writeAll(if (req.tools_json.len > 0) req.tools_json else "[]");
        try w.writeAll("}\n");
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
            self.id = name;
            const log_path = try util.join(self.a, &.{ dir, "session.jsonl" });
            self.file = try std.Io.Dir.cwd().createFile(platform.io, log_path, .{ .truncate = false });
            var header_buf: std.Io.Writer.Allocating = .init(self.a);
            const w = &header_buf.writer;
            try w.writeAll("{\"type\":\"session\",\"version\":1,\"id\":");
            try json.writeString(w, name);
            try w.writeAll(",\"cwd\":");
            try json.writeString(w, self.cwd);
            try w.writeAll(",\"createdAt\":");
            try json.writeString(w, util.isoAlloc(self.a));
            try w.writeAll(",\"title\":");
            try json.writeString(w, title);
            try w.writeAll("}\n");
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

fn writeMessage(w: *std.Io.Writer, message: types.Message) !void {
    switch (message) {
        .user => |u| {
            try w.writeAll("{\"role\":\"user\",\"content\":");
            try json.writeString(w, u.content);
            try w.writeAll(",\"timestamp\":");
            try json.writeInt(w, u.timestamp);
            try w.writeByte('}');
        },
        .tool_result => |t| {
            try w.writeAll("{\"role\":\"toolResult\",\"toolCallId\":");
            try json.writeString(w, t.tool_call_id);
            try w.writeAll(",\"toolName\":");
            try json.writeString(w, t.tool_name);
            try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
            try json.writeString(w, t.text);
            try w.writeByte('}');
            for (t.images) |img| {
                try w.writeAll(",{\"type\":\"image\",\"data\":");
                try json.writeString(w, img.data);
                try w.writeAll(",\"mimeType\":");
                try json.writeString(w, img.mime_type);
                try w.writeByte('}');
            }
            try w.writeByte(']');
            try w.writeAll(",\"isError\":");
            try json.writeBool(w, t.is_error);
            try w.writeAll(",\"timestamp\":");
            try json.writeInt(w, t.timestamp);
            try w.writeByte('}');
        },
        .assistant => |m| {
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            for (m.content.items, 0..) |block, i| {
                if (i > 0) try w.writeByte(',');
                switch (block) {
                    .text => |t| {
                        try w.writeAll("{\"type\":\"text\",\"text\":");
                        try json.writeString(w, t);
                        try w.writeByte('}');
                    },
                    .thinking => |t| {
                        try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
                        try json.writeString(w, t.text);
                        if (t.signature) |sig| {
                            try w.writeAll(",\"thinkingSignature\":");
                            try json.writeString(w, sig);
                        }
                        try w.writeByte('}');
                    },
                    .tool_call => |c| {
                        try w.writeAll("{\"type\":\"toolCall\",\"id\":");
                        try json.writeString(w, c.id);
                        try w.writeAll(",\"name\":");
                        try json.writeString(w, c.name);
                        try w.writeAll(",\"arguments\":");
                        try w.writeAll(c.arguments);
                        if (c.thought_signature) |sig| {
                            try w.writeAll(",\"thoughtSignature\":");
                            try json.writeString(w, sig);
                        }
                        try w.writeByte('}');
                    },
                    .image => |img| {
                        try w.writeAll("{\"type\":\"image\",\"data\":");
                        try json.writeString(w, img.data);
                        try w.writeAll(",\"mimeType\":");
                        try json.writeString(w, img.mime_type);
                        try w.writeByte('}');
                    },
                }
            }
            try w.writeAll("],\"api\":");
            try json.writeString(w, m.api);
            try w.writeAll(",\"provider\":");
            try json.writeString(w, m.provider);
            try w.writeAll(",\"model\":");
            try json.writeString(w, m.model);
            try w.writeAll(",\"usage\":");
            try writeUsage(w, m.usage);
            try w.writeAll(",\"stopReason\":");
            try json.writeString(w, m.stop_reason.wire());
            try w.writeAll(",\"timestamp\":");
            try json.writeInt(w, m.timestamp);
            if (m.response_id) |v| {
                try w.writeAll(",\"responseId\":");
                try json.writeString(w, v);
            }
            if (m.response_model) |v| {
                try w.writeAll(",\"responseModel\":");
                try json.writeString(w, v);
            }
            if (m.raw_stop_reason) |v| {
                try w.writeAll(",\"rawStopReason\":");
                try json.writeString(w, v);
            }
            if (m.error_message) |v| {
                try w.writeAll(",\"errorMessage\":");
                try json.writeString(w, v);
            }
            try w.writeByte('}');
        },
    }
}

fn writeUsage(w: *std.Io.Writer, u: types.Usage) !void {
    try w.writeAll("{\"input\":");
    try json.writeUint(w, u.input);
    try w.writeAll(",\"output\":");
    try json.writeUint(w, u.output);
    try w.writeAll(",\"cacheRead\":");
    try json.writeUint(w, u.cache_read);
    try w.writeAll(",\"cacheWrite\":");
    try json.writeUint(w, u.cache_write);
    if (u.reasoning) |r| {
        try w.writeAll(",\"reasoning\":");
        try json.writeUint(w, r);
    }
    try w.writeAll(",\"totalTokens\":");
    try json.writeUint(w, u.total_tokens);
    try w.writeAll(",\"cost\":{\"input\":");
    try json.writeFloat(w, u.cost_input);
    try w.writeAll(",\"output\":");
    try json.writeFloat(w, u.cost_output);
    try w.writeAll(",\"cacheRead\":");
    try json.writeFloat(w, u.cost_cache_read);
    try w.writeAll(",\"cacheWrite\":");
    try json.writeFloat(w, u.cost_cache_write);
    try w.writeAll(",\"total\":");
    try json.writeFloat(w, u.cost_total);
    try w.writeAll("}}");
}
