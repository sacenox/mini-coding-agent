const std = @import("std");

const platform = @import("../platform.zig");

fn pathLike(word: []const u8) bool {
    if (word.len == 0) return false;
    if (word[0] == '~' or word[0] == '/') return true;
    if (std.mem.startsWith(u8, word, "./") or std.mem.startsWith(u8, word, "../")) return true;
    if (std.mem.eql(u8, word, ".") or std.mem.eql(u8, word, "..")) return true;
    if (std.mem.indexOfScalar(u8, word, '/')) |slash| {
        return slash > 0;
    }
    return false;
}

pub fn commonPrefix(a: []const u8, b: []const u8) []const u8 {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) i += 1;
    return a[0..i];
}

pub fn completePath(word: []const u8) ?[]const u8 {
    if (!pathLike(word)) return null;
    const a = platform.gpa;
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const prefix = if (slash) |s| word[s + 1 ..] else word;

    var dir: []const u8 = undefined;
    if (word[0] == '~') {
        const home = platform.getEnv("HOME") orelse "/";
        const tail = if (slash) |s| word[1..s] else word[1..];
        dir = std.fs.path.resolve(a, &.{ home, tail }) catch return null;
    } else if (slash != null and slash.? == 0) {
        dir = "/";
    } else {
        const cwd = std.process.currentPathAlloc(platform.io, a) catch return null;
        const head = if (slash) |s| word[0..s] else word;
        dir = std.fs.path.resolve(a, &.{ cwd, head }) catch return null;
    }

    var d = std.Io.Dir.cwd().openDir(platform.io, dir, .{ .iterate = true }) catch return null;
    defer d.close(platform.io);
    var it = d.iterate();
    var candidates: std.ArrayList([]const u8) = .empty;
    while (it.next(platform.io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (prefix.len == 0 or prefix[0] != '.') {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
        }
        const is_dir = entry.kind == .directory;
        const name = if (is_dir)
            std.fmt.allocPrint(a, "{s}/", .{entry.name}) catch continue
        else
            entry.name;
        candidates.append(a, name) catch {};
    }
    if (candidates.items.len == 0) return null;
    if (candidates.items.len == 1) {
        if (std.mem.eql(u8, candidates.items[0], prefix)) return null;
        return std.fmt.allocPrint(a, "{s}{s}", .{ word[0 .. word.len - prefix.len], candidates.items[0] }) catch null;
    }
    var shared = candidates.items[0];
    for (candidates.items[1..]) |c| shared = commonPrefix(shared, c);
    if (shared.len > prefix.len) {
        return std.fmt.allocPrint(a, "{s}{s}", .{ word[0 .. word.len - prefix.len], shared }) catch null;
    }
    return null;
}
