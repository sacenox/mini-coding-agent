//! The `edit` tool: exact text replacement in a file, or creation when oldText
//! is empty. Returns the unified diff of the change as part of its text.

const std = @import("std");
const util = @import("../util.zig");
const platform = @import("../platform.zig");
const diff = @import("../diff.zig");
const common = @import("common.zig");

const Args = struct {
    path: []const u8,
    oldText: []const u8,
    newText: []const u8,
};

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) common.Result {
    return .{
        .text = std.fmt.allocPrint(a, fmt, args) catch "edit failed",
        .is_error = true,
    };
}

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: common.Context) common.Result {
    const args = std.json.parseFromSliceLeaky(Args, scratch, args_json, .{ .ignore_unknown_fields = true }) catch {
        return fail(a, "edit failed: path, oldText and newText must be strings", .{});
    };
    const path = args.path;

    if (args.oldText.len == 0) {
        if (util.fileExists(path)) return fail(a, "edit failed: {s} already exists", .{path});
        if (ctx.cancel.load(.acquire)) return fail(a, "edit cancelled", .{});
        writeFile(path, args.newText) catch |e| return fail(a, "edit failed: {s}: {s}", .{ path, @errorName(e) });
        const cleaned = util.utf8Clean(scratch, args.newText) catch return fail(a, "edit failed: out of memory", .{});
        const patch = diff.unified(scratch, path, "", cleaned) catch return fail(a, "edit failed: out of memory", .{});
        return .{
            .text = std.fmt.allocPrint(a, "created {s}\n{s}", .{ path, patch }) catch "created",
            .is_error = false,
        };
    }

    const before = util.readFileAlloc(scratch, path, 1 << 30) catch |e| {
        return fail(a, "edit failed: {s}: {s}", .{ path, @errorName(e) });
    };
    const at = std.mem.indexOf(u8, before, args.oldText) orelse
        return fail(a, "edit failed: oldText not found in {s}", .{path});
    var count: usize = 1;
    var search = at + args.oldText.len;
    while (std.mem.indexOfPos(u8, before, search, args.oldText)) |next| {
        count += 1;
        search = next + args.oldText.len;
    }
    if (count > 1) return fail(a, "edit failed: oldText matches {d} times in {s}", .{ count, path });

    const after = std.mem.concat(scratch, u8, &.{ before[0..at], args.newText, before[at + args.oldText.len ..] }) catch
        return fail(a, "edit failed: out of memory", .{});
    if (ctx.cancel.load(.acquire)) return fail(a, "edit cancelled", .{});
    writeFile(path, after) catch |e| return fail(a, "edit failed: {s}: {s}", .{ path, @errorName(e) });
    const clean_before = util.utf8Clean(scratch, before) catch return fail(a, "edit failed: out of memory", .{});
    const clean_after = util.utf8Clean(scratch, after) catch return fail(a, "edit failed: out of memory", .{});
    const patch = diff.unified(scratch, path, clean_before, clean_after) catch return fail(a, "edit failed: out of memory", .{});
    return .{
        .text = std.fmt.allocPrint(a, "edited {s}\n{s}", .{ path, patch }) catch "edited",
        .is_error = false,
    };
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(platform.io, path, .{ .truncate = true });
    defer file.close(platform.io);
    try file.writeStreamingAll(platform.io, data);
}
