const std = @import("std");
const wcwidth = @import("width.zig");

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

fn decodeLen(text: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    return if (i + n > text.len) 1 else n;
}

fn decodeCp(text: []const u8, i: usize) u21 {
    const n = decodeLen(text, i);
    if (text[i] < 0x80) return text[i];
    return std.unicode.utf8Decode(text[i .. i + n]) catch text[i];
}

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
    const len = decodeLen(text, i.*);
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
                continue;
            }
            if (i + 1 < text.len) {
                i += 2;
                if (text[i - 1] == '[') {
                    while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
                    if (i < text.len) i += 1;
                }
                continue;
            }
            i += 1;
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
        const cp = decodeCp(text, i);
        if (cp >= 0x80 and cp <= 0x9f) {
            i += decodeLen(text, i);
            continue;
        }
        const len = decodeLen(text, i);
        out.appendSlice(a, text[i .. i + len]) catch {};
        i += len;
    }
    return out.items;
}

pub fn stripAnsi(a: std.mem.Allocator, text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) {
            out.append(a, text[i]) catch {};
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) break;
        if (text[i] == '[') {
            i += 1;
            while (i < text.len and (text[i] < 0x40 or text[i] > 0x7e)) i += 1;
            if (i < text.len) i += 1;
            continue;
        }
        if (text[i] == ']') {
            i += 1;
            while (i < text.len) {
                if (text[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            continue;
        }
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
