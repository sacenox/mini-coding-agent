//! What a tool receives and returns. Tool arguments are untrusted and are
//! validated once, at the boundary, before execution.

const std = @import("std");
const types = @import("../types.zig");

/// Streamed tool output (bash's stdout and stderr), forwarded to the
/// projection that is listening.
pub const OutputFn = struct {
    ctx: *anyopaque,
    on_chunk: *const fn (ctx: *anyopaque, chunk: []const u8) void,

    pub fn call(self: OutputFn, chunk: []const u8) void {
        self.on_chunk(self.ctx, chunk);
    }
};

pub const Context = struct {
    cancel: *const std.atomic.Value(bool),
    /// Whether the current model accepts image input.
    supports_images: bool,
    on_output: ?OutputFn = null,
};

/// One changed file under the working directory, display-only: it never
/// reaches the model. `patch` is a unified diff; it is null when the content
/// cannot be tracked, in which case `note` explains why.
pub const FileDiff = struct {
    path: []const u8,
    patch: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Result = struct {
    text: []const u8,
    is_error: bool,
    /// Image blocks appended to the tool result, after `text`.
    images: []const types.ImageContent = &.{},
    /// Files the tool changed, for display only.
    diffs: []const FileDiff = &.{},
    /// One line that replaces the result body on screen, for display only.
    /// Null shows `text` instead.
    body: ?[]const u8 = null,
};
