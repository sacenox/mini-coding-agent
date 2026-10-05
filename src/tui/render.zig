const std = @import("std");

pub fn charWidth(code: u21) u8 {
    if (code < 32 or (code >= 0x7f and code < 0xa0)) return 0;
    if (code == 0x200b or code == 0x200c or code == 0x200d or code == 0xfeff) return 0;
    if (code >= 0xfe00 and code <= 0xfe0f) return 0;
    if (code >= 0xe0100 and code <= 0xe01ef) return 0;
    if (isCombining(code)) return 0;
    if ((code >= 0x1100 and code <= 0x115f) or
        (code >= 0x2e80 and code <= 0x303e) or
        (code >= 0x3041 and code <= 0x33ff) or
        (code >= 0x3400 and code <= 0x4dbf) or
        (code >= 0x4e00 and code <= 0x9fff) or
        (code >= 0xa000 and code <= 0xa4cf) or
        (code >= 0xac00 and code <= 0xd7a3) or
        (code >= 0xf900 and code <= 0xfaff) or
        (code >= 0xfe10 and code <= 0xfe19) or
        (code >= 0xfe30 and code <= 0xfe6f) or
        (code >= 0xff00 and code <= 0xff60) or
        (code >= 0xffe0 and code <= 0xffe6) or
        (code >= 0x1f300 and code <= 0x1faff) or
        (code >= 0x20000 and code <= 0x3fffd))
    {
        return 2;
    }
    return 1;
}

fn isCombining(code: u21) bool {
    return (code >= 0x0300 and code <= 0x036f) or
        (code >= 0x0483 and code <= 0x0489) or
        (code >= 0x0591 and code <= 0x05bd) or
        (code >= 0x0610 and code <= 0x061a) or
        (code >= 0x064b and code <= 0x065f) or
        (code >= 0x0670 and code <= 0x0670) or
        (code >= 0x06d6 and code <= 0x06dc) or
        (code >= 0x06df and code <= 0x06e4) or
        (code >= 0x0730 and code <= 0x074a) or
        (code >= 0x07a6 and code <= 0x07b0) or
        (code >= 0x0900 and code <= 0x0903) or
        (code >= 0x093a and code <= 0x094f) or
        (code >= 0x0951 and code <= 0x0957) or
        (code >= 0x0962 and code <= 0x0963) or
        (code >= 0x0e31 and code <= 0x0e31) or
        (code >= 0x0e34 and code <= 0x0e3a) or
        (code >= 0x0e47 and code <= 0x0e4e) or
        (code >= 0x1ab0 and code <= 0x1aff) or
        (code >= 0x1dc0 and code <= 0x1dff) or
        (code >= 0x20d0 and code <= 0x20ff) or
        (code >= 0xfe20 and code <= 0xfe2f);
}

const Piece = struct { text: []const u8, width: usize };

fn nextPiece(text: []const u8, i: *usize) ?Piece {
    if (i.* >= text.len) return null;
    if (isSgrAt(text, i.*)) |n| {
        const piece = Piece{ .text = text[i.* .. i.* + n], .width = 0 };
        i.* += n;
        return piece;
    }
    const n = std.unicode.utf8ByteSequenceLength(text[i.*]) catch 1;
    const len = @min(@as(usize, n), text.len - i.*);
    const cp = std.unicode.utf8Decode(text[i.* .. i.* + len]) catch text[i.*];
    const piece = Piece{ .text = text[i.* .. i.* + len], .width = if (cp == '\t') 0 else charWidth(cp) };
    i.* += len;
    return piece;
}

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (nextPiece(text, &i)) |piece| width += piece.width;
    return width;
}

fn isSgrAt(text: []const u8, i: usize) ?usize {
    if (i + 1 >= text.len or text[i] != 0x1b or text[i + 1] != '[') return null;
    var j = i + 2;
    while (j < text.len and (text[j] == ';' or (text[j] >= '0' and text[j] <= '9'))) j += 1;
    if (j < text.len and text[j] == 'm') return j - i + 1;
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
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const len = @min(@as(usize, seq_len), text.len - i);
        if (c < 0x80) {
            if ((c < 0x20 and c != 0x09 and c != 0x0a) or c == 0x7f) {
                i += 1;
                continue;
            }
            out.append(a, c) catch {};
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch 0;
        if (cp >= 0x80 and cp <= 0x9f) {
            i += len;
            continue;
        }
        out.appendSlice(a, text[i .. i + len]) catch {};
        i += len;
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
    var i: usize = 0;
    while (nextPiece(text, &i)) |piece| {
        if (used + piece.width > width and current.items.len != 0) {
            rows.append(a, current.items) catch {};
            current = .empty;
            used = 0;
        }
        current.appendSlice(a, piece.text) catch {};
        used += piece.width;
    }
    rows.append(a, current.items) catch {};
    return rows.items;
}
