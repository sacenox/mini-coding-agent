const std = @import("std");
const types = @import("../types.zig");

pub const OutputFn = struct {
    ctx: *anyopaque,
    on_chunk: *const fn (ctx: *anyopaque, chunk: []const u8) void,

    pub fn call(self: OutputFn, chunk: []const u8) void {
        self.on_chunk(self.ctx, chunk);
    }
};

pub const Context = struct {
    cancel: *const std.atomic.Value(bool),
    supports_images: bool,
    on_output: ?OutputFn = null,
    snapshot_ignore_dirs: []const []const u8 = &.{},
    snapshot_uses_gitignore: bool = false,
};

pub const FileDiff = struct {
    path: []const u8,
    patch: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Result = struct {
    text: []const u8,
    is_error: bool,
    images: []const types.ImageContent = &.{},
    diffs: []const FileDiff = &.{},
    body: ?[]const u8 = null,
};
