const std = @import("std");
const theme = @import("theme.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");

const BodyLine = render.BodyLine;

fn isFenceOpen(line: []const u8) ?struct { marker: []const u8, info: []const u8 } {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    if (i >= line.len) return null;
    const ch = line[i];
    if (ch != '`' and ch != '~') return null;
    var j = i;
    while (j < line.len and line[j] == ch) j += 1;
    if (j - i < 3) return null;
    var k = j;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
    var end = k;
    while (end < line.len and line[end] != ' ' and line[end] != '\t') end += 1;
    return .{ .marker = line[i..j], .info = line[k..end] };
}

fn isFenceClose(line: []const u8, marker: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    if (i >= line.len or line[i] != marker[0]) return false;
    var j = i;
    while (j < line.len and line[j] == marker[0]) j += 1;
    if (j - i < marker.len) return false;
    while (j < line.len) : (j += 1) {
        if (line[j] != ' ' and line[j] != '\t') return false;
    }
    return true;
}

pub const MarkdownStream = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator = undefined,
    rest: std.ArrayList(u8) = .empty,
    fence: ?struct { marker: []const u8, info: []const u8, lines: std.ArrayList([]const u8) } = null,
    prose: std.ArrayList([]const u8) = .empty,

    pub fn init(backing: std.mem.Allocator) MarkdownStream {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn bind(self: *MarkdownStream) void {
        self.a = self.arena.allocator();
    }

    pub fn feed(self: *MarkdownStream, out_a: std.mem.Allocator, delta: []const u8) []BodyLine {
        self.rest.appendSlice(self.a, delta) catch {};
        var out: std.ArrayList(BodyLine) = .empty;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.rest.items, i, '\n')) |nl| {
            const line = self.a.dupe(u8, self.rest.items[i..nl]) catch "";
            self.commit(out_a, line, &out);
            i = nl + 1;
        }
        if (i > 0) {
            const keep = self.rest.items[i..];
            std.mem.copyForwards(u8, self.rest.items[0..keep.len], keep);
            self.rest.items.len = keep.len;
        }
        return out.items;
    }

    fn commit(self: *MarkdownStream, out_a: std.mem.Allocator, line: []const u8, out: *std.ArrayList(BodyLine)) void {
        if (self.fence) |*f| {
            if (isFenceClose(line, f.marker)) {
                self.releaseFence(out_a, line, out);
            } else {
                f.lines.append(self.a, line) catch {};
            }
            return;
        }
        if (isFenceOpen(line)) |open| {
            self.releaseProse(out_a, "", out);
            var fl: std.ArrayList([]const u8) = .empty;
            fl.append(self.a, line) catch {};
            self.fence = .{ .marker = open.marker, .info = open.info, .lines = fl };
            return;
        }
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            self.releaseProse(out_a, "", out);
            out.append(out_a, .{ .text = line }) catch {};
            return;
        }
        self.prose.append(self.a, line) catch {};
    }

    fn releaseProse(self: *MarkdownStream, out_a: std.mem.Allocator, tail: []const u8, out: *std.ArrayList(BodyLine)) void {
        var prose = self.prose;
        self.prose = .empty;
        if (tail.len > 0) prose.append(self.a, tail) catch {};
        if (prose.items.len == 0) return;
        var joined: std.ArrayList(u8) = .empty;
        for (prose.items, 0..) |l, i| {
            if (i > 0) joined.append(out_a, '\n') catch {};
            joined.appendSlice(out_a, l) catch {};
        }
        joined.append(out_a, '\n') catch {};
        emitHighlighted(out_a, highlight.highlightMarkdown(out_a, highlight.formatTables(out_a, joined.items)), out);
    }

    fn releaseFence(self: *MarkdownStream, out_a: std.mem.Allocator, closing: ?[]const u8, out: *std.ArrayList(BodyLine)) void {
        const f = self.fence.?;
        self.fence = null;
        out.append(out_a, .{ .text = highlight.highlightMarkdown(out_a, f.lines.items[0]) }) catch {};
        if (f.lines.items.len > 1) {
            var body: std.ArrayList(u8) = .empty;
            for (f.lines.items[1..], 0..) |l, i| {
                if (i > 0) body.append(out_a, '\n') catch {};
                body.appendSlice(out_a, l) catch {};
            }
            var it = std.mem.splitScalar(u8, highlight.highlightCode(out_a, f.info, body.items), '\n');
            while (it.next()) |l| out.append(out_a, .{ .text = l }) catch {};
        }
        if (closing) |c| out.append(out_a, .{ .text = highlight.highlightMarkdown(out_a, c) }) catch {};
    }

    pub fn pending(self: *MarkdownStream, out_a: std.mem.Allocator) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        const held: []const []const u8 = if (self.fence) |f| f.lines.items else self.prose.items;
        for (held) |l| out.append(out_a, .{ .text = l }) catch {};
        if (self.rest.items.len > 0) out.append(out_a, .{ .text = self.rest.items }) catch {};
        return out.items;
    }

    pub fn flush(self: *MarkdownStream, out_a: std.mem.Allocator) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        if (self.fence != null) {
            self.releaseFence(out_a, null, &out);
            if (self.rest.items.len > 0) out.append(out_a, .{ .text = highlight.highlightMarkdown(out_a, self.rest.items) }) catch {};
        } else {
            self.releaseProse(out_a, self.rest.items, &out);
        }
        self.reset();
        return out.items;
    }

    pub fn reset(self: *MarkdownStream) void {
        self.rest = .empty;
        self.fence = null;
        self.prose = .empty;
        _ = self.arena.reset(.retain_capacity);
        self.a = self.arena.allocator();
    }
};

fn emitHighlighted(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList(BodyLine)) void {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n') orelse {
        out.append(a, .{ .text = text }) catch {};
        return;
    };
    const reset = text[nl + 1 ..];
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text[0..nl], '\n');
    while (it.next()) |l| lines.append(a, l) catch {};
    if (lines.items.len > 0) {
        const last = lines.items.len - 1;
        lines.items[last] = std.fmt.allocPrint(a, "{s}{s}", .{ lines.items[last], reset }) catch lines.items[last];
    }
    for (lines.items) |l| out.append(a, .{ .text = l }) catch {};
}

pub const TailStream = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator = undefined,
    rest: std.ArrayList(u8) = .empty,

    pub fn init(backing: std.mem.Allocator) TailStream {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn bind(self: *TailStream) void {
        self.a = self.arena.allocator();
    }

    pub fn feed(self: *TailStream, delta: []const u8) void {
        self.rest.appendSlice(self.a, delta) catch {};
        if (std.mem.lastIndexOfScalar(u8, self.rest.items, '\n')) |nl| {
            const keep = self.rest.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.rest.items[0..keep.len], keep);
            self.rest.items.len = keep.len;
        }
    }

    pub fn pending(self: *TailStream, out_a: std.mem.Allocator) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        if (self.rest.items.len > 0) {
            const text = render.stripAnsi(out_a, self.rest.items);
            out.append(out_a, .{ .text = text, .style = .{ .fg = theme.current.comment } }) catch {};
        }
        return out.items;
    }

    pub fn reset(self: *TailStream) void {
        self.rest = .empty;
        _ = self.arena.reset(.retain_capacity);
        self.a = self.arena.allocator();
    }
};
