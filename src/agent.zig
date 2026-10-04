//! The agent loop: one turn, no compaction, no retries, no meta-messages.
//! Provider errors surface as-is. Every event reaches a listener; the headless
//! projection and the TUI are both listeners and own no agent semantics.

const std = @import("std");
const types = @import("types.zig");
const api = @import("api.zig");
const tools = @import("tools/index.zig");
const common = @import("tools/common.zig");
const session = @import("session.zig");
const util = @import("util.zig");

pub const Phase = enum { preparing, waiting_model, streaming, running_tool, pausing, idle };

pub const Event = union(enum) {
    phase: struct { phase: Phase, detail: ?[]const u8 = null },
    text: []const u8,
    reasoning: []const u8,
    tool_call_start: []const u8,
    tool_call: struct { name: []const u8, arguments: []const u8 },
    tool_output: []const u8,
    tool_result: struct { name: []const u8, text: []const u8, is_error: bool, diffs: []const common.FileDiff, body: ?[]const u8 },
    message: *types.AssistantMessage,
    no_model,
    err: []const u8,
    cancelled,
    complete,
};

pub const Listener = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: Event) void,

    pub fn emit(self: Listener, event: Event) void {
        self.on_event(self.ctx, event);
    }
};

/// How the agent reaches the projection while a turn is in flight. Headless
/// passes `null`; the TUI supplies its own. `request_steering` blocks the turn
/// thread until the user submits a line or the turn is cancelled.
pub const Interaction = struct {
    ctx: *anyopaque,
    is_pause_requested: *const fn (ctx: *anyopaque) bool,
    clear_pause: *const fn (ctx: *anyopaque) void,
    request_steering: *const fn (ctx: *anyopaque) []const u8,

    pub fn pauseRequested(self: Interaction) bool {
        return self.is_pause_requested(self.ctx);
    }
    pub fn clearPause(self: Interaction) void {
        self.clear_pause(self.ctx);
    }
    pub fn requestSteering(self: Interaction) []const u8 {
        return self.request_steering(self.ctx);
    }
};

pub const Options = struct {
    /// Long-lived allocator for the transcript and its messages.
    a: std.mem.Allocator,
    model: ?*const types.Model,
    system_prompt: []const u8,
    tools_json: []const u8,
    supports_images: bool,
    session: *session.Session,
    cancel: *const std.atomic.Value(bool),
};

const StreamCtx = struct { listener: Listener, started: bool = false };

fn onApiEvent(ctx: *anyopaque, event: api.Event) void {
    const stream_ctx: *StreamCtx = @ptrCast(@alignCast(ctx));
    const listener = stream_ctx.listener;
    if (!stream_ctx.started) {
        stream_ctx.started = true;
        listener.emit(.{ .phase = .{ .phase = .streaming } });
    }
    switch (event) {
        .text => |d| listener.emit(.{ .text = d }),
        .reasoning => |d| listener.emit(.{ .reasoning = d }),
        .tool_start => |name| listener.emit(.{ .tool_call_start = name }),
        .tool_call => |call| listener.emit(.{ .tool_call = .{ .name = call.name, .arguments = call.arguments } }),
    }
}

fn onToolOutput(ctx: *anyopaque, chunk: []const u8) void {
    const listener: *Listener = @ptrCast(@alignCast(ctx));
    listener.emit(.{ .tool_output = chunk });
}

/// Appends a user message the model reads at the next step boundary. A
/// persistence failure is returned so the caller can surface it and stop.
fn steer(opts: Options, messages: *std.ArrayList(types.Message), content: []const u8) !void {
    if (content.len == 0) return;
    const message = types.Message{ .user = .{ .content = content, .timestamp = util.nowMs() } };
    try messages.append(opts.a, message);
    try opts.session.appendMessage(opts.a, message);
}

/// Returns the steering typed while paused, or "" when there was no pause;
/// null once the turn has been cancelled.
fn pauseStep(run: Run) ?[]const u8 {
    if (run.opts.cancel.load(.acquire)) return null;
    const interaction = run.interaction orelse return "";
    if (!interaction.pauseRequested()) return "";
    interaction.clearPause();
    run.listener.emit(.{ .phase = .{ .phase = .pausing } });
    const steering = interaction.requestSteering();
    run.listener.emit(.{ .phase = .{ .phase = .idle } });
    if (run.opts.cancel.load(.acquire)) return null;
    return steering;
}

const Run = struct {
    opts: Options,
    messages: *std.ArrayList(types.Message),
    interaction: ?Interaction,
    listener: Listener,
};

