const std = @import("std");
const theme = @import("theme.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");

pub const BodyLine = struct {
    text: []const u8,
    style: ?theme.Style = null,
    bg: ?[]const u8 = null,
};

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
    a: std.mem.Allocator,
    rest: std.ArrayList(u8) = .empty,
    fence: ?struct { marker: []const u8, info: []const u8, lines: std.ArrayList([]const u8) } = null,
    prose: std.ArrayList([]const u8) = .empty,

    pub fn init(a: std.mem.Allocator) MarkdownStream {
        return .{ .a = a };
    }

    pub fn feed(self: *MarkdownStream, delta: []const u8) []BodyLine {
        self.rest.appendSlice(self.a, delta) catch {};
        var out: std.ArrayList(BodyLine) = .empty;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.rest.items, i, '\n')) |nl| {
            const line = self.a.dupe(u8, self.rest.items[i..nl]) catch "";
            self.commit(line, &out);
            i = nl + 1;
        }
        if (i > 0) {
            const keep = self.rest.items[i..];
            std.mem.copyForwards(u8, self.rest.items[0..keep.len], keep);
            self.rest.items.len = keep.len;
        }
        return out.items;
    }

    fn commit(self: *MarkdownStream, line: []const u8, out: *std.ArrayList(BodyLine)) void {
        if (self.fence) |*f| {
            if (isFenceClose(line, f.marker)) {
                self.releaseFence(line, out);
            } else {
                f.lines.append(self.a, line) catch {};
            }
            return;
        }
        if (isFenceOpen(line)) |open| {
            self.releaseProse("", out);
            var fl: std.ArrayList([]const u8) = .empty;
            fl.append(self.a, line) catch {};
            self.fence = .{ .marker = open.marker, .info = open.info, .lines = fl };
            return;
        }
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            self.releaseProse("", out);
            out.append(self.a, .{ .text = line }) catch {};
            return;
        }
        self.prose.append(self.a, line) catch {};
    }

    fn releaseProse(self: *MarkdownStream, tail: []const u8, out: *std.ArrayList(BodyLine)) void {
        var prose = self.prose;
        self.prose = .empty;
        if (tail.len > 0) prose.append(self.a, tail) catch {};
        if (prose.items.len == 0) return;
        var joined: std.ArrayList(u8) = .empty;
        for (prose.items, 0..) |l, i| {
            if (i > 0) joined.append(self.a, '\n') catch {};
            joined.appendSlice(self.a, l) catch {};
        }
        joined.append(self.a, '\n') catch {};
        emitHighlighted(self.a, highlight.highlightMarkdown(self.a, highlight.formatTables(self.a, joined.items)), out);
    }

    fn releaseFence(self: *MarkdownStream, closing: ?[]const u8, out: *std.ArrayList(BodyLine)) void {
        const f = self.fence.?;
        self.fence = null;
        out.append(self.a, .{ .text = highlight.highlightMarkdown(self.a, f.lines.items[0]) }) catch {};
        if (f.lines.items.len > 1) {
            var body: std.ArrayList(u8) = .empty;
            for (f.lines.items[1..], 0..) |l, i| {
                if (i > 0) body.append(self.a, '\n') catch {};
                body.appendSlice(self.a, l) catch {};
            }
            var it = std.mem.splitScalar(u8, highlight.highlightCode(self.a, f.info, body.items), '\n');
            while (it.next()) |l| out.append(self.a, .{ .text = l }) catch {};
        }
        if (closing) |c| out.append(self.a, .{ .text = highlight.highlightMarkdown(self.a, c) }) catch {};
    }

    pub fn pending(self: *MarkdownStream) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        const held: []const []const u8 = if (self.fence) |f| f.lines.items else self.prose.items;
        for (held) |l| out.append(self.a, .{ .text = l }) catch {};
        if (self.rest.items.len > 0) out.append(self.a, .{ .text = self.rest.items }) catch {};
        return out.items;
    }

    pub fn flush(self: *MarkdownStream) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        if (self.fence != null) {
            self.releaseFence(null, &out);
            if (self.rest.items.len > 0) out.append(self.a, .{ .text = highlight.highlightMarkdown(self.a, self.rest.items) }) catch {};
        } else {
            self.releaseProse(self.rest.items, &out);
        }
        self.reset();
        return out.items;
    }

    pub fn reset(self: *MarkdownStream) void {
        self.rest = .empty;
        self.fence = null;
        self.prose = .empty;
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
    a: std.mem.Allocator,
    rest: std.ArrayList(u8) = .empty,

    pub fn init(a: std.mem.Allocator) TailStream {
        return .{ .a = a };
    }

    pub fn feed(self: *TailStream, delta: []const u8) void {
        self.rest.appendSlice(self.a, delta) catch {};
        if (std.mem.lastIndexOfScalar(u8, self.rest.items, '\n')) |nl| {
            const keep = self.rest.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.rest.items[0..keep.len], keep);
            self.rest.items.len = keep.len;
        }
    }

    pub fn pending(self: *TailStream) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        if (self.rest.items.len > 0) {
            const text = render.stripAnsi(self.a, self.rest.items);
            out.append(self.a, .{ .text = text, .style = .{ .fg = theme.current.comment } }) catch {};
        }
        return out.items;
    }

    pub fn reset(self: *TailStream) void {
        self.rest = .empty;
    }
};
