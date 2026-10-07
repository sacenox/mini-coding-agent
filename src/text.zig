const std = @import("std");

fn utf8SeqLen(p: []const u8) ?usize {
    if (p.len == 0) return null;
    const c = p[0];
    if (c >= 0xC2 and c <= 0xDF) {
        if (p.len >= 2 and p[1] & 0xC0 == 0x80) return 2;
    } else if (c == 0xE0) {
        if (p.len >= 3 and p[1] >= 0xA0 and p[1] <= 0xBF and p[2] & 0xC0 == 0x80) return 3;
    } else if (c >= 0xE1 and c <= 0xEC) {
        if (p.len >= 3 and p[1] & 0xC0 == 0x80 and p[2] & 0xC0 == 0x80) return 3;
    } else if (c == 0xED) {
        if (p.len >= 3 and p[1] >= 0x80 and p[1] <= 0x9F and p[2] & 0xC0 == 0x80) return 3;
    } else if (c >= 0xEE and c <= 0xEF) {
        if (p.len >= 3 and p[1] & 0xC0 == 0x80 and p[2] & 0xC0 == 0x80) return 3;
    } else if (c == 0xF0) {
        if (p.len >= 4 and p[1] >= 0x90 and p[1] <= 0xBF and p[2] & 0xC0 == 0x80 and p[3] & 0xC0 == 0x80) return 4;
    } else if (c >= 0xF1 and c <= 0xF3) {
        if (p.len >= 4 and p[1] & 0xC0 == 0x80 and p[2] & 0xC0 == 0x80 and p[3] & 0xC0 == 0x80) return 4;
    } else if (c == 0xF4) {
        if (p.len >= 4 and p[1] >= 0x80 and p[1] <= 0x8F and p[2] & 0xC0 == 0x80 and p[3] & 0xC0 == 0x80) return 4;
    }
    return null;
}

pub fn utf8Clean(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) {
            try out.append(a, text[i]);
            i += 1;
        } else if (utf8SeqLen(text[i..])) |len| {
            try out.appendSlice(a, text[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

pub fn slugify(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_dash = false;
    for (text) |c| {
        if (out.items.len >= 40) break;
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            if (pending_dash and out.items.len > 0 and out.items.len < 40) out.append(a, '-') catch {};
            pending_dash = false;
            out.append(a, lower) catch {};
        } else {
            pending_dash = true;
        }
    }
    if (out.items.len == 0) return a.dupe(u8, "session") catch "session";
    return out.items;
}
