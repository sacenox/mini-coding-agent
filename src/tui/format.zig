const std = @import("std");
const render = @import("render.zig");

/// The text-level half of the renderer: canonical markers, whitespace, and tables.
/// Styling runs afterwards, in highlight.zig, over the bytes produced here.
pub const Normalizer = struct {
    ordered_indent: ?usize = null,
    ordered_next: usize = 1,

    pub fn reset(self: *Normalizer) void {
        self.ordered_indent = null;
        self.ordered_next = 1;
    }

    /// Canonical form of one markdown line: even indentation, one space after every
    /// marker, `-` bullets, sequential ordered runs, `> ` quotes, `---` rules, no
    /// trailing whitespace. Fence bodies never reach this.
    pub fn line(self: *Normalizer, a: std.mem.Allocator, raw: []const u8) []const u8 {
        const text = std.mem.trimEnd(u8, raw, " \t\r");
        const ind = indentOf(text);
        var rest = text[ind.end..];
        if (fenceMarker(rest)) |fence_run| return self.fence(a, ind.cols, rest, fence_run);
        if (isRule(rest)) {
            self.reset();
            return std.fmt.allocPrint(a, "{s}---", .{spaces(a, ind.cols)}) catch "---";
        }
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, spaces(a, ind.cols)) catch {};
        while (rest.len > 0 and rest[0] == '>') {
            out.appendSlice(a, "> ") catch {};
            rest = std.mem.trimStart(u8, rest[1..], " \t");
        }
        return self.body(a, &out, ind.cols, rest);
    }

    fn body(self: *Normalizer, a: std.mem.Allocator, out: *std.ArrayList(u8), indent: usize, rest: []const u8) []const u8 {
        if (heading(rest)) |h| {
            self.reset();
            out.appendNTimes(a, '#', h.level) catch {};
            if (h.text.len > 0) {
                out.append(a, ' ') catch {};
                out.appendSlice(a, h.text) catch {};
            }
            return out.items;
        }
        if (marker(rest)) |m| switch (m) {
            .bullet => {
                self.ordered_indent = null;
                out.appendSlice(a, "- ") catch {};
                out.appendSlice(a, std.mem.trimStart(u8, rest[1..], " \t")) catch {};
            },
            .ordered => |o| {
                const num = if (self.ordered_indent == indent) self.ordered_next else o.num;
                self.ordered_indent = indent;
                self.ordered_next = num + 1;
                out.appendSlice(a, std.fmt.allocPrint(a, "{d}.", .{num}) catch "-") catch {};
                out.append(a, ' ') catch {};
                out.appendSlice(a, std.mem.trimStart(u8, rest[o.at..], " \t")) catch {};
            },
        } else {
            self.ordered_indent = null;
            out.appendSlice(a, rest) catch {};
        }
        return trimmed(out);
    }

    fn fence(self: *Normalizer, a: std.mem.Allocator, indent: usize, rest: []const u8, run: []const u8) []const u8 {
        self.reset();
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, spaces(a, indent)) catch {};
        out.appendSlice(a, run) catch {};
        out.appendSlice(a, std.mem.trim(u8, rest[run.len..], " \t")) catch {};
        return out.items;
    }
};

fn spaces(a: std.mem.Allocator, n: usize) []const u8 {
    const out = a.alloc(u8, n) catch return "";
    @memset(out, ' ');
    return out;
}

fn trimmed(out: *std.ArrayList(u8)) []const u8 {
    while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t'))
        out.items.len -= 1;
    return out.items;
}

const Indent = struct { end: usize, cols: usize };

/// Leading whitespace, with tabs worth two columns and the depth rounded down to even
/// so nested levels line up.
fn indentOf(text: []const u8) Indent {
    var end: usize = 0;
    var cols: usize = 0;
    while (end < text.len and (text[end] == ' ' or text[end] == '\t')) : (end += 1)
        cols += if (text[end] == '\t') 2 else 1;
    return .{ .end = end, .cols = cols & ~@as(usize, 1) };
}

fn fenceMarker(rest: []const u8) ?[]const u8 {
    if (rest.len == 0) return null;
    const c = rest[0];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (n < rest.len and rest[n] == c) n += 1;
    return if (n >= 3) rest[0..n] else null;
}

