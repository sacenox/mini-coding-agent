const std = @import("std");
const platform = @import("../platform.zig");
const text = @import("../text.zig");
const tools = @import("../tools.zig");
const snapshot = @import("snapshot.zig");

const max_head = 10_000;
const max_tail = 6_000;
const truncated_marker = "\n\n... output truncated ...\n\n";

const default_timeout_s = 120;

const description_fmt =
    "Run a bash command and return its combined output.\n\n" ++
    "The command runs with `bash -c` starting in {s}, so pipes, redirects, globs, and && work. Use it for " ++
    "builds, tests, git, package managers, and file work that read and edit do not cover. The output ends " ++
    "with an `exit code:` line. Pass `timeout` (seconds) to change the 120-second limit.";

const params = [_]tools.Param{
    .{ .name = "command", .kind = .string, .description = "Bash command line to execute." },
    .{ .name = "timeout", .kind = .integer, .required = false, .description = "Seconds to allow before the command is killed. Defaults to 120." },
};

fn describe(a: std.mem.Allocator, ctx: tools.Describe) []const u8 {
    return std.fmt.allocPrint(a, description_fmt, .{ctx.cwd}) catch "Run a bash command.";
}

pub const tool = tools.Descriptor{
    .name = .bash,
    .description = describe,
    .params = &params,
    .run = run,
};

const Args = struct { command: []const u8, timeout: ?u64 = null };

const Acc = struct {
    a: std.mem.Allocator,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,
    truncated: bool = false,
    on_output: ?tools.OutputFn,

    fn append(self: *Acc, chunk: []const u8) !void {
        if (self.on_output) |cb| cb.call(chunk);
        var rest = chunk;
        if (self.head.items.len < max_head) {
            const take = @min(max_head - self.head.items.len, rest.len);
            try self.head.appendSlice(self.a, rest[0..take]);
            rest = rest[take..];
        }
        if (rest.len == 0) return;
        try self.tail.appendSlice(self.a, rest);
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

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) tools.Result {
    return tools.fail(a, "bash failed", fmt, args);
}

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: tools.Context) tools.Result {
    const args = std.json.parseFromSliceLeaky(Args, scratch, args_json, .{ .ignore_unknown_fields = true }) catch {
        return fail(a, "bash failed: command must be a string", .{});
    };

    const ignore = snapshot.Ignore{ .dirs = ctx.snapshot_ignore_dirs, .uses_gitignore = ctx.snapshot_uses_gitignore };
    if (ctx.on_phase) |p| p.call(.snapshotting);
    const before = snapshot.capture(scratch, ignore) catch return fail(a, "bash failed: out of memory", .{});
    if (ctx.on_phase) |p| p.call(.running);

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
    const body = text.utf8Clean(scratch, raw_body) catch return fail(a, "bash failed: out of memory", .{});
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, body) catch return fail(a, "bash failed: out of memory", .{});
    if (body.len > 0 and body[body.len - 1] != '\n') out.append(a, '\n') catch return fail(a, "bash failed: out of memory", .{});
    out.appendSlice(a, std.fmt.allocPrint(scratch, "exit code: {s}", .{label}) catch "exit code: unknown") catch
        return fail(a, "bash failed: out of memory", .{});

    if (ctx.on_phase) |p| p.call(.snapshotting);
    const after = snapshot.capture(scratch, ignore) catch return fail(a, "bash failed: out of memory", .{});
    if (ctx.on_phase) |p| p.call(.running);
    const diffs = snapshot.diffTrees(scratch, before, after) catch return fail(a, "bash failed: out of memory", .{});

    return .{
        .text = out.items,
        .is_error = if (code) |c| c != 0 else true,
        .diffs = diffs,
    };
}
