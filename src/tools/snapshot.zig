const std = @import("std");
const platform = @import("../platform.zig");
const filesystem = @import("../filesystem.zig");
const diff = @import("../diff.zig");
const tools = @import("../tools.zig");

const max_file_bytes = 1 << 20;
const max_total_bytes = 32 << 20;
const binary_sniff = 8192;

const Kind = enum { text, binary, large, link, untracked };

const FileState = struct {
    size: u64,
    mtime: i128,
    inode: u64,
    kind: Kind,
    content: ?[]const u8,
};

pub const Tree = std.StringHashMap(FileState);

pub const Ignore = struct {
    dirs: []const []const u8 = &.{},
    uses_gitignore: bool = true,
};

fn normalizePattern(raw: []const u8) ?[]const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    if (std.mem.startsWith(u8, line, "./")) line = line[2..];
    line = std.mem.trimEnd(u8, line, "/");
    return if (line.len == 0) null else line;
}

fn ignoreSet(tmp: std.mem.Allocator, ignore: Ignore) !std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(tmp);
    var list: std.ArrayList([]const u8) = .empty;
    try list.appendSlice(tmp, ignore.dirs);
    if (ignore.uses_gitignore) {
        if (filesystem.readFileAlloc(tmp, ".gitignore", 1 << 20)) |text| {
            var it = std.mem.tokenizeScalar(u8, text, '\n');
            while (it.next()) |line| try list.append(tmp, line);
        } else |_| {}
    }
    for (list.items) |dir| {
        const name = normalizePattern(dir) orelse continue;
        try set.put(name, {});
    }
    return set;
}

pub fn capture(a: std.mem.Allocator, ignore: Ignore) !Tree {
    var tree = Tree.init(a);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();

    const ignores = try ignoreSet(tmp, ignore);

    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(tmp, "");

    var total: u64 = 0;
    while (stack.pop()) |dir_rel| {
        const open_path = if (dir_rel.len == 0) "." else dir_rel;
        var d = std.Io.Dir.cwd().openDir(platform.io, open_path, .{ .iterate = true }) catch continue;
        defer d.close(platform.io);

        var it = d.iterate();
        while (it.next(platform.io) catch null) |entry| {
            const rel = if (dir_rel.len == 0)
                try a.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_rel, entry.name });

            if (entry.kind == .directory) {
                if (!ignores.contains(entry.name)) try stack.append(tmp, rel);
                continue;
            }

            const st = std.Io.Dir.cwd().statFile(platform.io, rel, .{ .follow_symlinks = false }) catch {
                continue;
            };
            var state = FileState{
                .size = st.size,
                .mtime = st.mtime.nanoseconds,
                .inode = st.inode,
                .kind = .untracked,
                .content = null,
            };
            if (st.kind == .sym_link) {
                state.kind = .link;
            } else if (st.kind != .file) {
                continue;
            } else if (st.size > max_file_bytes) {
                state.kind = .large;
            } else if (total >= max_total_bytes) {
                state.kind = .untracked;
            } else {
                const buf = std.Io.Dir.cwd().readFileAlloc(platform.io, rel, a, .limited(max_file_bytes + 1)) catch {
                    state.kind = .untracked;
                    try tree.put(rel, state);
                    continue;
                };
                const sniff = @min(buf.len, binary_sniff);
                if (std.mem.indexOfScalar(u8, buf[0..sniff], 0) != null) {
                    state.kind = .binary;
                } else {
                    state.kind = .text;
                    state.content = buf;
                    total += st.size;
                }
            }
            try tree.put(rel, state);
        }
    }
    return tree;
}

fn sameStat(x: FileState, y: FileState) bool {
    return x.size == y.size and x.mtime == y.mtime and x.inode == y.inode;
}

fn noteFor(a: std.mem.Allocator, kind: Kind, verb: []const u8) []const u8 {
    return switch (kind) {
        .binary => std.fmt.allocPrint(a, "binary file {s}", .{verb}) catch "binary file changed",
        .large => std.fmt.allocPrint(a, "large file {s}", .{verb}) catch "large file changed",
        else => std.fmt.allocPrint(a, "file not tracked ({s})", .{verb}) catch "file not tracked",
    };
}

fn diffOne(a: std.mem.Allocator, path: []const u8, before: ?FileState, after: ?FileState) !?tools.FileDiff {
    if (before == null) {
        const af = after.?;
        if (af.kind == .link) return .{ .path = path, .note = "symlink created" };
        if (af.content == null) return .{ .path = path, .note = noteFor(a, af.kind, "created") };
        return .{ .path = path, .patch = try diff.unified(a, "", af.content.?) };
    }
    if (after == null) {
        const bf = before.?;
        if (bf.kind == .link) return .{ .path = path, .note = "symlink removed" };
        if (bf.content == null) return .{ .path = path, .note = noteFor(a, bf.kind, "deleted") };
        return .{ .path = path, .patch = try diff.unified(a, bf.content.?, "") };
    }
    const bf = before.?;
    const af = after.?;
    if (bf.kind == .link or af.kind == .link) {
        return if (sameStat(bf, af)) null else .{ .path = path, .note = "symlink changed" };
    }
    if (bf.content != null and af.content != null) {
        if (std.mem.eql(u8, bf.content.?, af.content.?)) return null;
        return .{ .path = path, .patch = try diff.unified(a, bf.content.?, af.content.?) };
    }
    if (sameStat(bf, af)) return null;
    return .{ .path = path, .note = noteFor(a, if (af.content == null) af.kind else bf.kind, "changed") };
}

pub fn diffTrees(a: std.mem.Allocator, before: Tree, after: Tree) ![]tools.FileDiff {
    var paths: std.ArrayList([]const u8) = .empty;
    var it = before.iterator();
    while (it.next()) |e| try paths.append(a, e.key_ptr.*);
    var it2 = after.iterator();
    while (it2.next()) |e| {
        if (!before.contains(e.key_ptr.*)) try paths.append(a, e.key_ptr.*);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var out: std.ArrayList(tools.FileDiff) = .empty;
    for (paths.items) |p| {
        if (try diffOne(a, p, before.get(p), after.get(p))) |d| try out.append(a, d);
    }
    return out.toOwnedSlice(a);
}
