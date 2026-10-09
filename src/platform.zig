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
    return getEnv("HOME");
}

pub fn writeOut(bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

pub fn writeErr(bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

pub fn printErr(comptime fmt: []const u8, fmt_args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt, fmt_args) catch return;
    defer gpa.free(s);
    writeErr(s);
}
