const std = @import("std");
const filesystem = @import("../filesystem.zig");
const text = @import("../text.zig");
const message_mod = @import("../message.zig");
const tools = @import("../tools.zig");

const Args = struct {
    path: []const u8,
    offset: ?usize = null,
    range: ?usize = null,
};

const description_base =
    "Read a file and return its text.\n\n" ++
    "Relative paths resolve against the working directory. Prefer this over cat, head, or sed. The whole " ++
    "file is returned by default; pass `offset` (the 1-based first line) and/or `range` (the number of " ++
    "lines) to read part of it.";

const text_description = description_base ++
    "\n\nText longer than 100,000 characters is truncated, and binary files are rejected; use bash to read those.";

const image_description = description_base ++
    "\n\nImages (png, jpg, jpeg, webp) are returned as image content. Text longer than 100,000 characters is " ++
    "truncated.";

const params = [_]tools.Param{
    .{ .name = "path", .kind = .string, .description = "File to read. Relative paths resolve against the working directory." },
    .{ .name = "offset", .kind = .integer, .required = false, .description = "First line to return, 1-based. Defaults to the beginning of the file." },
    .{ .name = "range", .kind = .integer, .required = false, .description = "Number of lines to return from `offset`. Defaults to the end of the file." },
};

fn describe(_: std.mem.Allocator, ctx: tools.Describe) []const u8 {
    return if (ctx.with_images) image_description else text_description;
}

pub const tool = tools.Descriptor{
    .name = .read,
    .description = describe,
    .params = &params,
    .run = run,
};

const image_mime = [_]struct { ext: []const u8, mime: []const u8 }{
    .{ .ext = ".png", .mime = "image/png" },
    .{ .ext = ".jpg", .mime = "image/jpeg" },
    .{ .ext = ".jpeg", .mime = "image/jpeg" },
    .{ .ext = ".webp", .mime = "image/webp" },
};

const max_text_chars = 100_000;
const max_image_base64_bytes = 5 * 1024 * 1024;

fn fail(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) tools.Result {
    return tools.fail(a, "read failed", fmt, args);
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

pub fn run(a: std.mem.Allocator, scratch: std.mem.Allocator, args_json: []const u8, ctx: tools.Context) tools.Result {
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
        const images = a.alloc(message_mod.ImageContent, 1) catch return .{ .text = summary, .is_error = false };
        images[0] = .{ .data = b64, .mime_type = mime };
        return .{
            .text = summary,
            .is_error = false,
            .images = images,
            .body = std.fmt.allocPrint(a, "{s}, {d} bytes", .{ mime, data.len }) catch null,
        };
    }

    if (text.isBinary(data)) {
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
