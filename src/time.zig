const std = @import("std");
const platform = @import("platform.zig");

pub fn nowMs() i64 {
    return std.Io.Timestamp.now(platform.io, .real).toMilliseconds();
}

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

pub fn stamp(buf: []u8, ms: i64) []const u8 {
    const d = Date.fromMs(ms);
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        d.year, d.month, d.day, d.hour, d.minute, d.second,
    }) catch unreachable;
}
