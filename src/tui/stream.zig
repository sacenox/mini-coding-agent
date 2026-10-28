const std = @import("std");
const format = @import("format.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");
const text = @import("../text.zig");

const BodyLine = render.BodyLine;

pub const MarkdownStream = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator = undefined,
    rest: std.ArrayList(u8) = .empty,
    fence: ?struct { marker: []const u8, lines: std.ArrayList([]const u8) } = null,
    prose: std.ArrayList([]const u8) = .empty,
    norm: format.Normalizer = .{},

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

    fn commit(self: *MarkdownStream, out_a: std.mem.Allocator, raw: []const u8, out: *std.ArrayList(BodyLine)) void {
        if (self.fence) |*f| {
            if (format.fenceClose(raw, f.marker)) {
                self.releaseFence(out_a, self.norm.line(self.a, raw), out);
            } else {
                f.lines.append(self.a, raw) catch {};
            }
            return;
        }
        const line = self.norm.line(self.a, raw);
        if (format.fenceRun(line)) |marker| {
            self.releaseProse(out_a, "", out);
            var fl: std.ArrayList([]const u8) = .empty;
            fl.append(self.a, line) catch {};
            self.fence = .{ .marker = marker, .lines = fl };
            return;
        }
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            self.releaseProse(out_a, "", out);
            out.append(out_a, .{ .text = "" }) catch {};
            return;
        }
        self.prose.append(self.a, line) catch {};
    }

    fn releaseProse(self: *MarkdownStream, out_a: std.mem.Allocator, tail: []const u8, out: *std.ArrayList(BodyLine)) void {
        var prose = self.prose;
        self.prose = .empty;
        if (tail.len > 0) prose.append(self.a, tail) catch {};
        if (prose.items.len == 0) return;
        const joined = std.fmt.allocPrint(out_a, "{s}\n", .{text.join(out_a, prose.items, "\n") catch ""}) catch "";
        emitHighlighted(out_a, highlight.highlightMarkdown(out_a, format.formatTables(out_a, joined)), out);
    }

    fn releaseFence(self: *MarkdownStream, out_a: std.mem.Allocator, closing: ?[]const u8, out: *std.ArrayList(BodyLine)) void {
        const f = self.fence.?;
        self.fence = null;
        out.append(out_a, .{ .text = highlight.highlightMarkdown(out_a, f.lines.items[0]) }) catch {};
        if (f.lines.items.len > 1) {
            const body = text.join(out_a, f.lines.items[1..], "\n") catch "";
            var it = std.mem.splitScalar(u8, highlight.highlightCode(out_a, body), '\n');
            while (it.next()) |l| out.append(out_a, .{ .text = l }) catch {};
        }
        if (closing) |c| out.append(out_a, .{ .text = highlight.highlightMarkdown(out_a, c) }) catch {};
    }

    pub fn flush(self: *MarkdownStream, out_a: std.mem.Allocator) []BodyLine {
        var out: std.ArrayList(BodyLine) = .empty;
        if (self.fence) |*f| {
            if (self.rest.items.len > 0) f.lines.append(self.a, self.rest.items) catch {};
            self.releaseFence(out_a, null, &out);
        } else {
            self.releaseProse(out_a, self.norm.line(self.a, self.rest.items), &out);
        }
        self.reset();
        return out.items;
    }

    pub fn reset(self: *MarkdownStream) void {
        self.rest = .empty;
        self.fence = null;
        self.prose = .empty;
        self.norm.reset();
        _ = self.arena.reset(.retain_capacity);
        self.a = self.arena.allocator();
    }
};

fn emitHighlighted(a: std.mem.Allocator, source: []const u8, out: *std.ArrayList(BodyLine)) void {
    const nl = std.mem.lastIndexOfScalar(u8, source, '\n') orelse {
        out.append(a, .{ .text = source }) catch {};
        return;
    };
    const reset = source[nl + 1 ..];
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source[0..nl], '\n');
    while (it.next()) |l| lines.append(a, l) catch {};
    if (lines.items.len > 0) {
        const last = lines.items.len - 1;
        lines.items[last] = std.fmt.allocPrint(a, "{s}{s}", .{ lines.items[last], reset }) catch lines.items[last];
    }
    for (lines.items) |l| out.append(a, .{ .text = l }) catch {};
}
