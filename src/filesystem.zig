const std = @import("std");
const platform = @import("platform.zig");

pub fn join(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

pub fn readFileAlloc(a: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(platform.io, path, a, .limited(max));
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(platform.io, dir) catch {};
    }
    const f = try std.Io.Dir.cwd().createFile(platform.io, path, .{ .truncate = true });
    defer f.close(platform.io);
    try f.writeStreamingAll(platform.io, data);
}

/// Atomically replacing write, owner-only permissions.
pub fn writePrivateFile(path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    std.Io.Dir.cwd().createDirPath(platform.io, dir_path) catch {};
    var dir = try std.Io.Dir.cwd().openDir(platform.io, dir_path, .{});
    defer dir.close(platform.io);
    var file = try dir.createFileAtomic(platform.io, std.fs.path.basename(path), .{
        .permissions = @enumFromInt(0o600),
        .replace = true,
    });
    defer file.deinit(platform.io);
    try file.file.writeStreamingAll(platform.io, data);
    try file.replace(platform.io);
}

pub fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(platform.io, path, .{}) catch return false;
    return true;
}

pub fn listDir(a: std.mem.Allocator, root: []const u8) [][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    const dir = std.Io.Dir.cwd().openDir(platform.io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(platform.io);
    var it = dir.iterate();
    while (it.next(platform.io) catch return out.toOwnedSlice(a) catch &.{}) |entry| {
        out.append(a, a.dupe(u8, entry.name) catch return out.toOwnedSlice(a) catch &.{}) catch
            return out.toOwnedSlice(a) catch &.{};
    }
    return out.toOwnedSlice(a) catch &.{};
}
