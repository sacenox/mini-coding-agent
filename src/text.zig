const std = @import("std");

const binary_sniff = 8192;

pub fn isBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, binary_sniff)], 0) != null;
}

pub fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    return std.mem.count(u8, content, "\n") + @intFromBool(content[content.len - 1] != '\n');
}

pub fn plural(a: std.mem.Allocator, n: usize, one: []const u8, many: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{d} {s}", .{ n, if (n == 1) one else many }) catch many;
}

pub fn join(a: std.mem.Allocator, parts: []const []const u8, sep: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) try out.appendSlice(a, sep);
        try out.appendSlice(a, part);
    }
    return out.items;
}

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

pub const Cp = struct { cp: u21, len: usize };

pub fn decodeAt(bytes: []const u8, i: usize) ?Cp {
    if (i >= bytes.len) return null;
    const b = bytes[i];
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .cp = b, .len = 1 };
    if (i + n > bytes.len) return .{ .cp = b, .len = 1 };
    return .{ .cp = std.unicode.utf8Decode(bytes[i .. i + n]) catch b, .len = n };
}

pub fn cpLen(bytes: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (decodeAt(bytes, i)) |d| {
        i += d.len;
        n += 1;
    }
    return n;
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
