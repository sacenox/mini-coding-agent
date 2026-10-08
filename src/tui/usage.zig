const std = @import("std");
const types = @import("../types.zig");
const styles = @import("styles.zig");

pub fn estimateContextTokens(messages: []const types.Message, system_prompt: []const u8, tools_json: []const u8) u64 {
    var last_idx: ?usize = null;
    var usage: u64 = 0;
    for (messages, 0..) |m, i| {
        if (m != .assistant) continue;
        const am = m.assistant;
        if (am.stop_reason == .aborted or am.stop_reason == .err) continue;
        if (am.usage.total_tokens == 0) continue;
        usage = am.usage.total_tokens;
        last_idx = i;
    }
    if (last_idx) |idx| {
        var trailing: u64 = 0;
        for (messages[idx + 1 ..]) |m| trailing += estimateMessageTokens(m);
        return usage + trailing;
    }
    var total: u64 = 0;
    for (messages) |m| total += estimateMessageTokens(m);
    return total + estimateTextTokens(system_prompt) + estimateTextTokens(tools_json);
}

fn estimateTextTokens(text: []const u8) u64 {
    return (text.len + 3) / 4;
}

fn estimateMessageTokens(m: types.Message) u64 {
    return switch (m) {
        .user => |u| estimateTextTokens(u.content),
        .tool_result => |t| estimateTextTokens(t.text),
        .assistant => |am| blk: {
            var chars: usize = 0;
            for (am.content.items) |b| switch (b) {
                .text => |t| chars += t.len,
                .thinking => |t| chars += t.text.len,
                .tool_call => |tc| chars += tc.name.len + tc.arguments.len,
            };
            break :blk (chars + 3) / 4;
        },
    };
}

pub fn formatTokens(a: std.mem.Allocator, n: u64) []const u8 {
    if (n < 1000) return std.fmt.allocPrint(a, "{d}", .{n}) catch "";
    const millions = n >= 1_000_000;
    const div: f64 = if (millions) 1_000_000.0 else 1000.0;
    const unit: []const u8 = if (millions) "M" else "k";
    var buf: [64]u8 = undefined;
    var num = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ @as(f64, @floatFromInt(n)) / div, if (millions) @as(usize, 2) else 1 }) catch return unit;
    while (num.len > 0 and num[num.len - 1] == '0') num = num[0 .. num.len - 1];
    if (num.len > 0 and num[num.len - 1] == '.') num = num[0 .. num.len - 1];
    return std.fmt.allocPrint(a, "{s}{s}", .{ num, unit }) catch unit;
}

pub fn contextUsageLine(a: std.mem.Allocator, used: u64, model: *const types.Model) []const u8 {
    const cw = @max(model.context_window, 1);
    const percent = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(cw)) * 100.0;
    const sizes = std.fmt.allocPrint(a, "{s}/{s}", .{ formatTokens(a, used), formatTokens(a, cw) }) catch "";
    if (used + model.max_tokens > cw) return styles.red(a, std.fmt.allocPrint(a, "ctx full · {s}", .{sizes}) catch "ctx full");
    const text = std.fmt.allocPrint(a, "ctx {s} · {d}%", .{ sizes, @as(u64, @intFromFloat(percent + 0.5)) }) catch "ctx";
    return if (percent >= 85) styles.yellow(a, text) else styles.dim(a, text);
}

pub fn lastUsage(messages: []const types.Message) types.Usage {
    var out: types.Usage = .{};
    for (messages) |m| {
        if (m != .assistant) continue;
        const am = m.assistant;
        if (am.stop_reason == .aborted or am.stop_reason == .err) continue;
        if (am.usage.total_tokens == 0) continue;
        out = am.usage;
    }
    return out;
}

pub fn cacheLine(a: std.mem.Allocator, usage: types.Usage) []const u8 {
    const prompt = usage.input + usage.cache_read + usage.cache_write;
    const pct: u64 = if (prompt == 0)
        0
    else
        @intFromFloat(@as(f64, @floatFromInt(usage.cache_read)) / @as(f64, @floatFromInt(prompt)) * 100.0 + 0.5);
    return styles.dim(a, std.fmt.allocPrint(a, "cache {d}%", .{pct}) catch "cache");
}
