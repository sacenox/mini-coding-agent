const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");

pub const OutputFn = struct {
    ctx: *anyopaque,
    on_chunk: *const fn (ctx: *anyopaque, chunk: []const u8) void,

    pub fn call(self: OutputFn, chunk: []const u8) void {
        self.on_chunk(self.ctx, chunk);
    }
};

pub const ToolPhase = enum { snapshotting, running };

pub const PhaseFn = struct {
    ctx: *anyopaque,
    on_phase: *const fn (ctx: *anyopaque, phase: ToolPhase) void,

    pub fn call(self: PhaseFn, phase: ToolPhase) void {
        self.on_phase(self.ctx, phase);
    }
};

pub const Context = struct {
    cancel: *const std.atomic.Value(bool),
    supports_images: bool,
    tools: []const config.ToolName = &.{},
    on_output: ?OutputFn = null,
    on_phase: ?PhaseFn = null,
    snapshot_ignore_dirs: []const []const u8 = &.{},
    snapshot_uses_gitignore: bool = true,
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

pub fn fail(a: std.mem.Allocator, fallback: []const u8, comptime fmt: []const u8, args: anytype) Result {
    return .{
        .text = std.fmt.allocPrint(a, fmt, args) catch fallback,
        .is_error = true,
    };
}
