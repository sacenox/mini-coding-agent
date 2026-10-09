const std = @import("std");
const platform = @import("platform.zig");
const filesystem = @import("filesystem.zig");

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
        const text = filesystem.readFileAlloc(self.a, self.path, 1 << 20) catch return;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (trimmed.len == 0) continue;
            self.entries.append(self.a, self.a.dupe(u8, trimmed) catch return) catch return;
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

    fn flush(self: *Store) void {
        const start = if (self.entries.items.len > self.max) self.entries.items.len - self.max else 0;
        var out: std.ArrayList(u8) = .empty;
        for (self.entries.items[start..]) |e| {
            out.appendSlice(self.a, e) catch return;
            out.append(self.a, '\n') catch return;
        }
        filesystem.writeFile(self.path, out.items) catch {};
    }
};
