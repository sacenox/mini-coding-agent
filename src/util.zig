//! Small helpers: time formatting, filesystem reads, path joins, slugs.

const std = @import("std");
const platform = @import("platform.zig");

pub fn nowMs() i64 {
    return std.Io.Timestamp.now(platform.io, .real).toMilliseconds();
}

/// The UTC calendar fields of one epoch millisecond value.
const Date = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    milli: u64,

    fn fromMs(ms: i64) Date {
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(ms, 1000)) };
        const ymd = epoch.getEpochDay().calculateYearDay();
        const md = ymd.calculateMonthDay();
        const ds = epoch.getDaySeconds();
        return .{
            .year = ymd.year,
            .month = md.month.numeric(),
            .day = md.day_index + 1,
            .hour = ds.getHoursIntoDay(),
            .minute = ds.getMinutesIntoHour(),
            .second = ds.getSecondsIntoMinute(),
            .milli = @intCast(@mod(ms, 1000)),
        };
    }
};

/// ISO-8601 UTC with milliseconds, matching `new Date().toISOString()`.
fn isoFromMs(buf: []u8, ms: i64) []const u8 {
    const d = Date.fromMs(ms);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        d.year, d.month, d.day, d.hour, d.minute, d.second, d.milli,
    }) catch unreachable;
}

pub fn isoAlloc(a: std.mem.Allocator) []const u8 {
    const buf = a.alloc(u8, 32) catch unreachable;
    return isoFromMs(buf, nowMs());
}

/// `YYYYMMDD-HHMMSS`, the session directory prefix.
pub fn stamp(buf: []u8, ms: i64) []const u8 {
    const d = Date.fromMs(ms);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        d.year, d.month, d.day, d.hour, d.minute, d.second,
    }) catch unreachable;
}

pub fn join(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

pub fn readFileAlloc(a: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(platform.io, path, a, .limited(max));
}

/// Writes `data` to `path`, creating parent directories. The file is truncated
/// first; a partial write is reported to the caller.
pub fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(platform.io, dir) catch {};
    }
    const f = try std.Io.Dir.cwd().createFile(platform.io, path, .{ .truncate = true });
    defer f.close(platform.io);
    try f.writeStreamingAll(platform.io, data);
}

pub fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(platform.io, path, .{}) catch return false;
    return true;
}

/// Directory names under `root`, skipping the "." and ".." entries. Returns an
/// empty slice when the directory cannot be read.
pub fn listDir(a: std.mem.Allocator, root: []const u8) [][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    const dir = std.Io.Dir.cwd().openDir(platform.io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(platform.io);
    var it = dir.iterate();
    while (it.next(platform.io) catch return out.toOwnedSlice(a) catch &.{}) |entry| {
        out.append(a, a.dupe(u8, entry.name) catch return out.toOwnedSlice(a) catch &.{}) catch
            return out.toOwnedSlice(a) catch &.{};
    }
    return out.toOwnedSlice(a) catch &.{};
}

pub fn randomBytes(buf: []u8) void {
    std.Io.random(platform.io, buf);
}

/// The byte length of a valid UTF-8 sequence at the start of `p`, or null.
/// Ported from the C reference so decoding is identical there and here.
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

/// Replaces invalid byte sequences with U+FFFD so the text survives the JSON
/// and session round trips. Returns `text` unchanged when it is already valid.
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

/// Lowercased, non-alphanumerics collapsed to "-", trimmed, capped at 40.
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
