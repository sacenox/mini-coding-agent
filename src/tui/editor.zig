const std = @import("std");
const render = @import("render.zig");
const input = @import("input.zig");

const TAB = 4;

const physicalRows = render.physicalRows;

fn isSpace(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x0b or cp == 0x0c or cp == 0xa0;
}

fn cpLen(line: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < line.len) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        i += @min(@as(usize, n), line.len - i);
        count += 1;
    }
    return count;
}

fn cpAt(line: []const u8, col: usize) u21 {
    var i: usize = 0;
    var count: usize = 0;
    while (i < line.len) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const len = @min(@as(usize, n), line.len - i);
        if (count == col) return std.unicode.utf8Decode(line[i .. i + len]) catch line[i];
        i += len;
        count += 1;
    }
    return 0;
}

fn byteOf(line: []const u8, col: usize) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < line.len and count < col) {
        const n = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        i += @min(@as(usize, n), line.len - i);
        count += 1;
    }
    return i;
}

fn sub(a: std.mem.Allocator, line: []const u8, start: usize, end: usize) []const u8 {
    const s = byteOf(line, start);
    const e = byteOf(line, end);
    return a.dupe(u8, line[s..e]) catch "";
}

fn cat(a: std.mem.Allocator, parts: []const []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| out.appendSlice(a, p) catch {};
    return out.items;
}

fn wordStart(line: []const u8, col: usize) usize {
    var i = col;
    while (i > 0 and isSpace(cpAt(line, i - 1))) i -= 1;
    while (i > 0 and !isSpace(cpAt(line, i - 1))) i -= 1;
    return i;
}

fn wordEnd(line: []const u8, col: usize) usize {
    const n = cpLen(line);
    var i = col;
    while (i < n and isSpace(cpAt(line, i))) i += 1;
    while (i < n and !isSpace(cpAt(line, i))) i += 1;
    return i;
}

pub const Render = struct {
    rows: []const []const u8,
    cursor_row: usize,
    cursor_col: usize,
};

pub const Action = enum { submit, changed, none };

