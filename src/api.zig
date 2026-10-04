//! The provider contract: one streaming request in, one assistant message out,
//! with deltas delivered through a sink.

const std = @import("std");
const types = @import("types.zig");

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
