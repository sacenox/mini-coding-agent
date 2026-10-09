const std = @import("std");
const filesystem = @import("../filesystem.zig");
const text = @import("../text.zig");
const platform = @import("../platform.zig");
const diff = @import("../diff.zig");
const tools = @import("../tools.zig");

const Args = struct {
    path: []const u8,
    oldText: []const u8,
    newText: []const u8,
};

const description =
    "Edit a file by replacing exact text.\n\n" ++
    "`oldText` must match the file byte-for-byte and occur exactly once; include surrounding lines to make " ++
    "it unique. `newText` replaces it. If `oldText` is missing or matches more than once, the edit fails " ++
    "without changing anything.\n\n" ++
    "To create a new file, pass an empty `oldText`; this fails if the file already exists. The result " ++
    "includes a unified diff of the change.";

const params = [_]tools.Param{
    .{ .name = "path", .kind = .string, .description = "File to edit, or to create when `oldText` is empty." },
    .{ .name = "oldText", .kind = .string, .description = "Exact text to replace. Must occur exactly once. Leave empty to create a new file." },
    .{ .name = "newText", .kind = .string, .description = "Replacement text." },
};

fn describe(_: std.mem.Allocator, _: tools.Describe) []const u8 {
    return description;
}

pub const tool = tools.Descriptor{
    .name = .edit,
    .description = describe,
    .params = &params,
    .run = run,
};

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) tools.Result {
    return tools.fail(a, "edit failed", fmt, args);
}

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: tools.Context) tools.Result {
    const args = std.json.parseFromSliceLeaky(Args, scratch, args_json, .{ .ignore_unknown_fields = true }) catch {
        return fail(a, "edit failed: path, oldText and newText must be strings", .{});
    };
    const path = args.path;

    if (args.oldText.len == 0) {
        if (filesystem.fileExists(path)) return fail(a, "edit failed: {s} already exists", .{path});
        if (ctx.cancel.load(.acquire)) return fail(a, "edit cancelled", .{});
        writeFile(path, args.newText) catch |e| return fail(a, "edit failed: {s}: {s}", .{ path, @errorName(e) });
        const cleaned = text.utf8Clean(scratch, args.newText) catch return fail(a, "edit failed: out of memory", .{});
        const patch = diff.unified(scratch, "", cleaned) catch return fail(a, "edit failed: out of memory", .{});
        return .{
            .text = std.fmt.allocPrint(a, "created {s}\n{s}", .{ path, patch }) catch "created",
            .is_error = false,
        };
    }

    const before = filesystem.readFileAlloc(scratch, path, 1 << 30) catch |e| {
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
    const clean_before = text.utf8Clean(scratch, before) catch return fail(a, "edit failed: out of memory", .{});
    const clean_after = text.utf8Clean(scratch, after) catch return fail(a, "edit failed: out of memory", .{});
    const patch = diff.unified(scratch, clean_before, clean_after) catch return fail(a, "edit failed: out of memory", .{});
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