fn isRule(rest: []const u8) bool {
    if (rest.len == 0) return false;
    const c = rest[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var marks: usize = 0;
    for (rest) |ch| {
        if (ch == c) {
            marks += 1;
        } else if (ch != ' ' and ch != '\t') {
            return false;
        }
    }
    return marks >= 3;
}

const Heading = struct { level: usize, text: []const u8 };

fn heading(rest: []const u8) ?Heading {
    var n: usize = 0;
    while (n < rest.len and rest[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < rest.len and rest[n] != ' ' and rest[n] != '\t') return null;
    var text = std.mem.trimStart(u8, rest[n..], " \t");
    // A closing run of `#`s is decoration; only one that follows a space counts.
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    if (end < text.len and (end == 0 or text[end - 1] == ' ' or text[end - 1] == '\t'))
        text = std.mem.trimEnd(u8, text[0..end], " \t");
    return .{ .level = n, .text = text };
}

const Marker = union(enum) {
    bullet,
    ordered: struct { num: usize, at: usize },
};

/// Byte offset just past the list marker, or null when the line has none.
fn marker(rest: []const u8) ?Marker {
    if (rest.len == 0) return null;
    const c = rest[0];
    if (c == '-' or c == '*' or c == '+')
        return if (rest.len == 1 or rest[1] == ' ' or rest[1] == '\t') .bullet else null;
    var at: usize = 0;
    while (at < rest.len and std.ascii.isDigit(rest[at])) at += 1;
    if (at == 0 or at >= rest.len) return null;
    if (rest[at] != '.' and rest[at] != ')') return null;
    if (at + 1 < rest.len and rest[at + 1] != ' ' and rest[at + 1] != '\t') return null;
    return .{ .ordered = .{ .num = std.fmt.parseInt(usize, rest[0..at], 10) catch 1, .at = at + 1 } };
}

const Align = enum { none, left, center, right };

fn alignOf(cell: []const u8) Align {
    const left = cell.len > 0 and cell[0] == ':';
    const right = cell.len > 1 and cell[cell.len - 1] == ':';
    if (left and right) return .center;
    if (left) return .left;
    if (right) return .right;
    return .none;
}

fn splitCells(a: std.mem.Allocator, line: []const u8) []const []const u8 {
    const trimmed_line = std.mem.trim(u8, line, " \t\r");
    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < trimmed_line.len) : (i += 1) {
        if (trimmed_line[i] == '\\' and i + 1 < trimmed_line.len) {
            i += 1;
            continue;
        }
        if (trimmed_line[i] == '|') {
            cells.append(a, std.mem.trim(u8, trimmed_line[start..i], " \t")) catch {};
            start = i + 1;
        }
    }
    cells.append(a, std.mem.trim(u8, trimmed_line[start..], " \t")) catch {};
    if (trimmed_line.len > 0 and trimmed_line[0] == '|' and cells.items.len > 0) _ = cells.orderedRemove(0);
    if (trimmed_line.len > 1 and trimmed_line[trimmed_line.len - 1] == '|' and cells.items.len > 0) _ = cells.pop();
    return cells.items;
}

/// Index of the `]` closing the `[` at `open`, skipping escaped bytes.
pub fn closeBracket(text: []const u8, open: usize) ?usize {
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == ']') return i;
    }
    return null;
}

/// Index of the `)` closing the `(` at `open`, so destinations may hold parentheses.
pub fn linkEnd(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] != '(' and text[i] != ')') continue;
        if (text[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        } else {
            depth += 1;
        }
    }
    return null;
}

/// The styling pass only adds color, so a cell's own bytes are what gets painted.
fn cellWidth(cell: []const u8) usize {
    return render.displayWidth(cell);
}

/// Delimiter row (`|---|:--:|`) as per-column alignments, or null when the line is not one.
fn delimiterRow(a: std.mem.Allocator, line: []const u8) ?[]const Align {
    if (std.mem.indexOfScalar(u8, line, '-') == null) return null;
    const cells = splitCells(a, line);
    if (cells.len == 0) return null;
    const aligns = a.alloc(Align, cells.len) catch return null;
    for (cells, 0..) |cell, k| {
        var body = cell;
        if (body.len > 0 and body[0] == ':') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == ':') body = body[0 .. body.len - 1];
        if (body.len == 0) return null;
        for (body) |c| {
            if (c != '-') return null;
        }
        aligns[k] = alignOf(cell);
    }
    return aligns;
}

