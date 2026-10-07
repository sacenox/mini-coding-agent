const std = @import("std");
const tables = @import("width_tables.zig");

pub const Cluster = struct { text: []const u8, width: u8 };

fn inRanges(comptime ranges: []const tables.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid].lo) hi = mid else if (cp > ranges[mid].hi) lo = mid + 1 else return true;
    }
    return false;
}

fn classOf(cp: u21) ?tables.Class {
    var lo: usize = 0;
    var hi: usize = tables.grapheme.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < tables.grapheme[mid].lo) {
            hi = mid;
        } else if (cp > tables.grapheme[mid].hi) {
            lo = mid + 1;
        } else {
            return tables.grapheme[mid].class;
        }
    }
    return null;
}

fn isZero(cp: u21) bool {
    return inRanges(&tables.zero, cp);
}

pub fn charWidth(cp: u21) u8 {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (isZero(cp)) return 0;
    if (inRanges(&tables.wide, cp)) return 2;
    return 1;
}

fn decodeAt(text: []const u8, i: usize) ?struct { cp: u21, len: usize } {
    if (i >= text.len) return null;
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = text[i], .len = 1 };
    if (i + n > text.len) return .{ .cp = text[i], .len = 1 };
    const cp = std.unicode.utf8Decode(text[i .. i + n]) catch return .{ .cp = text[i], .len = 1 };
    return .{ .cp = cp, .len = n };
}

fn isExtPict(cp: u21) bool {
    return inRanges(&tables.extended_pictographic, cp);
}
fn isEmoji(cp: u21) bool {
    return inRanges(&tables.emoji, cp);
}
fn isConsonant(cp: u21) bool {
    return inRanges(&tables.consonant, cp);
}
fn isLinker(cp: u21) bool {
    return inRanges(&tables.linker, cp);
}

const State = struct {
    ri: u32 = 0,
    ext_pict: bool = false,
    zwj_ext_pict: bool = false,
    indic: u2 = 0,
};

fn startsWith(state: *State, cp: u21) void {
    state.* = .{
        .ri = if (classOf(cp) == .regional_indicator) 1 else 0,
        .ext_pict = isExtPict(cp),
        .indic = if (isConsonant(cp)) 1 else 0,
    };
}

fn extends(state: *State, cur: u21) void {
    const cur_class = classOf(cur);
    state.ri = if (cur_class == .regional_indicator) state.ri + 1 else 0;
    if (cur_class == .zwj) {
        state.zwj_ext_pict = state.ext_pict;
    } else if (cur_class != .extend and cur_class != .spacingmark) {
        state.ext_pict = isExtPict(cur);
        state.zwj_ext_pict = false;
    }
    if (isConsonant(cur)) {
        state.indic = 1;
    } else if (isLinker(cur) and state.indic >= 1) {
        state.indic = 2;
    }
}

fn noBreak(state: State, prev: u21, cur: u21) bool {
    const a = classOf(prev);
    const b = classOf(cur);
    if (a == .cr and b == .lf) return true;
    if (a == .cr or a == .lf or a == .control) return false;
    if (b == .cr or b == .lf or b == .control) return false;
    if (a == .l and (b == .l or b == .v or b == .lv or b == .lvt)) return true;
    if ((a == .lv or a == .v) and (b == .v or b == .t)) return true;
    if ((a == .lvt or a == .t) and b == .t) return true;
    if (b == .extend or b == .zwj) return true;
    if (b == .spacingmark) return true;
    if (a == .prepend) return true;
    if (a != null and a.? == .zwj and state.zwj_ext_pict and isExtPict(cur)) return true;
    if (a == .regional_indicator and b == .regional_indicator and state.ri % 2 == 1) return true;
    if (state.indic == 2 and isConsonant(cur)) return true;
    return false;
}

fn clusterWidth(text: []const u8) u8 {
    var width: u8 = 0;
    var has_vs16 = false;
    var base: u21 = 0;
    var i: usize = 0;
    var first = true;
    while (i < text.len) {
        const d = decodeAt(text, i) orelse break;
        if (d.cp == 0xfe0f) has_vs16 = true;
        if (first) {
            base = d.cp;
            first = false;
        }
        width = @max(width, charWidth(d.cp));
        i += d.len;
    }
    if (has_vs16 and isEmoji(base)) width = @max(width, 2);
    return width;
}

pub fn nextCluster(text: []const u8, i: usize) ?Cluster {
    const d = decodeAt(text, i) orelse return null;
    var state = State{};
    startsWith(&state, d.cp);
    var end = i + d.len;
    var prev = d.cp;
    while (end < text.len) {
        const n = decodeAt(text, end) orelse break;
        if (!noBreak(state, prev, n.cp)) break;
        extends(&state, n.cp);
        prev = n.cp;
        end += n.len;
    }
    return .{ .text = text[i..end], .width = clusterWidth(text[i..end]) };
}

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (nextCluster(text, i)) |cluster| {
        width += cluster.width;
        i += cluster.text.len;
    }
    return width;
}
