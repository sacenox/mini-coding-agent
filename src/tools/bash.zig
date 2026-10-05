const std = @import("std");
const platform = @import("../platform.zig");
const util = @import("../util.zig");
const common = @import("common.zig");
const snapshot = @import("snapshot.zig");

const max_head = 10_000;
const max_tail = 6_000;
const truncated_marker = "\n\n... output truncated ...\n\n";

const default_timeout_s = 120;

const Args = struct { command: []const u8, timeout: ?u64 = null };

const Acc = struct {
    a: std.mem.Allocator,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    on_output: ?common.OutputFn,

    fn append(self: *Acc, chunk: []const u8) !void {
        if (self.on_output) |cb| cb.call(chunk);
        var text = chunk;
        if (self.head.items.len < max_head) {
            const take = @min(max_head - self.head.items.len, text.len);
            try self.head.appendSlice(self.a, text[0..take]);
            text = text[take..];
        }
        if (text.len == 0) return;
        try self.tail.appendSlice(self.a, text);
        if (self.tail.items.len > max_tail) {
            self.truncated = true;
            const drop = self.tail.items.len - max_tail;
            std.mem.copyForwards(u8, self.tail.items[0..], self.tail.items[drop..]);
            self.tail.items.len = max_tail;
        }
    }

    fn body(self: *Acc, a: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, self.head.items);
        if (self.truncated) try out.appendSlice(a, truncated_marker);
        try out.appendSlice(a, self.tail.items);
        return out.toOwnedSlice(a);
    }
};

fn killGroup(pid: i32) void {
    std.posix.kill(-pid, .TERM) catch {};
    std.Io.sleep(platform.io, .{ .nanoseconds = 300 * std.time.ns_per_ms }, .boot) catch {};
    std.posix.kill(-pid, .KILL) catch {};
}

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) common.Result {
    return .{
        .text = std.fmt.allocPrint(a, fmt, args) catch "bash failed",
        .is_error = true,
    };
}

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: common.Context) common.Result {
    const args = std.json.parseFromSliceLeaky(Args, scratch, args_json, .{ .ignore_unknown_fields = true }) catch {
        return fail(a, "bash failed: command must be a string", .{});
    };

    const before = snapshot.capture(scratch) catch return fail(a, "bash failed: out of memory", .{});

    var child = std.process.spawn(platform.io, .{
        .argv = &.{ "bash", "-c", args.command },
        .cwd = .inherit,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |e| return fail(a, "bash failed: {s}", .{@errorName(e)});

    const pid = child.id.?;
    var fds = [_]std.posix.pollfd{
        .{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    var open = [_]bool{ true, true };

    var acc = Acc{ .a = scratch, .on_output = ctx.on_output };
    var cancelled = false;
    var broken = false;
    var oom = false;
    var timed_out = false;

    const timeout_s = args.timeout orelse default_timeout_s;
    const start = std.Io.Clock.awake.now(platform.io);
    const deadline = start.addDuration(.fromSeconds(@intCast(@min(timeout_s, std.math.maxInt(i64)))));

    while (open[0] or open[1]) {
        if (ctx.cancel.load(.acquire)) {
            cancelled = true;
            break;
        }
        const now = std.Io.Clock.awake.now(platform.io);
        if (now.durationTo(deadline).nanoseconds <= 0) {
            timed_out = true;
            break;
        }
        const remaining = now.durationTo(deadline).toMilliseconds();
        const wait_ms: i32 = @intCast(@min(100, @max(1, remaining)));
        const ready = std.posix.poll(&fds, wait_ms) catch {
            broken = true;
            break;
        };
        if (ready == 0) continue;
        for (0..2) |i| {
            if (!open[i]) continue;
            if (fds[i].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) continue;
            var buf: [8192]u8 = undefined;
            const n = std.posix.read(fds[i].fd, &buf) catch |e| switch (e) {
                error.WouldBlock => continue,
                else => {
                    open[i] = false;
                    continue;
                },
            };
            if (n == 0) {
                open[i] = false;
                continue;
            }
            acc.append(buf[0..n]) catch {
                oom = true;
                break;
            };
        }
        if (oom) break;
    }

    if (cancelled or timed_out or oom or broken) killGroup(pid);
    const term = child.wait(platform.io) catch std.process.Child.Term{ .unknown = 0 };

    if (oom) return fail(a, "bash failed: out of memory", .{});
    if (broken) return fail(a, "bash failed: could not read the command's output", .{});

    const code: ?u8 = switch (term) {
        .exited => |c| c,
        else => null,
    };
    const label: []const u8 = if (timed_out)
        std.fmt.allocPrint(scratch, "timed out after {d}s", .{timeout_s}) catch "timed out"
    else if (code) |c|
        std.fmt.allocPrint(scratch, "{d}", .{c}) catch "unknown"
    else if (cancelled)
        "aborted"
    else
        "unknown";

    const raw_body = acc.body(scratch) catch return fail(a, "bash failed: out of memory", .{});
    const body = util.utf8Clean(scratch, raw_body) catch return fail(a, "bash failed: out of memory", .{});
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, body) catch return fail(a, "bash failed: out of memory", .{});
    if (body.len > 0 and body[body.len - 1] != '\n') out.append(a, '\n') catch return fail(a, "bash failed: out of memory", .{});
    out.appendSlice(a, std.fmt.allocPrint(scratch, "exit code: {s}", .{label}) catch "exit code: unknown") catch
        return fail(a, "bash failed: out of memory", .{});

    const after = snapshot.capture(scratch) catch return fail(a, "bash failed: out of memory", .{});
    const diffs = snapshot.diffTrees(scratch, before, after) catch return fail(a, "bash failed: out of memory", .{});

    return .{
        .text = out.items,
        .is_error = if (code) |c| c != 0 else true,
        .diffs = diffs,
    };
}
