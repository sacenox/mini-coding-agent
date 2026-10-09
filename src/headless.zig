const std = @import("std");
const platform = @import("platform.zig");
const time = @import("time.zig");
const config = @import("config.zig");
const message_mod = @import("message.zig");
const agent = @import("agent.zig");

var cancel = std.atomic.Value(bool).init(false);
var caught_signal = std.atomic.Value(u32).init(0);

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    caught_signal.store(@intFromEnum(sig), .seq_cst);
    cancel.store(true, .release);
}

const PrintCtx = struct { failed: bool = false };

fn printEvent(ctx: *anyopaque, event: agent.Event) void {
    const pc: *PrintCtx = @ptrCast(@alignCast(ctx));
    switch (event) {
        .tool_call => |call| platform.printErr("[tool] {s}\n", .{call.name}),
        .tool_output => |chunk| platform.writeErr(chunk),
        .no_model => {
            pc.failed = true;
            platform.printErr("[error] no model configured; add \"provider\" and \"model\" to {s}\n", .{config.configPath(platform.gpa)});
        },
        .err => |message| {
            pc.failed = true;
            platform.printErr("[error] {s}\n", .{message});
        },
        .cancelled => {
            pc.failed = true;
            platform.printErr("[cancelled]\n", .{});
        },
        else => {},
    }
}

pub fn run(a: std.mem.Allocator, prompt_text: []const u8, opts: agent.Options) u8 {
    var messages: std.ArrayList(message_mod.Message) = .empty;
    const user = message_mod.Message{ .user = .{ .content = prompt_text, .timestamp = time.nowMs() } };
    messages.append(a, user) catch {
        platform.printErr("[error] out of memory\n", .{});
        return 1;
    };
    opts.session.appendMessage(a, user) catch |e| {
        platform.printErr("[error] {s}\n", .{@errorName(e)});
        return 1;
    };

    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    var pc = PrintCtx{};
    var o = opts;
    o.cancel = &cancel;
    agent.runTurn(o, &messages, null, .{ .ctx = &pc, .on_event = printEvent });
    opts.session.close();
    const sig = caught_signal.load(.seq_cst);
    if (sig != 0) platform.reRaise(@enumFromInt(sig));
    if (pc.failed) return 1;

    var i = messages.items.len;
    const last = while (i > 0) {
        i -= 1;
        if (messages.items[i] == .assistant) break messages.items[i].assistant;
    } else return 0;
    const text = last.text(a) catch {
        platform.printErr("[error] out of memory\n", .{});
        return 1;
    };
    if (text.len > 0) {
        platform.writeOut(text);
        if (text[text.len - 1] != '\n') platform.writeOut("\n");
    }
    return 0;
}
