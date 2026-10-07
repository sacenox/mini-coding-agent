const std = @import("std");

pub const Key = union(enum) {
    text: []const u8,
    submit,
    newline,
    backspace,
    delete,
    word_back,
    left,
    right,
    word_left,
    word_right,
    up,
    down,
    home,
    end,
    doc_start,
    doc_end,
    tab,
    escape,
    interrupt,
    eof,
};

const SHIFT: u32 = 1;
const ALT: u32 = 2;
const CTRL: u32 = 4;
const MODS: u32 = SHIFT | ALT | CTRL;

const CODE = struct {
    const enter = 13;
    const escape = 27;
    const tab = 9;
    const backspace = 127;
    const delete = 57349;
    const left = 57350;
    const right = 57351;
    const up = 57352;
    const down = 57353;
    const home = 57356;
    const end = 57357;
};

fn lookup(code: u32, mods: u32) ?Key {
    const k = code * 8 + mods;
    return switch (k) {
        CODE.enter * 8 + 0 => .submit,
        CODE.enter * 8 + ALT => .newline,
        CODE.enter * 8 + SHIFT => .newline,
        CODE.escape * 8 + 0 => .escape,
        CODE.tab * 8 + 0 => .tab,
        CODE.backspace * 8 + 0 => .backspace,
        CODE.backspace * 8 + CTRL => .word_back,
        CODE.delete * 8 + 0 => .delete,
        CODE.left * 8 + 0 => .left,
        CODE.left * 8 + CTRL => .word_left,
        CODE.right * 8 + 0 => .right,
        CODE.right * 8 + CTRL => .word_right,
        CODE.up * 8 + 0 => .up,
        CODE.down * 8 + 0 => .down,
        CODE.home * 8 + 0 => .home,
        CODE.home * 8 + CTRL => .doc_start,
        CODE.end * 8 + 0 => .end,
        CODE.end * 8 + CTRL => .doc_end,
        97 * 8 + CTRL => .home,
        98 * 8 + ALT => .word_back,
        99 * 8 + CTRL => .interrupt,
        100 * 8 + CTRL => .eof,
        101 * 8 + CTRL => .end,
        106 * 8 + CTRL => .newline,
        119 * 8 + CTRL => .word_back,
        else => null,
    };
}

const PASTE_START = "\x1b[200~";
const PASTE_END = "\x1b[201~";

