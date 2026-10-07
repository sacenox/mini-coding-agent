const std = @import("std");
const filesystem = @import("../filesystem.zig");
const text = @import("../text.zig");
const types = @import("../types.zig");
const common = @import("common.zig");

const Args = struct {
    path: []const u8,
    offset: ?usize = null,
    range: ?usize = null,
};

const image_mime = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".webp", .mime = "image/webp" },
};

const max_text_chars = 100_000;
const max_image_base64_bytes = 5 * 1024 * 1024;

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) common.Result {
    return common.fail(a, "read failed", fmt, args);
}

fn mimeFor(path: []const u8) ?[]const u8 {
    const ext = std.fs.path.extension(path);
    for (image_mime) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.mime;
    }
    return null;
}

fn advance(content: []const u8, pos: usize, n: usize) ?usize {
    var p = pos;
    var left = n;
    while (left > 0) : (left -= 1) {
        const nl = std.mem.indexOfScalarPos(u8, content, p, '\n') orelse return null;
        p = nl + 1;
    }
    return p;
}

fn lineSlice(content: []const u8, offset: usize, range: ?usize) ?[]const u8 {
    const start = advance(content, 0, offset - 1) orelse return null;
    if (offset > 1 and start >= content.len) return null;
    if (range) |r| if (advance(content, start, r)) |end| return content[start..end];
    return content[start..];
}

fn countLines(content: []const u8) usize {
    if (content.len == 0) return 0;
    return std.mem.count(u8, content, "\n") + @intFromBool(content[content.len - 1] != '\n');
}

fn bodyLine(a: std.mem.Allocator, args: Args, lines: usize, truncated: bool) ?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var window = false;
    if (args.offset) |o| {
        w.print("offset {d}", .{o}) catch return null;
        window = true;
    }
    if (args.range) |r| {
        if (window) w.writeAll(", ") catch return null;
        w.print("range {d}", .{r}) catch return null;
        window = true;
    }
    if (window) w.writeAll(" · ") catch return null;
    if (lines == 1) w.writeAll("1 line") catch return null else w.print("{d} lines", .{lines}) catch return null;
    if (truncated) w.writeAll(", truncated") catch return null;
    return out.written();
}

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: common.Context) common.Result {
    const args = std.json.parseFromSliceLeaky(Args, scratch, args_json, .{ .ignore_unknown_fields = true }) catch
        return fail(a, "read failed: invalid arguments", .{});
    const path = args.path;
    if (args.offset) |o| if (o < 1) return fail(a, "read failed: offset must be at least 1", .{});
    if (args.range) |r| if (r < 1) return fail(a, "read failed: range must be at least 1", .{});

    const data = filesystem.readFileAlloc(a, path, 1 << 30) catch |e|
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
        return .{
            .text = summary,
            .is_error = false,
            .images = images,
            .body = std.fmt.allocPrint(a, "{s}, {d} bytes", .{ mime, data.len }) catch null,
        };
    }

    const head = data[0..@min(data.len, 8000)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) {
        return fail(a, "read failed: {s} is binary; use bash (file, xxd)", .{path});
    }

    const content = text.utf8Clean(a, data) catch return fail(a, "read failed: out of memory", .{});
    const offset = args.offset orelse 1;
    const slice = lineSlice(content, offset, args.range) orelse
        return fail(a, "read failed: {s} has fewer than {d} lines", .{ path, offset });

    var sent = slice;
    if (slice.len > max_text_chars) {
        var cut: usize = max_text_chars;
        while (cut > 0 and slice[cut] & 0xC0 == 0x80) cut -= 1;
        sent = slice[0..cut];
    }
    const truncated = sent.len < slice.len;
    const result_text = if (truncated)
        std.fmt.allocPrint(a, "{s}\n\n... truncated ... {s} is {d} characters\n", .{ sent, path, slice.len }) catch "read failed"
    else
        sent;
    return .{ .text = result_text, .is_error = false, .body = bodyLine(a, args, countLines(sent), truncated) };
}