pub const Editor = struct {
    lines: std.ArrayList([]const u8) = .empty,
    row: usize = 0,
    col: usize = 0,
    width: usize = 80,
    a: std.mem.Allocator,
    s: std.mem.Allocator = undefined,

    pub fn init(a: std.mem.Allocator) Editor {
        var e = Editor{ .a = a };
        e.lines.append(a, "") catch {};
        return e;
    }

    pub fn contents(self: *Editor) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.lines.items, 0..) |line, i| {
            if (i > 0) out.append(self.a, '\n') catch {};
            out.appendSlice(self.a, line) catch {};
        }
        return out.items;
    }

    pub fn clear(self: *Editor) void {
        self.lines = .empty;
        self.lines.append(self.a, "") catch {};
        self.row = 0;
        self.col = 0;
    }

    pub fn setText(self: *Editor, draft: []const u8) void {
        self.lines = .empty;
        var it = std.mem.splitScalar(u8, draft, '\n');
        while (it.next()) |line| self.lines.append(self.a, self.a.dupe(u8, line) catch "") catch {};
        if (self.lines.items.len == 0) self.lines.append(self.a, "") catch {};
        self.row = self.lines.items.len - 1;
        self.col = cpLen(self.lines.items[self.row]);
    }

    pub fn handle(self: *Editor, key: input.Key) Action {
        switch (key) {
            .submit => return .submit,
            .newline => {
                self.insert("\n");
                return .changed;
            },
            .text => |t| {
                self.insert(t);
                return .changed;
            },
            .backspace => {
                self.backspace();
                return .changed;
            },
            .delete => {
                self.deleteForward();
                return .changed;
            },
            .word_back => {
                self.wordBack();
                return .changed;
            },
            .left => {
                self.left();
                return .changed;
            },
            .right => {
                self.right();
                return .changed;
            },
            .word_left => {
                self.wordLeft();
                return .changed;
            },
            .word_right => {
                self.wordRight();
                return .changed;
            },
            .up => {
                self.up();
                return .changed;
            },
            .down => {
                self.down();
                return .changed;
            },
            .home => {
                self.col = 0;
                return .changed;
            },
            .end => {
                self.col = cpLen(self.lines.items[self.row]);
                return .changed;
            },
            .doc_start => {
                self.row = 0;
                self.col = 0;
                return .changed;
            },
            .doc_end => {
                self.row = self.lines.items.len - 1;
                self.col = cpLen(self.lines.items[self.row]);
                return .changed;
            },
            else => return .none,
        }
    }

    fn cells(self: *Editor, line: []const u8) []usize {
        var out: std.ArrayList(usize) = .empty;
        out.append(self.s, 0) catch {};
        var col: usize = 0;
        var i: usize = 0;
        while (render.nextCluster(line, i)) |cluster| {
            const tab = cluster.text.len == 1 and cluster.text[0] == '\t';
            const advance = if (tab) TAB - (col % TAB) else cluster.width;
            var cps: usize = 0;
            var j: usize = 0;
            while (j < cluster.text.len) {
                const n = std.unicode.utf8ByteSequenceLength(cluster.text[j]) catch 1;
                j += @min(@as(usize, n), cluster.text.len - j);
                cps += 1;
            }
            var m: usize = 0;
            col += advance;
            while (m < cps) : (m += 1) out.append(self.s, col) catch {};
            i += cluster.text.len;
        }
        if (out.items.len == 0) out.append(self.s, 0) catch {};
        return out.items;
    }

    fn colAtCell(self: *Editor, line: []const u8, cell: usize) usize {
        const cs = self.cells(line);
        var i = cs.len - 1;
        while (i > 0 and cs[i] > cell) i -= 1;
        return i;
    }

    fn caret(self: *Editor) struct { row: usize, col: usize } {
        const width = @max(self.width, 1);
        const line = self.lines.items[self.row];
        const cell = self.cells(line)[self.col];
        const rows = render.wrapLine(self.s, render.expandTabs(self.s, line, TAB), width);
        var used: usize = 0;
        for (rows, 0..) |r, i| {
            const w = render.displayWidth(r);
            if (cell < used + w) return .{ .row = i, .col = cell - used };
            used += w;
        }
        const last = render.displayWidth(rows[rows.len - 1]);
        return .{ .row = rows.len - 1, .col = @min(last, width - 1) };
    }

    pub fn layout(self: *Editor, width: usize, max_rows: usize) Render {
        self.width = @max(1, width);
        const view = @max(1, max_rows);
        const n = self.lines.items.len;
        const heights = self.s.alloc(usize, n) catch return .{ .rows = &.{}, .cursor_row = 0, .cursor_col = 0 };
        var caret_line: usize = 0;
        var caret_cell: usize = 0;
        for (self.lines.items, 0..) |line, i| {
            heights[i] = physicalRows(render.expandTabs(self.s, line, TAB), self.width);
            if (i == self.row) {
                caret_line = i;
                caret_cell = self.cells(line)[self.col];
            }
        }
        var start = caret_line;
        var used = heights[caret_line];
        while (start > 0 and used + heights[start - 1] <= view) {
            start -= 1;
            used += heights[start];
        }
        var end = caret_line + 1;
        while (end < n and used + heights[end] <= view) {
            used += heights[end];
            end += 1;
        }
        return .{
            .rows = self.lines.items[start..end],
            .cursor_row = caret_line - start,
            .cursor_col = caret_cell,
        };
    }

    fn insert(self: *Editor, draft: []const u8) void {
        const current = self.lines.items[self.row];
        var parts = std.mem.splitScalar(u8, draft, '\n');
        const first = parts.next() orelse "";
        var rest: std.ArrayList([]const u8) = .empty;
        while (parts.next()) |p| rest.append(self.a, p) catch {};
        const before = sub(self.a, current, 0, self.col);
        const after = sub(self.a, current, self.col, cpLen(current));
        if (rest.items.len == 0) {
            self.lines.items[self.row] = cat(self.a, &.{ before, first, after });
            self.col += cpLen(first);
            return;
        }
        const head = cat(self.a, &.{ before, first });
        const tail = cat(self.a, &.{ rest.items[rest.items.len - 1], after });
        self.lines.items[self.row] = head;
        var insert_at = self.row + 1;
        for (rest.items[0 .. rest.items.len - 1]) |m| {
            self.lines.insert(self.a, insert_at, m) catch {};
            insert_at += 1;
        }
        self.lines.insert(self.a, insert_at, tail) catch {};
        self.row += rest.items.len;
        self.col = cpLen(rest.items[rest.items.len - 1]);
    }

    fn backspace(self: *Editor) void {
        if (self.col > 0) {
            const line = self.lines.items[self.row];
            const before = sub(self.a, line, 0, self.col - 1);
            const after = sub(self.a, line, self.col, cpLen(line));
            self.lines.items[self.row] = cat(self.a, &.{ before, after });
            self.col -= 1;
            return;
        }
        if (self.row > 0) {
            const prev = self.lines.items[self.row - 1];
            const previous = cpLen(prev);
            self.lines.items[self.row - 1] = cat(self.a, &.{ prev, self.lines.items[self.row] });
            _ = self.lines.orderedRemove(self.row);
            self.row -= 1;
            self.col = previous;
        }
    }

    fn deleteForward(self: *Editor) void {
        const line = self.lines.items[self.row];
        const n = cpLen(line);
        if (self.col < n) {
            const before = sub(self.a, line, 0, self.col);
            const after = sub(self.a, line, self.col + 1, n);
            self.lines.items[self.row] = cat(self.a, &.{ before, after });
            return;
        }
        if (self.row < self.lines.items.len - 1) {
            self.lines.items[self.row] = cat(self.a, &.{ line, self.lines.items[self.row + 1] });
            _ = self.lines.orderedRemove(self.row + 1);
        }
    }

    fn left(self: *Editor) void {
        if (self.col > 0) {
            self.col -= 1;
        } else if (self.row > 0) {
            self.row -= 1;
            self.col = cpLen(self.lines.items[self.row]);
        }
    }

    fn right(self: *Editor) void {
        if (self.col < cpLen(self.lines.items[self.row])) {
            self.col += 1;
        } else if (self.row < self.lines.items.len - 1) {
            self.row += 1;
            self.col = 0;
        }
    }

    fn up(self: *Editor) void {
        const width = @max(self.width, 1);
        const line = self.lines.items[self.row];
        const ct = self.caret();
        if (ct.row > 0) {
            self.col = self.colAtCell(line, self.cells(line)[self.col] - width);
            return;
        }
        if (self.row == 0) return;
        self.row -= 1;
        const previous = self.lines.items[self.row];
        const expanded = render.expandTabs(self.s, previous, TAB);
        const last_row = render.wrapLine(self.s, expanded, width).len - 1;
        self.col = self.colAtCell(previous, last_row * width + ct.col);
    }

    fn down(self: *Editor) void {
        const width = @max(self.width, 1);
        const line = self.lines.items[self.row];
        const ct = self.caret();
        const expanded = render.expandTabs(self.s, line, TAB);
        if (ct.row < render.wrapLine(self.s, expanded, width).len - 1) {
            self.col = self.colAtCell(line, self.cells(line)[self.col] + width);
            return;
        }
        if (self.row == self.lines.items.len - 1) return;
        self.row += 1;
        self.col = self.colAtCell(self.lines.items[self.row], ct.col);
    }

    fn wordLeft(self: *Editor) void {
        const line = self.lines.items[self.row];
        const start = wordStart(line, self.col);
        if (start != self.col) {
            self.col = start;
            return;
        }
        if (self.row == 0) return;
        self.row -= 1;
        const previous = self.lines.items[self.row];
        self.col = wordStart(previous, cpLen(previous));
    }

    fn wordRight(self: *Editor) void {
        const line = self.lines.items[self.row];
        const end = wordEnd(line, self.col);
        if (end != self.col) {
            self.col = end;
            return;
        }
        if (self.row == self.lines.items.len - 1) return;
        self.row += 1;
        self.col = wordEnd(self.lines.items[self.row], 0);
    }

    fn wordBack(self: *Editor) void {
        const line = self.lines.items[self.row];
        const start = wordStart(line, self.col);
        const before = sub(self.a, line, 0, start);
        const after = sub(self.a, line, self.col, cpLen(line));
        self.lines.items[self.row] = cat(self.a, &.{ before, after });
        self.col = start;
    }

    pub fn completeWord(self: *Editor, step: *const fn (word: []const u8) ?[]const u8) bool {
        const line = self.lines.items[self.row];
        const start = wordStart(line, self.col);
        if (start == self.col) return false;
        if (isSpace(cpAt(line, self.col - 1))) return false;
        const word = sub(self.a, line, start, self.col);
        const completed = step(word) orelse return false;
        const before = sub(self.a, line, 0, start);
        const after = sub(self.a, line, self.col, cpLen(line));
        self.lines.items[self.row] = cat(self.a, &.{ before, completed, after });
        self.col = start + cpLen(completed);
        return true;
    }
};
