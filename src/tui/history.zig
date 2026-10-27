const std = @import("std");
const filesystem = @import("../filesystem.zig");

pub const Store = struct {
    path: []const u8,
    max: usize,
    entries: std.ArrayList([]const u8) = .empty,
    a: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator, path: []const u8, max: usize) Store {
        var self = Store{ .path = path, .max = @max(max, 1), .a = a };
        self.load();
        return self;
    }

    fn load(self: *Store) void {
        const raw = filesystem.readFileAlloc(self.a, self.path, 1 << 20) catch return;
        var it = std.mem.splitScalar(u8, raw, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (trimmed.len == 0) continue;
            const decoded = self.unescape(trimmed) catch continue;
            if (decoded.len == 0) continue;
            self.entries.append(self.a, self.a.dupe(u8, decoded) catch return) catch return;
        }
    }

    pub fn add(self: *Store, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e, trimmed)) {
                _ = self.entries.orderedRemove(i);
                break;
            }
        }
        self.entries.append(self.a, self.a.dupe(u8, trimmed) catch return) catch return;
        while (self.entries.items.len > self.max) _ = self.entries.orderedRemove(0);
        self.flush();
    }

    /// Escape backslash and newline so each entry stays one line in the file.
    fn escape(self: *Store, e: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (e) |c| {
            if (c == '\\' or c == '\n') out.append(self.a, '\\') catch return e;
            out.append(self.a, if (c == '\n') 'n' else c) catch return e;
        }
        return out.items;
    }

    fn unescape(self: *Store, s: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '\\' and i + 1 < s.len) {
                i += 1;
                out.append(self.a, if (s[i] == 'n') '\n' else s[i]) catch return s;
            } else {
                out.append(self.a, s[i]) catch return s;
            }
            i += 1;
        }
        return out.items;
    }

    fn flush(self: *Store) void {
        const start = if (self.entries.items.len > self.max) self.entries.items.len - self.max else 0;
        var out: std.ArrayList(u8) = .empty;
        for (self.entries.items[start..]) |e| {
            out.appendSlice(self.a, self.escape(e)) catch return;
            out.append(self.a, '\n') catch return;
        }
        filesystem.writeFile(self.path, out.items) catch {};
    }
};
