const std = @import("std");
const message_mod = @import("../message.zig");

const placeholder_cp: u21 = 0x10EEEE;
const chunk_size = 4096;
const header_b64_bytes = 32;
const header_bytes = 24;
const max_placeholder_rows = 255;
const placeholder_id_mask = 0xFF_FFFF;

/// Kitty row/column diacritics, indexed by value (rowcolumn-diacritics.txt).
const diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
    0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
    0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
    0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
    0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
    0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
    0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
    0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
    0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
    0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
    0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
    0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
    0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
    0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
    0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
    0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
    0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
    0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
    0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
    0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
    0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
    0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
    0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
    0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
    0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
    0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
    0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
    0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
    0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
    0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
};

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

/// Width and height from the PNG IHDR chunk, decoding only the header.
fn pngSize(data: []const u8) ?struct { w: u32, h: u32 } {
    if (data.len < header_b64_bytes) return null;
    var head: [header_bytes]u8 = undefined;
    std.base64.standard.Decoder.decode(&head, data[0..header_b64_bytes]) catch return null;
    if (!std.mem.eql(u8, head[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, head[12..16], "IHDR")) return null;
    const w = be32(head[16..20]);
    const h = be32(head[20..24]);
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

/// A stable, unique-enough image id whose low 24 bits address the placeholder
/// foreground color. `salt` varies per commit, `seq` per image.
pub fn imageId(salt: u8, seq: u32) u32 {
    return (@as(u32, salt) << 16) | (seq & 0xFFFF);
}

fn writeCp(w: *std.Io.Writer, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try w.writeAll(buf[0..n]);
}

/// Transmit the base64 PNG payload to the terminal in `chunk_size` byte chunks.
/// `chunk_size` is a multiple of 4 so every chunk is valid base64.
fn transmit(w: *std.Io.Writer, id: u32, data: []const u8) !void {
    var off: usize = 0;
    var first = true;
    while (off < data.len) {
        const end = @min(off + chunk_size, data.len);
        const more = end < data.len;
        if (first) {
            try w.print("\x1b_Ga=t,f=100,i={d},q=2", .{id});
            first = false;
            if (more) try w.writeAll(",m=1");
        } else if (more) {
            try w.writeAll("\x1b_Gm=1");
        } else {
            try w.writeAll("\x1b_G");
        }
        try w.writeAll(";");
        try w.writeAll(data[off..end]);
        try w.writeAll("\x1b\\");
        off = end;
    }
}

/// Transmit the PNG, place it virtually, and lay out the Unicode placeholder
/// grid that displays it: `cols` x `rows` cells, each row tagged with its index.
fn emit(w: *std.Io.Writer, id: u32, cols: usize, rows: usize, data: []const u8) !void {
    try transmit(w, id, data);
    try w.print("\x1b_Ga=p,U=1,i={d},c={d},r={d},q=2\x1b\\", .{ id, cols, rows });
    const r: u8 = @intCast((id >> 16) & 0xFF);
    const g: u8 = @intCast((id >> 8) & 0xFF);
    const b: u8 = @intCast(id & 0xFF);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        try w.print("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            try writeCp(w, placeholder_cp);
            // The first cell of each row carries the row; the rest inherit.
            if (col == 0) try writeCp(w, diacritics[row]);
        }
        try w.writeAll("\x1b[39m\r\n");
    }
}

/// Build the kitty graphics sequence that transmits a PNG, creates a virtual
/// placement for it, and lays out the Unicode placeholder grid that displays it.
/// Sized to fit `avail_cols` columns and at most `max_rows` rows. Returns null
/// when the image is not a PNG whose size can be read.
pub fn block(a: std.mem.Allocator, id: u32, image: message_mod.ImageContent, avail_cols: usize, max_rows: usize, cell_w: usize, cell_h: usize) ?[]const u8 {
    if (!std.mem.eql(u8, image.mime_type, "image/png")) return null;
    const size = pngSize(image.data) orelse return null;
    if (avail_cols == 0 or max_rows == 0 or cell_w == 0 or cell_h == 0) return null;
    const img_w: f64 = @floatFromInt(size.w);
    const img_h: f64 = @floatFromInt(size.h);
    const fit_w: f64 = @floatFromInt(avail_cols * cell_w);
    const row_cap = @min(max_rows, max_placeholder_rows);
    const fit_h: f64 = @floatFromInt(row_cap * cell_h);
    const scale = @min(@min(fit_w / img_w, fit_h / img_h), 1);
    const cols: usize = @min(@max(1, @as(usize, @intFromFloat(@round(img_w * scale / @as(f64, @floatFromInt(cell_w)))))), avail_cols);
    const rows: usize = @min(@max(1, @as(usize, @intFromFloat(@round(img_h * scale / @as(f64, @floatFromInt(cell_h)))))), row_cap);

    var out: std.Io.Writer.Allocating = .init(a);
    emit(&out.writer, id & placeholder_id_mask, cols, rows, image.data) catch {
        out.deinit();
        return null;
    };
    return out.written();
}
