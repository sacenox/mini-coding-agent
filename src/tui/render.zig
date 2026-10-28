const std = @import("std");
const styles = @import("styles.zig");
const wcwidth = @import("width.zig");
const utf8 = @import("../text.zig");

pub const nextCluster = wcwidth.nextCluster;

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (nextPiece(text, &i)) |piece| width += piece.width;
    return width;
}

pub fn rowsForCells(cells: usize, width: usize) usize {
    if (cells == 0) return 1;
    return (cells + width - 1) / width;
}

pub fn physicalRows(line: []const u8, width: usize) usize {
    return rowsForCells(displayWidth(line), width);
}

const Piece = struct { text: []const u8, width: usize, sgr: bool };

fn nextPiece(text: []const u8, i: *usize) ?Piece {
    if (i.* >= text.len) return null;
    if (isSgrAt(text, i.*)) |n| {
        const piece = Piece{ .text = text[i.* .. i.* + n], .width = 0, .sgr = true };
        i.* += n;
        return piece;
    }
    if (wcwidth.nextCluster(text, i.*)) |cluster| {
        const piece = Piece{ .text = cluster.text, .width = if (cluster.text[0] == '\t') 0 else cluster.width, .sgr = false };
        i.* += cluster.text.len;
        return piece;
    }
    const len = (utf8.decodeAt(text, i.*) orelse return null).len;
    const piece = Piece{ .text = text[i.* .. i.* + len], .width = 1, .sgr = false };
    i.* += len;
    return piece;
}

fn isSgrAt(text: []const u8, i: usize) ?usize {
    if (i + 1 >= text.len or text[i] != 0x1b or text[i + 1] != '[') return null;
    var j = i + 2;
    while (j < text.len and (text[j] == ';' or (text[j] >= '0' and text[j] <= '9'))) j += 1;
    if (j < text.len and text[j] == 'm') return j - i + 1;
    if (j < text.len and text[j] == ':') {
        while (j < text.len and (text[j] == ':' or text[j] == ';' or (text[j] >= '0' and text[j] <= '9'))) j += 1;
        if (j < text.len and text[j] == 'm') return j - i + 1;
    }
    if (j == i + 2 and j < text.len and text[j] == 'm') return j - i + 1;
    return null;
}

fn escapeLen(text: []const u8, i: usize) usize {
    if (i + 1 >= text.len) return 1;
    if (text[i + 1] == '[') {
        var j = i + 2;
        while (j < text.len and (text[j] < 0x40 or text[j] > 0x7e)) j += 1;
        return (if (j < text.len) j + 1 else text.len) - i;
    }
    if (text[i + 1] == ']') {
        var j = i + 2;
        while (j < text.len) : (j += 1) {
            if (text[j] == 0x07) return j + 1 - i;
            if (text[j] == 0x1b and j + 1 < text.len and text[j + 1] == '\\') return j + 2 - i;
        }
        return text.len - i;
    }
    return 2;
}

pub fn sanitize(a: std.mem.Allocator, text: []const u8) []const u8 {
    var clean = true;
    for (text) |c| {
        if (c >= 0x80 or c == 0x1b or c == 0x7f or (c < 0x20 and c != 0x09 and c != 0x0a)) {
            clean = false;
            break;
        }
    }
    if (clean) return text;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == 0x1b) {
            if (isSgrAt(text, i)) |n| {
                out.appendSlice(a, text[i .. i + n]) catch {};
                i += n;
            } else {
                i += escapeLen(text, i);
            }
            continue;
        }
        if (c < 0x80) {
            if ((c < 0x20 and c != 0x09 and c != 0x0a) or c == 0x7f) {
                i += 1;
                continue;
            }
            out.append(a, c) catch {};
            i += 1;
            continue;
        }
        const d = utf8.decodeAt(text, i) orelse break;
        if (d.cp > 0x9f) out.appendSlice(a, text[i .. i + d.len]) catch {};
        i += d.len;
    }
    return out.items;
}

pub fn stripAnsi(a: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += escapeLen(text, i);
            continue;
        }
        out.append(a, text[i]) catch {};
        i += 1;
    }
    return out.items;
}

