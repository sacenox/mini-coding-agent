//! Provider-neutral transcript types, mirroring pi-ai's message shapes.
//!
//! A tool call's arguments are kept as their raw JSON object text, exactly as
//! the provider streamed them, so provider continuation data survives a
//! round trip without a parse/print cycle.

const std = @import("std");

pub const Usage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    reasoning: ?u64 = null,
    total_tokens: u64 = 0,
    cost_input: f64 = 0,
    cost_output: f64 = 0,
    cost_cache_read: f64 = 0,
    cost_total: f64 = 0,
};

pub const StopReason = enum {
    pending,
    stop,
    length,
    tool_use,
    err,
    aborted,

    pub fn wire(self: StopReason) []const u8 {
        return switch (self) {
            .pending => "pending",
            .stop => "stop",
            .length => "length",
            .tool_use => "toolUse",
            .err => "error",
            .aborted => "aborted",
        };
    }
};

pub const ImageContent = struct {
    data: []const u8,
    mime_type: []const u8,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// A JSON object, verbatim from the provider stream.
    arguments: []const u8,
    /// Provider continuation data (Google's `thoughtSignature`), preserved so a
    /// tool round trip can be replayed.
    thought_signature: ?[]const u8 = null,
};

pub const ContentBlock = union(enum) {
    text: []const u8,
    thinking: struct {
        text: []const u8,
        signature: ?[]const u8 = null,
    },
    tool_call: ToolCall,
};

pub const AssistantMessage = struct {
    content: std.ArrayList(ContentBlock),
    api: []const u8,
    provider: []const u8,
    model: []const u8,
    response_id: ?[]const u8 = null,
    response_model: ?[]const u8 = null,
    raw_stop_reason: ?[]const u8 = null,
    usage: Usage = .{},
    stop_reason: StopReason = .pending,
    error_message: ?[]const u8 = null,
    timestamp: i64 = 0,
};

pub const ToolResultMessage = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
    images: []const ImageContent = &.{},
    is_error: bool,
    timestamp: i64,
};

pub const Message = union(enum) {
    user: struct { content: []const u8, timestamp: i64 },
    assistant: *AssistantMessage,
    tool_result: ToolResultMessage,
};

/// Concatenates an assistant message's text blocks. An allocation failure is
/// returned rather than a silently truncated string.
pub fn assistantText(a: std.mem.Allocator, msg: *const AssistantMessage) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (msg.content.items) |block| switch (block) {
        .text => |t| try out.appendSlice(a, t),
        else => {},
    };
    return out.items;
}

/// The model a resolved provider serves.
pub const Model = struct {
    id: []const u8,
    name: []const u8,
    api: []const u8,
    provider: []const u8,
    base_url: []const u8,
    api_key: ?[]const u8,
    /// The effort actually sent, after clamping to what the model accepts.
    effort: []const u8,
    supports_images: bool,
    context_window: u64,
    max_tokens: u64,
    cost_input: f64,
    cost_output: f64,
    cost_cache_read: f64,
    session_header: ?[]const u8,
    /// Extra request headers, from a custom provider. Plain name/value pairs.
    headers: []const [2][]const u8 = &.{},
};
