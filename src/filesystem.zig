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

pub fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(platform.io, path, .{}) catch return false;
    return true;
}

pub fn listDir(a: std.mem.Allocator, root: []const u8) ![]const []const u8 {
    var dir = try std.Io.Dir.cwd().openDir(platform.io, root, .{ .iterate = true });
    defer dir.close(platform.io);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    var it = dir.iterate();
    while (try it.next(platform.io)) |entry| {
        try out.append(a, try a.dupe(u8, entry.name));
    }
    return out.toOwnedSlice(a);
}
