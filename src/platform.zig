const std = @import("std");

pub var io: std.Io = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var env: *std.process.Environ.Map = undefined;
pub var args: std.process.Args = undefined;

pub fn setup(init: std.process.Init) void {
    io = init.io;
    gpa = init.gpa;
    env = init.environ_map;
    args = init.minimal.args;
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
