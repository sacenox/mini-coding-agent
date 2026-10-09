const std = @import("std");
const types = @import("types.zig");
const api = @import("api.zig");
const platform = @import("platform.zig");
const tools = @import("tools.zig");
const common = @import("tools/common.zig");
const session = @import("session.zig");
const config = @import("config.zig");
const time = @import("time.zig");

pub const Phase = enum { preparing, waiting_model, streaming, running_tool, snapshotting, pausing, idle };

pub const Event = union(enum) {
    phase: struct { phase: Phase, detail: ?[]const u8 = null },
    text: []const u8,
    reasoning: []const u8,
    tool_call_start: []const u8,
    tool_args: usize,
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
    a: std.mem.Allocator,
    model: ?*const types.Model,
    system_prompt: []const u8,
    loaded: struct { agent_files: usize = 0, skills: usize = 0 } = .{},
    tools_json: []const u8,
    supports_images: bool,
    session: *session.Session,
    cancel: *const std.atomic.Value(bool),
    config: *const config.Config,
    messages_mutex: ?*std.Io.Mutex = null,
};

fn lockMessages(opts: Options) void {
    if (opts.messages_mutex) |m| m.lockUncancelable(platform.io);
}

fn unlockMessages(opts: Options) void {
    if (opts.messages_mutex) |m| m.unlock(platform.io);
}

const StreamCtx = struct { listener: Listener, started: bool = false };

const ToolPhaseCtx = struct { listener: Listener, name: []const u8 };

fn onToolPhase(ctx: *anyopaque, phase: common.ToolPhase) void {
    const c: *ToolPhaseCtx = @ptrCast(@alignCast(ctx));
    switch (phase) {
        .snapshotting => c.listener.emit(.{ .phase = .{ .phase = .snapshotting } }),
        .running => c.listener.emit(.{ .phase = .{ .phase = .running_tool, .detail = c.name } }),
    }
}

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
        .tool_args => |n| listener.emit(.{ .tool_args = n }),
        .tool_call => |call| listener.emit(.{ .tool_call = .{ .name = call.name, .arguments = call.arguments } }),
    }
}

fn onToolOutput(ctx: *anyopaque, chunk: []const u8) void {
    const listener: *Listener = @ptrCast(@alignCast(ctx));
    listener.emit(.{ .tool_output = chunk });
}

fn pushMessage(opts: Options, messages: *std.ArrayList(types.Message), message: types.Message) !void {
    lockMessages(opts);
    defer unlockMessages(opts);
    try messages.append(opts.a, message);
}

fn steer(opts: Options, messages: *std.ArrayList(types.Message), content: []const u8) !void {
    if (content.len == 0) return;
    const message = types.Message{ .user = .{ .content = content, .timestamp = time.nowMs() } };
    try pushMessage(opts, messages, message);
    try opts.session.appendMessage(opts.a, message);
}

fn pauseStep(run: Run) ?[]const u8 {
    const interaction = run.interaction orelse return "";
    if (!interaction.pauseRequested()) return "";
    interaction.clearPause();
    run.listener.emit(.{ .phase = .{ .phase = .pausing } });
    const steering = interaction.requestSteering();
    run.listener.emit(.{ .phase = .{ .phase = .idle } });
    if (run.opts.cancel.load(.acquire)) return null;
    return steering;
}

fn cancelled(opts: Options, listener: Listener) bool {
    if (!opts.cancel.load(.acquire)) return false;
    listener.emit(.cancelled);
    return true;
}

const Run = struct {
    opts: Options,
    messages: *std.ArrayList(types.Message),
    interaction: ?Interaction,
    listener: Listener,
};

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

        if (cancelled(opts, listener)) return;
        const steering = pauseStep(run) orelse {
            listener.emit(.cancelled);
            return;
        };
        steer(opts, messages, steering) catch |e| {
            listener.emit(.{ .err = @errorName(e) });
            return;
        };

        if (cancelled(opts, listener)) return;
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

        if (cancelled(opts, listener)) return;
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

        pushMessage(opts, messages, .{ .assistant = assistant }) catch {
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

        var held: std.ArrayList([]const u8) = .empty;
        defer held.deinit(opts.a);
        var run_tools = true;
        for (assistant.content.items) |block| {
            if (block != .tool_call) continue;
            const call = block.tool_call;

            if (run_tools) {
                if (opts.cancel.load(.acquire)) {
                    run_tools = false;
                } else if (pauseStep(run)) |step| {
                    if (step.len > 0) held.append(opts.a, step) catch {
                        listener.emit(.{ .err = "out of memory" });
                        return;
                    };
                } else {
                    run_tools = false;
                }
            }
            if (run_tools and opts.cancel.load(.acquire)) run_tools = false;

            var result: ?common.Result = null;
            if (run_tools) {
                listener.emit(.{ .phase = .{ .phase = .running_tool, .detail = call.name } });
                var phase_ctx = ToolPhaseCtx{ .listener = listener, .name = call.name };
                result = tools.execute(opts.a, scratch, call.name, call.arguments, .{
                    .cancel = opts.cancel,
                    .supports_images = opts.supports_images,
                    .tools = opts.config.tools,
                    .on_output = .{ .ctx = &stream_ctx.listener, .on_chunk = onToolOutput },
                    .on_phase = .{ .ctx = &phase_ctx, .on_phase = onToolPhase },
                    .snapshot_ignore_dirs = opts.config.snapshot_ignore_dirs,
                    .snapshot_uses_gitignore = opts.config.snapshot_uses_gitignore,
                });
            }

            const tool_message = types.Message{ .tool_result = .{
                .tool_call_id = call.id,
                .tool_name = call.name,
                .text = if (result) |r| r.text else "aborted",
                .images = if (result) |r| r.images else &.{},
                .is_error = if (result) |r| r.is_error else true,
                .timestamp = time.nowMs(),
            } };
            pushMessage(opts, messages, tool_message) catch {
                listener.emit(.{ .err = "out of memory" });
                return;
            };
            opts.session.appendMessage(scratch, tool_message) catch |e| {
                listener.emit(.{ .err = @errorName(e) });
                return;
            };
            listener.emit(.{ .tool_result = .{
                .name = call.name,
                .text = tool_message.tool_result.text,
                .is_error = tool_message.tool_result.is_error,
                .diffs = if (result) |r| r.diffs else &.{},
                .body = if (result) |r| r.body else null,
            } });
        }
        if (!run_tools) {
            listener.emit(.cancelled);
            return;
        }
        if (cancelled(opts, listener)) return;
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