fn tableCandidate(line: []const u8) bool {
    const trimmed_line = std.mem.trim(u8, line, " \t\r");
    if (trimmed_line.len == 0) return false;
    // Tables nested in quotes or lists keep their marker; reflowing them would drop it.
    if (trimmed_line[0] == '>' or trimmed_line[0] == '-' or trimmed_line[0] == '*' or trimmed_line[0] == '+') return false;
    return std.mem.indexOfScalar(u8, trimmed_line, '|') != null;
}

fn rowCells(line: []const u8) bool {
    const trimmed_line = std.mem.trim(u8, line, " \t\r");
    return trimmed_line.len > 0 and std.mem.indexOfScalar(u8, trimmed_line, '|') != null;
}

fn emitRow(a: std.mem.Allocator, block: *std.ArrayList(u8), indent: []const u8, cells: []const []const u8, named: usize, widths: []const usize, aligns: []const Align, delimiter: bool) void {
    block.appendSlice(a, indent) catch {};
    block.append(a, '|') catch {};
    for (0..named) |k| {
        const cell = if (k < cells.len) cells[k] else "";
        const alignment = aligns[k];
        block.append(a, ' ') catch {};
        if (delimiter) {
            block.append(a, if (alignment == .left or alignment == .center) ':' else '-') catch {};
            block.appendNTimes(a, '-', widths[k] - 2) catch {};
            block.append(a, if (alignment == .right or alignment == .center) ':' else '-') catch {};
        } else {
            const pad = widths[k] - cellWidth(cell);
            const before: usize = switch (alignment) {
                .right => pad,
                .center => pad / 2,
                else => 0,
            };
            block.appendNTimes(a, ' ', before) catch {};
            block.appendSlice(a, cell) catch {};
            block.appendNTimes(a, ' ', pad - before) catch {};
        }
        block.appendSlice(a, " |") catch {};
    }
}

/// Leading whitespace, kept so a table nested in a list stays in its item.
fn leadingText(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[0..i];
}

fn formatTable(a: std.mem.Allocator, header: []const u8, aligns: []const Align, body: []const []const u8, trailing: bool) ?[]const u8 {
    const indent = leadingText(header);
    const named = aligns.len;
    const rows = a.alloc([]const []const u8, body.len + 1) catch return null;
    rows[0] = splitCells(a, header);
    if (rows[0].len != named) return null;
    for (body, 0..) |line, i| {
        const cells = splitCells(a, line);
        if (cells.len > named) return null;
        rows[i + 1] = cells;
    }

    const widths = a.alloc(usize, named) catch return null;
    @memset(widths, 3);
    for (rows) |cells| {
        for (cells, 0..) |cell, k| widths[k] = @max(widths[k], cellWidth(cell));
    }

    var block: std.ArrayList(u8) = .empty;
    for (rows, 0..) |cells, r| {
        if (r > 0) block.append(a, '\n') catch {};
        emitRow(a, &block, indent, cells, named, widths, aligns, false);
        if (r == 0) {
            block.append(a, '\n') catch {};
            emitRow(a, &block, indent, &.{}, named, widths, aligns, true);
        }
    }
    if (trailing) block.append(a, '\n') catch {};
    return block.items;
}

pub fn formatTables(a: std.mem.Allocator, text: []const u8) []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| lines.append(a, line) catch {};

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (i + 1 < lines.items.len and tableCandidate(line)) {
            if (delimiterRow(a, lines.items[i + 1])) |aligns| {
                var end = i + 2;
                while (end < lines.items.len and rowCells(lines.items[end])) end += 1;
                const block = formatTable(a, line, aligns, lines.items[i + 2 .. end], end < lines.items.len);
                if (block) |b| {
                    out.appendSlice(a, b) catch {};
                    i = end;
                    continue;
                }
            }
        }
        out.appendSlice(a, line) catch {};
        out.append(a, '\n') catch {};
        i += 1;
    }
    // A single trailing split always leaves one empty entry; drop its newline.
    if (out.items.len > 0 and text.len > 0 and text[text.len - 1] != '\n' and out.items[out.items.len - 1] == '\n')
        out.items.len -= 1;
    return out.items;
}
