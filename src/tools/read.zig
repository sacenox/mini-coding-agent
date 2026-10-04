//! The `read` tool: returns a file's text, or the image itself for a png, jpg,
//! or webp when the model accepts image input.

const std = @import("std");
const util = @import("../util.zig");
const types = @import("../types.zig");
const common = @import("common.zig");

const Args = struct { path: []const u8 };

const image_mime = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".webp", .mime = "image/webp" },
};

const max_text_chars = 100_000;
/// Cap on the base64 payload sent to the provider, where the file inflates by 4/3.
const max_image_base64_bytes = 5 * 1024 * 1024;

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) common.Result {
    return .{
        .text = std.fmt.allocPrint(a, fmt, args) catch "read failed",
        .is_error = true,
    };
}

fn mimeFor(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    for (image_mime) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return null;
}

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: common.Context) common.Result {
    const args = std.json.parseFromSliceLeaky(Args, scratch, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(a, "read failed: invalid arguments", .{});
    const path = args.path;

    const data = util.readFileAlloc(a, path, 1 << 30) catch |e|
        return fail(a, "read failed: {s}: {s}", .{ path, @errorName(e) });

    if (mimeFor(path)) |mime| {
        if (!ctx.supports_images) {
            return fail(a, "read failed: {s} is an image and the current model does not accept image input", .{path});
        }
        const encoded = std.base64.standard.Encoder.calcSize(data.len);
        if (encoded > max_image_base64_bytes) {
            return fail(a, "read failed: {s} encodes to {d} bytes, over the {d} byte image limit", .{ path, encoded, max_image_base64_bytes });
        }
        const b64 = a.alloc(u8, encoded) catch return fail(a, "read failed: out of memory", .{});
        _ = std.base64.standard.Encoder.encode(b64, data);
        const summary = std.fmt.allocPrint(a, "read {s} ({s}, {d} bytes)", .{ path, mime, data.len }) catch "read";
        const images = a.alloc(types.ImageContent, 1) catch return .{ .text = summary, .is_error = false };
        images[0] = .{ .data = b64, .mime_type = mime };
        return .{ .text = summary, .is_error = false, .images = images };
    }

    const head = data[0..@min(data.len, 8000)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) {
        return fail(a, "read failed: {s} is binary; use bash (file, xxd)", .{path});
    }

    const text = util.utf8Clean(a, data) catch return fail(a, "read failed: out of memory", .{});
    if (text.len > max_text_chars) {
        // Cut back to a code point boundary so the truncation never splits a
        // sequence and hands the provider bytes that are not valid UTF-8.
        var cut: usize = max_text_chars;
        while (cut > 0 and text[cut] & 0xC0 == 0x80) cut -= 1;
        const truncated = std.fmt.allocPrint(a, "{s}\n\n... truncated ... {s} is {d} characters\n", .{ text[0..cut], path, text.len }) catch "read failed";
        return .{ .text = truncated, .is_error = false };
    }
    return .{ .text = text, .is_error = false };
}
