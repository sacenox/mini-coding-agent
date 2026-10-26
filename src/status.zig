const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");
const time = @import("time.zig");
const config = @import("config.zig");

/// OSC 7501, the Program Status Protocol. The program reports what it is doing
/// so any consumer of the pty can react; well-behaved terminals ignore the
/// unknown sequence. See https://mitchellh.com/writing/program-status-osc7501
const app = "mini-coding-agent";
const max_msg = 256;

/// Herdr's own integration prefix is reserved for Herdr; a source of our own
/// keeps its state and ours apart. See https://herdr.dev/docs/add-herdr-support/
const herdr_source = "mini";
const herdr_agent = "mini";
const herdr_report_timeout_ms = 2000;
const herdr_release_timeout_ms = 1000;

var program_status = false;
var notify_mode: config.Notifications = .off;
var herdr_on = false;
var herdr_bin: []const u8 = "";
var herdr_pane: []const u8 = "";

/// Reports leave through a single worker that always sends the newest state and
/// drops the ones it queued over, so a slow Herdr never slows the agent down.
var lock: std.Io.Mutex = .init;
var pending: ?Job = null;
var pending_msg: [max_msg]u8 = undefined;
var seq: u64 = 0;

const Job = struct {
    state: []const u8,
    msg_len: usize,
    seq: u64,
};

/// Enables the status consumers this run reports to. Herdr is only a consumer
/// inside a Herdr pane; anywhere else it stays off.
pub fn init(cfg: *const config.Config) void {
    program_status = cfg.program_status;
    notify_mode = cfg.notifications;
    if (!cfg.herdr) return;
    if (!std.mem.eql(u8, platform.getEnv("HERDR_ENV") orelse "", "1")) return;
    herdr_bin = platform.getEnv("HERDR_BIN_PATH") orelse return;
    herdr_pane = platform.getEnv("HERDR_PANE_ID") orelse return;
    if (herdr_bin.len == 0 or herdr_pane.len == 0) return;

    // Herdr drops reports whose --seq is not higher than the last one it took,
    // even across our own restarts, so the sequence starts at the wall clock.
    seq = @intCast(@max(0, time.nowMs()));
    herdr_on = true;

    const worker = std.Thread.spawn(.{}, loop, .{}) catch {
        herdr_on = false;
        return;
    };
    worker.detach();
}

pub fn report(state: []const u8, kind: ?[]const u8, msg: ?[]const u8) void {
    if (program_status) osc7501(state, kind, msg);
    if (!herdr_on) return;

    const mapped = herdrState(state);
    const text: []const u8 = if (std.mem.eql(u8, mapped, "blocked") and msg != null)
        msg.?[0..@min(msg.?.len, max_msg)]
    else
        "";

    lock.lockUncancelable(platform.io);
    defer lock.unlock(platform.io);
    seq += 1;
    if (text.len > 0) @memcpy(pending_msg[0..text.len], text);
    pending = .{ .state = mapped, .msg_len = text.len, .seq = seq };
}

/// Asks for the user's attention when a turn stops needing none of it. OSC 9 is
/// the desktop notification most terminals forward; the bell is the fallback
/// every terminal has.
pub fn notify(message: []const u8) void {
    if (notify_mode == .osc9 or notify_mode == .both) {
        var buf: [max_msg + 8]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "\x1b]9;{s}\x07", .{message[0..@min(message.len, max_msg)]}) catch return;
        platform.writeOut(out);
    }
    if (notify_mode == .bell or notify_mode == .both) platform.writeOut("\x07");
}

/// Clears our name, state, and resume command from the pane. Only for an exit,
/// and the report must land before the process goes away.
pub fn release() void {
    if (!herdr_on) return;
    herdr_on = false;

    var seq_buf: [24]u8 = undefined;
    const n = std.fmt.bufPrint(&seq_buf, "{d}", .{nextSeq()}) catch return;
    runQuiet(&.{ herdr_bin, "pane", "release-agent", herdr_pane, "--source", herdr_source, "--agent", herdr_agent, "--seq", n }, herdr_release_timeout_ms);
}

/// Herdr knows three states; everything else it sees is "ready for input".
fn herdrState(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "working")) return "working";
    if (std.mem.eql(u8, state, "blocked")) return "blocked";
    return "idle";
}

fn nextSeq() u64 {
    lock.lockUncancelable(platform.io);
    defer lock.unlock(platform.io);
    seq += 1;
    return seq;
}

fn loop() void {
    while (true) {
        var msg: [max_msg]u8 = undefined;
        var job: ?Job = null;
        lock.lockUncancelable(platform.io);
        if (pending) |p| {
            @memcpy(msg[0..p.msg_len], pending_msg[0..p.msg_len]);
            job = p;
            pending = null;
        }
        lock.unlock(platform.io);

        if (job) |j| send(j, msg[0..j.msg_len]);
        std.Io.sleep(platform.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .boot) catch {};
    }
}

fn send(job: Job, msg: []const u8) void {
    var seq_buf: [24]u8 = undefined;
    const n = std.fmt.bufPrint(&seq_buf, "{d}", .{job.seq}) catch return;

    const base = [_][]const u8{
        herdr_bin, "pane",      "report-agent", herdr_pane, "--source", herdr_source,
        "--agent", herdr_agent, "--state",      job.state,  "--seq",    n,
    };
    var argv: [base.len + 2][]const u8 = undefined;
    @memcpy(argv[0..base.len], &base);
    var len = base.len;
    if (msg.len > 0) {
        argv[len] = "--message";
        argv[len + 1] = msg;
        len += 2;
    }
    runQuiet(argv[0..len], herdr_report_timeout_ms);
}

/// Fire and forget: our stdio stays ours, failures are invisible, and a Herdr
/// that wedges is killed instead of holding the worker forever.
fn runQuiet(argv: []const []const u8, timeout_ms: i64) void {
    var child = std.process.spawn(platform.io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;

    const pid = child.id orelse return;
    const deadline = time.nowMs() + timeout_ms;
    while (!reaped(pid)) {
        if (time.nowMs() >= deadline) {
            child.kill(platform.io);
            return;
        }
        std.Io.sleep(platform.io, .{ .nanoseconds = 5 * std.time.ns_per_ms }, .boot) catch {};
    }
}

fn reaped(pid: std.posix.pid_t) bool {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    const rc = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
    return std.posix.errno(rc) == .SUCCESS and rc != 0;
}

fn osc7501(state: []const u8, kind: ?[]const u8, msg: ?[]const u8) void {
    var buf: [1024]u8 = undefined;
    const head = "\x1b]7501;";
    @memcpy(buf[0..head.len], head);
    var len: usize = head.len;

    len += (std.fmt.bufPrint(buf[len..], "state={s}:app={s}", .{ state, app }) catch return).len;
    if (kind) |k| len += (std.fmt.bufPrint(buf[len..], ":kind={s}", .{k}) catch return).len;
    if (msg) |m| {
        const clipped = m[0..@min(m.len, max_msg)];
        var encoded: [std.base64.standard.Encoder.calcSize(max_msg)]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&encoded, clipped);
        len += (std.fmt.bufPrint(buf[len..], ":msg={s}", .{b64}) catch return).len;
    }
    buf[len] = 0x1b;
    buf[len + 1] = '\\';
    len += 2;

    platform.writeOut(buf[0..len]);
}
