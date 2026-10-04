//! The provider contract: one streaming request in, one assistant message out,
//! with deltas delivered through a sink.

const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");

pub const Event = union(enum) {
    /// Assistant text delta.
    text: []const u8,
    /// Reasoning delta.
    reasoning: []const u8,
    /// A tool call block began; the name is known but arguments have not
    /// finished streaming.
    tool_start: []const u8,
    /// A tool call block finished.
    tool_call: types.ToolCall,
};

pub const Sink = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.on_event(self.ctx, event);
    }
};

pub const Request = struct {
    /// Long-lived allocator: the returned message's content outlives the step.
    pers: std.mem.Allocator,
    /// Per-step arena: the request body and each parsed event. Reset freely.
    scratch: std.mem.Allocator,
    model: *const types.Model,
    system_prompt: []const u8,
    /// A pre-serialized JSON array of tool schemas, verbatim.
    tools_json: []const u8,
    messages: []const types.Message,
    effort: []const u8,
    session_id: ?[]const u8,
    cancel: *const std.atomic.Value(bool),
};

/// Runs one streaming request. Transport and protocol failures are recorded in
/// the returned message's `stop_reason`/`error_message`; only a failure to
/// allocate is an error.
pub fn stream(req: Request, sink: Sink) std.mem.Allocator.Error!types.AssistantMessage {
    if (std.mem.eql(u8, req.model.api, "openai-completions")) {
        return @import("api/openai_completions.zig").stream(req, sink);
    }
    if (std.mem.eql(u8, req.model.api, "anthropic-messages")) {
        return @import("api/anthropic_messages.zig").stream(req, sink);
    }
    if (std.mem.eql(u8, req.model.api, "openai-responses")) {
        return @import("api/openai_responses.zig").stream(req, sink);
    }
    if (std.mem.eql(u8, req.model.api, "google-generative-ai")) {
        return @import("api/google_generative_ai.zig").stream(req, sink);
    }
    var msg = newAssistant(req);
    msg.stop_reason = .err;
    msg.error_message = "provider: unsupported api";
    return msg;
}

pub fn newAssistant(req: Request) types.AssistantMessage {
    return .{
        .content = .empty,
        .api = req.model.api,
        .provider = req.model.provider,
        .model = req.model.id,
        .timestamp = @import("util.zig").nowMs(),
    };
}

/// The header list every provider shares: the content negotiation pair, the
/// provider's own extra pairs (skipped when their value is empty), and then
/// the caller's custom and session headers.
pub fn headers(a: std.mem.Allocator, req: Request, extra: []const [2][]const u8) ![]http.Header {
    var list: std.ArrayList(http.Header) = .empty;
    errdefer list.deinit(a);
    try list.append(a, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(a, .{ .name = "Accept", .value = "text/event-stream" });
    for (extra) |kv| {
        if (kv[1].len > 0) try list.append(a, .{ .name = kv[0], .value = kv[1] });
    }
    for (req.model.headers) |kv| try list.append(a, .{ .name = kv[0], .value = kv[1] });
    if (req.session_id) |sid| {
        if (req.model.session_header) |name| {
            if (sid.len > 0) try list.append(a, .{ .name = name, .value = sid });
        }
    }
    return list.toOwnedSlice(a);
}

/// Sends the request and maps a transport failure onto `msg`. Returns false
/// once the caller must return `msg` as-is; true when the stream completed and
/// the caller should proceed to finalize.
pub fn post(req: Request, url: []const u8, hdrs: []const http.Header, body: []const u8, handler: http.SseHandler, msg: *types.AssistantMessage) std.mem.Allocator.Error!bool {
    var err_body: ?[]const u8 = null;
    http.postSse(req.scratch, url, hdrs, body, handler, req.cancel, &err_body) catch |e| {
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
        return false;
    };
    if (req.cancel.load(.acquire)) {
        msg.stop_reason = .aborted;
        return false;
    }
    return true;
}

/// The `{d}` cost fields, shared by every provider's usage accounting.
pub fn applyCost(model: *const types.Model, u: *types.Usage) void {
    const m = 1_000_000.0;
    u.cost_input = @as(f64, @floatFromInt(u.input)) * model.cost_input / m;
    u.cost_output = @as(f64, @floatFromInt(u.output)) * model.cost_output / m;
    u.cost_cache_read = @as(f64, @floatFromInt(u.cache_read)) * model.cost_cache_read / m;
    u.cost_cache_write = 0;
    u.cost_total = u.cost_input + u.cost_output + u.cost_cache_read + u.cost_cache_write;
}

pub fn num(v: std.json.Value) u64 {
    return switch (v) {
        .integer => |n| @intCast(@max(n, 0)),
        .float => |f| @intFromFloat(@max(f, 0)),
        else => 0,
    };
}

pub fn numField(obj: std.json.ObjectMap, key: []const u8) u64 {
    return num(obj.get(key) orelse return 0);
}

/// A non-empty string field, or null.
pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// A string field, or `""` when the field is missing or not a string.
pub fn stringOr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (obj.get(key) orelse .null) {
        .string => |s| s,
        else => "",
    };
}

/// An integer field, or `default` when the field is missing or not an integer.
pub fn intOr(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    return switch (obj.get(key) orelse .null) {
        .integer => |n| n,
        else => default,
    };
}

/// `base_url` plus one path segment, with a trailing slash on the base ignored.
pub fn buildUrl(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
}

/// The tool schemas parsed from the session's flat form, or null when there
/// are none. Borrowed from `a`.
pub fn parseTools(a: std.mem.Allocator, tools_json: []const u8) ?[]const std.json.Value {
    if (tools_json.len == 0) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, tools_json, .{}) catch return null;
    return if (root == .array) root.array.items else null;
}

/// `"name":"…","description":"…","<params_key>":<schema>` — the body every
/// provider's tool encoding shares. The caller supplies the wrapper.
pub fn writeToolBody(w: *std.Io.Writer, obj: std.json.ObjectMap, params_key: []const u8) !void {
    try w.writeAll("\"name\":");
    try @import("json.zig").writeString(w, obj.get("name").?.string);
    try w.writeAll(",\"description\":");
    try @import("json.zig").writeString(w, obj.get("description").?.string);
    try w.writeAll(",\"");
    try w.writeAll(params_key);
    try w.writeAll("\":");
    try std.json.Stringify.value(obj.get("parameters").?, .{}, w);
}
