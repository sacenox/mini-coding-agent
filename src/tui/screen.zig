const std = @import("std");
const platform = @import("../platform.zig");
const theme = @import("theme.zig");
const render = @import("render.zig");

const rowsForCells = render.rowsForCells;

pub const LiveRegion = struct {
    widths: std.ArrayList(usize) = .empty,
    caret_line: usize = 0,
    caret_cell: usize = 0,
    drawn: bool = false,

    fn remember(self: *LiveRegion, lines: []const []const u8, caret_line: usize, caret_cell: usize) void {
        self.widths.clearRetainingCapacity();
        for (lines) |line| self.widths.append(platform.gpa, render.displayWidth(line)) catch {};
        self.caret_line = caret_line;
        self.caret_cell = caret_cell;
        self.drawn = true;
    }

    fn caretCell(self: *LiveRegion, width: usize) usize {
        const w = if (self.caret_line < self.widths.items.len) self.widths.items[self.caret_line] else 0;
        if (self.caret_cell > 0 and self.caret_cell == w and self.caret_cell % width == 0) return self.caret_cell - 1;
        return self.caret_cell;
    }

    fn caretRow(self: *LiveRegion, width: usize) usize {
        var row: usize = 0;
        const lines = @min(self.caret_line, self.widths.items.len);
        for (self.widths.items[0..lines]) |cells| row += rowsForCells(cells, width);
        return row + self.caretCell(width) / width;
    }

    fn totalRows(self: *LiveRegion, width: usize) usize {
        var row: usize = 0;
        for (self.widths.items) |cells| row += rowsForCells(cells, width);
        return row;
    }

    pub fn erase(self: *LiveRegion, a: std.mem.Allocator, width: usize) []const u8 {
        if (!self.drawn) return "";
        const up = self.caretRow(width);
        var out: std.ArrayList(u8) = .empty;
        if (up > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}A", .{up}) catch "") catch {};
        out.appendSlice(a, "\r") catch {};
        out.appendSlice(a, theme.SGR_PLAIN) catch {};
        out.appendSlice(a, "\x1b[J") catch {};
        return out.items;
    }

    pub fn draw(self: *LiveRegion, a: std.mem.Allocator, width: usize, lines: []const []const u8, caret_line: usize, caret_cell: usize, above: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, self.erase(a, width)) catch {};
        out.appendSlice(a, above) catch {};
        for (lines, 0..) |line, i| {
            if (i > 0) out.appendSlice(a, "\r\n") catch {};
            out.appendSlice(a, line) catch {};
        }
        self.remember(lines, caret_line, caret_cell);
        const end_row = self.totalRows(width) - 1;
        const caret_row = self.caretRow(width);
        const up = if (end_row > caret_row) end_row - caret_row else 0;
        if (up > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}A", .{up}) catch "") catch {};
        out.appendSlice(a, "\r") catch {};
        const col = self.caretCell(width) % width;
        if (col > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}C", .{col}) catch "") catch {};
        return out.items;
    }
};

pub const Scrollback = struct {
    a: std.mem.Allocator = undefined,
    scratch: std.mem.Allocator = undefined,
    buf: std.ArrayList(u8) = .empty,
    wrote: bool = false,
    last_blank: bool = false,
    separator: bool = false,

    pub fn clear(self: *Scrollback) void {
        self.buf.clearRetainingCapacity();
    }

    pub fn push(self: *Scrollback, line: []const u8) void {
        const clean = render.sanitize(self.scratch, line);
        const blank = clean.len == 0 or (self.separator and self.wrote);
        self.separator = false;
        if (blank and self.wrote and !self.last_blank) {
            self.buf.appendSlice(self.a, render.paintRow(self.scratch, "")) catch {};
            self.buf.appendSlice(self.a, "\r\n") catch {};
            self.last_blank = true;
        }
        if (clean.len != 0) {
            self.buf.appendSlice(self.a, render.paintRow(self.scratch, clean)) catch {};
            self.buf.appendSlice(self.a, "\r\n") catch {};
            self.wrote = true;
            self.last_blank = false;
        }
    }

    pub fn commitLines(self: *Scrollback, lines: []const render.BodyLine) void {
        for (lines) |line| self.push(render.styleLine(self.scratch, line));
    }

    pub fn note(self: *Scrollback, line: []const u8) void {
        self.separator = true;
        self.push(line);
        self.separator = true;
    }

    pub fn commitUser(self: *Scrollback, text: []const u8) void {
        self.separator = true;
        var it = std.mem.splitScalar(u8, text, '\n');
        var lines: std.ArrayList(render.BodyLine) = .empty;
        while (it.next()) |l| lines.append(self.scratch, .{ .text = l, .style = .{ .fg = theme.current.prompt } }) catch {};
        self.commitLines(lines.items);
        self.separator = true;
    }
};
