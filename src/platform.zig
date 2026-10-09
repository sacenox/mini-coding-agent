const std = @import("std");

/// The default `std.Io.Threaded` grows its worker pool to one less than the CPU
/// count. That pool is only exercised by the net stack, which races DNS answers
/// and connections through `Io.async`; a handful of workers covers the agent.
const max_io_threads = 4;

pub var io: std.Io = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var env: *std.process.Environ.Map = undefined;
pub var args: std.process.Args = undefined;

var threaded: std.Io.Threaded = undefined;

pub fn setup(init: std.process.Init) void {
    gpa = init.gpa;
    env = init.environ_map;
    args = init.minimal.args;
    threaded = std.Io.Threaded.init(init.gpa, .{
        .argv0 = .init(init.minimal.args),
        .environ = init.minimal.environ,
        .async_limit = .limited(max_io_threads),
    });
    io = threaded.io();
}

pub fn getEnv(key: []const u8) ?[]const u8 {
    return env.get(key);
}

pub fn home() ?[]const u8 {
    if (getEnv("HOME")) |h| {
        if (h.len > 0) return h;
    }
    const pw = std.c.getpwuid(std.c.getuid()) orelse return null;
    const dir = pw.dir orelse return null;
    return std.mem.sliceTo(dir, 0);
}

/// Reset `sig` to its default disposition and re-raise it, so the process dies
/// with the signal instead of masking it behind a normal exit code.
pub fn reRaise(sig: std.posix.SIG) noreturn {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &act, null);
    std.posix.raise(sig) catch {};
    std.process.exit(1);
}

pub fn writeOut(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn writeErr(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

pub fn printErr(comptime fmt: []const u8, fmt_args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, fmt_args) catch {
        const heap = std.fmt.allocPrint(gpa, fmt, fmt_args) catch return;
        defer gpa.free(heap);
        writeErr(heap);
        return;
    };
    writeErr(s);
}
