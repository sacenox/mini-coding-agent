const std = @import("std");
const input = @import("input.zig");

pub const Kind = enum { provider, model, thinking, history };

pub const Action = enum { ignore, update, accept, cancel };

pub const Picker = struct {
    kind: Kind,
    title: []const u8,
    ids: []const []const u8 = &.{},
    labels: []const []const u8 = &.{},
    provider: []const u8 = "",
    draft: []const u8 = "",
    query: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(usize) = .empty,
    sel: usize = 0,

    pub fn refresh(self: *Picker, a: std.mem.Allocator) void {
        self.matches.clearRetainingCapacity();
        const query = self.query.items;
        const n = @min(self.ids.len, self.labels.len);
        for (self.ids[0..n], self.labels[0..n], 0..) |id, label, i| {
            if (query.len != 0 and std.ascii.findIgnoreCase(label, query) == null and
                std.ascii.findIgnoreCase(id, query) == null) continue;
            self.matches.append(a, i) catch {};
        }
        self.sel = if (self.matches.items.len == 0) 0 else @min(self.sel, self.matches.items.len - 1);
    }

    pub fn key(self: *Picker, a: std.mem.Allocator, k: input.Key) Action {
        switch (k) {
            .text => |t| {
                self.query.appendSlice(a, t) catch {};
                self.sel = 0;
                self.refresh(a);
            },
            .backspace => {
                if (self.query.items.len == 0) return .ignore;
                var start = self.query.items.len - 1;
                while (start > 0 and (self.query.items[start] & 0xc0) == 0x80) start -= 1;
                self.query.shrinkRetainingCapacity(start);
                self.sel = 0;
                self.refresh(a);
            },
            .up, .history_prev => {
                if (self.sel == 0) return .ignore;
                self.sel -= 1;
            },
            .down, .history_next => {
                if (self.sel + 1 >= self.matches.items.len) return .ignore;
                self.sel += 1;
            },
            .submit => return .accept,
            .escape, .interrupt => return .cancel,
            else => return .ignore,
        }
        return .update;
    }

    pub fn current(self: *const Picker) ?[]const u8 {
        if (self.matches.items.len == 0) return null;
        return self.ids[self.matches.items[self.sel]];
    }
};