pub fn expandTabs(a: std.mem.Allocator, text: []const u8, size: usize) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var column: usize = 0;
    var i: usize = 0;
    while (nextPiece(text, &i)) |piece| {
        if (piece.text[0] != '\t') {
            out.appendSlice(a, piece.text) catch {};
            column += piece.width;
            continue;
        }
        const spaces = size - (column % size);
        var k: usize = 0;
        while (k < spaces) : (k += 1) out.append(a, ' ') catch {};
        column += spaces;
    }
    return out.items;
}

pub fn wrapLine(a: std.mem.Allocator, text: []const u8, width: usize) []const []const u8 {
    var rows: std.ArrayList([]const u8) = .empty;
    if (width == 0 or text.len == 0) {
        rows.append(a, "") catch {};
        return rows.items;
    }
    var current: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    var active: []const u8 = "";
    var i: usize = 0;
    while (nextPiece(text, &i)) |piece| {
        if (piece.sgr) {
            current.appendSlice(a, piece.text) catch {};
            active = piece.text;
            continue;
        }
        if (used + piece.width > width and used != 0) {
            rows.append(a, current.items) catch {};
            current = .empty;
            current.appendSlice(a, active) catch {};
            used = 0;
        }
        current.appendSlice(a, piece.text) catch {};
        used += piece.width;
    }
    rows.append(a, current.items) catch {};
    return rows.items;
}

pub fn clip(a: std.mem.Allocator, text: []const u8, width: usize) []const u8 {
    if (width == 0) return "";
    if (displayWidth(text) <= width) return text;
    var out: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    var i: usize = 0;
    while (nextPiece(text, &i)) |piece| {
        if (piece.sgr) {
            out.appendSlice(a, piece.text) catch {};
            continue;
        }
        if (used + piece.width > width - 1) break;
        out.appendSlice(a, piece.text) catch {};
        used += piece.width;
    }
    out.appendSlice(a, "…") catch {};
    return out.items;
}

pub const BodyLine = struct {
    text: []const u8,
    style: ?styles.Style = null,
};

const max_body_rows = 12;
const elided_head = 4;
const elided_tail = 4;

pub fn paintRow(a: std.mem.Allocator, line: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}\x1b[K", .{ styles.SGR_PLAIN, line }) catch line;
}

pub fn styleLine(a: std.mem.Allocator, line: BodyLine, base: styles.Style) []const u8 {
    const safe = sanitize(a, line.text);
    const expanded = expandTabs(a, safe, 4);
    if (expanded.len == 0) return "";
    if (line.style == null and !styles.anySet(base)) return expanded;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ styles.sgrOn(a, line.style orelse .{}, base), expanded, styles.SGR_PLAIN }) catch expanded;
}

pub fn plainRows(a: std.mem.Allocator, lines: []const BodyLine, base: styles.Style) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |line| out.append(a, styleLine(a, line, base)) catch {};
    return out.items;
}

pub fn bodyRows(a: std.mem.Allocator, lines: []const BodyLine, width: usize, base: styles.Style) []const []const u8 {
    return elide(a, plainRows(a, lines, base), width);
}

pub fn elide(a: std.mem.Allocator, rows: []const []const u8, width: usize) []const []const u8 {
    var height: usize = 0;
    for (rows) |r| height += physicalRows(r, width);
    if (height <= max_body_rows or rows.len <= elided_head + elided_tail) return rows;
    const tail_at = rows.len - elided_tail;
    var shown: usize = 0;
    var head: usize = 0;
    while (head < tail_at) : (head += 1) {
        const h = physicalRows(rows[head], width);
        if (shown + h + elided_tail > max_body_rows - 1) break;
        shown += h;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (rows[0..head]) |r| out.append(a, r) catch {};
    const hidden_rows: usize = blk: {
        var n = height;
        for (rows[0..head]) |r| n -= physicalRows(r, width);
        for (rows[tail_at..]) |r| n -= physicalRows(r, width);
        break :blk n;
    };
    out.append(a, styles.comment(a, std.fmt.allocPrint(a, "... {d} lines not shown ...", .{hidden_rows}) catch "")) catch {};
    for (rows[tail_at..]) |r| out.append(a, r) catch {};
    return out.items;
}