/// Runs one turn to completion, appending to `messages`. Returns after the
/// model stops without tool calls, after a cancellation, or after an error;
/// every outcome is reported through the listener.
pub fn runTurn(opts: Options, messages: *std.ArrayList(types.Message), interaction: ?Interaction, listener: Listener) void {
    const run = Run{ .opts = opts, .messages = messages, .interaction = interaction, .listener = listener };

    const model = opts.model orelse {
        listener.emit(.no_model);
        return;
    };

    var arena = std.heap.ArenaAllocator.init(opts.a);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const scratch = arena.allocator();

        // Cancellation and steering land at the step boundary, never between an
        // assistant turn and its tool results.
        const steering = pauseStep(run) orelse {
            listener.emit(.cancelled);
            return;
        };
        steer(opts, messages, steering) catch |e| {
            listener.emit(.{ .err = @errorName(e) });
            return;
        };

        listener.emit(.{ .phase = .{ .phase = .preparing } });
        opts.session.appendRequest(scratch, .{
            .provider = model.provider,
            .model = model.id,
            .api = model.api,
            .thinking_effort = model.effort,
            .system_prompt = opts.system_prompt,
            .tools_json = opts.tools_json,
        }) catch |e| {
            listener.emit(.{ .err = @errorName(e) });
            return;
        };

        listener.emit(.{ .phase = .{ .phase = .waiting_model } });
        var stream_ctx = StreamCtx{ .listener = listener };
        const assistant = opts.a.create(types.AssistantMessage) catch {
            listener.emit(.{ .err = "out of memory" });
            return;
        };
        assistant.* = api.stream(.{
            .pers = opts.a,
            .scratch = scratch,
            .model = model,
            .system_prompt = opts.system_prompt,
            .tools_json = opts.tools_json,
            .messages = messages.items,
            .effort = model.effort,
            .session_id = opts.session.id,
            .cancel = opts.cancel,
        }, .{ .ctx = &stream_ctx, .on_event = onApiEvent }) catch |e| {
            listener.emit(.{ .err = @errorName(e) });
            return;
        };

        messages.append(opts.a, .{ .assistant = assistant }) catch {
            listener.emit(.{ .err = "out of memory" });
            return;
        };
        opts.session.appendMessage(scratch, .{ .assistant = assistant }) catch |e| {
            listener.emit(.{ .err = @errorName(e) });
            return;
        };
        listener.emit(.{ .message = assistant });

        if (assistant.stop_reason == .aborted) {
            listener.emit(.cancelled);
            return;
        }
        if (assistant.stop_reason == .err) {
            listener.emit(.{ .err = assistant.error_message orelse "provider error" });
            return;
        }

        const has_calls = for (assistant.content.items) |block| {
            if (block == .tool_call) break true;
        } else false;
        if (!has_calls) {
            listener.emit(.complete);
            return;
        }

        // Steering is held until every result of this assistant turn has
        // landed: the provider rejects a user message between an assistant
        // turn and its tool results.
        var held: std.ArrayList([]const u8) = .empty;
        defer held.deinit(opts.a);
        for (assistant.content.items) |block| {
            if (block != .tool_call) continue;
            const call = block.tool_call;

            const step = pauseStep(run) orelse {
                listener.emit(.cancelled);
                return;
            };
            if (step.len > 0) held.append(opts.a, step) catch {
                listener.emit(.{ .err = "out of memory" });
                return;
            };

            listener.emit(.{ .phase = .{ .phase = .running_tool, .detail = call.name } });

            const result = tools.execute(opts.a, scratch, call.name, call.arguments, .{
                .cancel = opts.cancel,
                .supports_images = opts.supports_images,
                .on_output = .{ .ctx = &stream_ctx.listener, .on_chunk = onToolOutput },
            });

            const tool_message = types.Message{ .tool_result = .{
                .tool_call_id = call.id,
                .tool_name = call.name,
                .text = result.text,
                .images = result.images,
                .is_error = result.is_error,
                .timestamp = util.nowMs(),
            } };
            messages.append(opts.a, tool_message) catch {
                listener.emit(.{ .err = "out of memory" });
                return;
            };
            opts.session.appendMessage(scratch, tool_message) catch |e| {
                listener.emit(.{ .err = @errorName(e) });
                return;
            };
            listener.emit(.{ .tool_result = .{
                .name = call.name,
                .text = result.text,
                .is_error = result.is_error,
                .diffs = result.diffs,
                .body = result.body,
            } });
        }
        const joined = tryJoin(opts.a, held.items) catch {
            listener.emit(.{ .err = "out of memory" });
            return;
        };
        steer(opts, messages, joined) catch |e| {
            listener.emit(.{ .err = @errorName(e) });
            return;
        };
    }
}

/// Joins held steering lines with newlines, so the next step sees one message.
fn tryJoin(a: std.mem.Allocator, parts: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (parts.len == 0) return "";
    if (parts.len == 1) return parts[0];
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |p, i| {
        if (i > 0) try out.append(a, '\n');
        try out.appendSlice(a, p);
    }
    return out.items;
}