pub const Parser = struct {
    buffer: std.ArrayList(u8) = .empty,
    pasting: bool = false,

    pub const Pending = enum { none, escape, sequence };

    pub fn pending(self: *Parser) Pending {
        if (self.pasting) return .none;
        if (self.buffer.items.len == 1 and self.buffer.items[0] == 0x1b) return .escape;
        return if (self.buffer.items.len > 1) .sequence else .none;
    }

    pub fn flushEscape(self: *Parser, a: std.mem.Allocator, out: *std.ArrayList(Key)) void {
        if (self.buffer.items.len != 1 or self.buffer.items[0] != 0x1b) return;
        self.buffer.clearRetainingCapacity();
        out.append(a, .escape) catch {};
    }

    pub fn flushSequence(self: *Parser) void {
        self.buffer.clearRetainingCapacity();
    }

    pub fn feed(self: *Parser, a: std.mem.Allocator, chunk: []const u8, out: *std.ArrayList(Key)) void {
        self.buffer.appendSlice(a, chunk) catch {};
        const buf = self.buffer.items;
        var i: usize = 0;
        while (true) {
            if (self.pasting) {
                const rest = buf[i..];
                if (std.mem.indexOf(u8, rest, PASTE_END)) |end| {
                    if (end > 0) out.append(a, .{ .text = normalizePaste(a, rest[0..end]) }) catch {};
                    i += end + PASTE_END.len;
                    self.pasting = false;
                    continue;
                }
                if (rest.len > PASTE_END.len) {
                    const keep = PASTE_END.len - 1;
                    const emit = rest[0 .. rest.len - keep];
                    if (emit.len > 0) out.append(a, .{ .text = normalizePaste(a, emit) }) catch {};
                    i += emit.len;
                }
                break;
            }
            if (i >= buf.len) break;
            if (std.mem.startsWith(u8, buf[i..], PASTE_START)) {
                i += PASTE_START.len;
                self.pasting = true;
                continue;
            }
            if (buf[i] == 0x1b) {
                if (!self.parseEscape(a, buf, &i, out)) break;
                continue;
            }
            const seq_len = std.unicode.utf8ByteSequenceLength(buf[i]) catch 1;
            if (i + seq_len > buf.len) break;
            const cp = std.unicode.utf8Decode(buf[i .. i + seq_len]) catch buf[i];
            if (cp < 0x20) {
                if (cp == 0x08) {
                    if (lookup(CODE.backspace, 0)) |key| out.append(a, key) catch {};
                } else if (cp == 0x09) {
                    out.append(a, .tab) catch {};
                } else if (cp == 0x0d) {
                    out.append(a, .submit) catch {};
                } else {
                    if (lookup(@as(u32, cp) + 0x60, CTRL)) |key| out.append(a, key) catch {};
                }
            } else if (cp == 0x7f) {
                if (lookup(CODE.backspace, 0)) |key| out.append(a, key) catch {};
            } else {
                out.append(a, .{ .text = a.dupe(u8, buf[i .. i + seq_len]) catch "" }) catch {};
            }
            i += seq_len;
        }
        if (i > 0) {
            const remaining = buf[i..];
            std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
            self.buffer.items.len = remaining.len;
        }
    }

    fn parseEscape(self: *Parser, a: std.mem.Allocator, buf: []const u8, i: *usize, out: *std.ArrayList(Key)) bool {
        if (buf.len - i.* < 2) return false;
        const next = buf[i.* + 1];
        if (next == '[' or next == 'O') return self.parseCsi(a, buf, i, out);
        if (next == ']') return self.skipString(buf, i, true);
        if (next == 'P' or next == 'X' or next == '^' or next == '_') return self.skipString(buf, i, false);
        const cp = next;
        i.* += 2;
        if (lookup(cp, ALT)) |key| out.append(a, key) catch {};
        return true;
    }

    fn parseCsi(self: *Parser, a: std.mem.Allocator, buf: []const u8, i: *usize, out: *std.ArrayList(Key)) bool {
        _ = self;
        var j = i.* + 2;
        while (j < buf.len) : (j += 1) {
            const c = buf[j];
            if (c >= 0x40 and c <= 0x7e) break;
        }
        if (j >= buf.len) return false;
        const final = buf[j];
        const params = buf[i.* + 2 .. j];
        i.* = j + 1;
        var code: ?u32 = null;
        var mods: u32 = 0;
        if (final == 'u') {
            var fields = std.mem.splitScalar(u8, params, ';');
            const first = fields.next() orelse "";
            const code_str = first[0 .. std.mem.indexOfScalar(u8, first, ':') orelse first.len];
            const c = std.fmt.parseInt(u32, code_str, 10) catch return true;
            if (c >= 57344) return true;
            code = c;
            if (fields.next()) |m| {
                const mstr = m[0 .. std.mem.indexOfScalar(u8, m, ':') orelse m.len];
                mods = modsOf(mstr);
            }
        } else {
            if (final == '~') {
                var fields = std.mem.splitScalar(u8, params, ';');
                const first = fields.next() orelse "";
                const n = std.fmt.parseInt(u32, first, 10) catch return true;
                code = switch (n) {
                    1, 7 => CODE.home,
                    3 => CODE.delete,
                    4, 8 => CODE.end,
                    else => null,
                };
                if (fields.next()) |m| mods = modsOf(m);
            } else {
                code = switch (final) {
                    'A' => CODE.up,
                    'B' => CODE.down,
                    'C' => CODE.right,
                    'D' => CODE.left,
                    'H' => CODE.home,
                    'F' => CODE.end,
                    else => null,
                };
                if (std.mem.indexOfScalar(u8, params, ';')) |semi| mods = modsOf(params[semi + 1 ..]);
            }
        }
        if (code) |c| {
            if (lookup(c, mods)) |key| out.append(a, key) catch {};
        }
        return true;
    }

    fn skipString(self: *Parser, buf: []const u8, i: *usize, bel: bool) bool {
        _ = self;
        const rest = buf[i.* + 2 ..];
        const st = std.mem.indexOf(u8, rest, "\x1b\\");
        const bell = if (bel) std.mem.indexOfScalar(u8, rest, 0x07) else null;
        var end: ?usize = null;
        if (bell) |b| {
            if (st == null or b < st.?) end = i.* + 2 + b + 1;
        }
        if (end == null) {
            if (st) |s| end = i.* + 2 + s + 2;
        }
        if (end) |e| {
            i.* = e;
            return true;
        }
        return false;
    }
};

fn modsOf(field: []const u8) u32 {
    const raw = std.fmt.parseInt(u32, field, 10) catch return 0;
    if (raw == 0) return 0;
    return (raw - 1) & MODS;
}

fn normalizePaste(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            out.append(a, '\n') catch {};
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        } else {
            out.append(a, text[i]) catch {};
        }
    }
    return out.items;
}
