const std = @import("std");

const context = 3;
const max_trace_bytes = 64 << 20;

const Line = struct {
    p: []const u8,
    nl: bool,
};

const OpKind = enum { eq, del, ins };
const Op = struct { kind: OpKind, line: Line };

fn splitLines(a: std.mem.Allocator, text: []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        while (i < text.len and text[i] != '\n') i += 1;
        try out.append(a, .{ .p = text[start..i], .nl = i < text.len });
        if (i < text.len) i += 1;
    }
    return out.toOwnedSlice(a);
}

fn lineEq(x: Line, y: Line) bool {
    return x.nl == y.nl and x.p.len == y.p.len and std.mem.eql(u8, x.p, y.p);
}

fn myers(a: std.mem.Allocator, la: []const Line, lb: []const Line) ![]Op {
    const n = la.len;
    const m = lb.len;
    var ops: std.ArrayList(Op) = .empty;
    try ops.ensureTotalCapacity(a, n + m);

    if (n == 0) {
        for (lb) |l| ops.appendAssumeCapacity(.{ .kind = .ins, .line = l });
        return ops.toOwnedSlice(a);
    }
    if (m == 0) {
        for (la) |l| ops.appendAssumeCapacity(.{ .kind = .del, .line = l });
        return ops.toOwnedSlice(a);
    }

    const max: usize = n + m;
    const vsize = 2 * max + 3;
    const offset: i64 = @intCast(max + 1);
    const v = try a.alloc(i64, vsize);
    @memset(v, 0);
    v[@intCast(offset + 1)] = 0;

    var trace: std.ArrayList([]i64) = .empty;
    var trace_bytes: usize = 0;
    var found_d: ?usize = null;

    var d: usize = 0;
    while (d <= max) : (d += 1) {
        if (trace_bytes + vsize * @sizeOf(i64) > max_trace_bytes) break;
        try trace.append(a, try a.dupe(i64, v));
        trace_bytes += vsize * @sizeOf(i64);

        const di: i64 = @intCast(d);
        var k: i64 = -di;
        while (k <= di) : (k += 2) {
            const im: usize = @intCast(offset + k - 1);
            const ip: usize = @intCast(offset + k + 1);
            var x: i64 = if (k == -di or (k != di and v[im] < v[ip]))
                v[ip]
            else
                v[im] + 1;
            var y: i64 = x - k;
            while (x < @as(i64, @intCast(n)) and y < @as(i64, @intCast(m)) and
                lineEq(la[@intCast(x)], lb[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }
            v[@intCast(offset + k)] = x;
            if (x >= @as(i64, @intCast(n)) and y >= @as(i64, @intCast(m))) {
                found_d = d;
                break;
            }
        }
        if (found_d != null) break;
    }

    if (found_d == null) {
        for (la) |l| try ops.append(a, .{ .kind = .del, .line = l });
        for (lb) |l| try ops.append(a, .{ .kind = .ins, .line = l });
        return ops.toOwnedSlice(a);
    }

    var x: i64 = @intCast(n);
    var y: i64 = @intCast(m);
    var dd: i64 = @intCast(found_d.?);
    while (dd >= 0) : (dd -= 1) {
        const vt = trace.items[@intCast(dd)];
        const k = x - y;
        const im: usize = @intCast(offset + k - 1);
        const ip: usize = @intCast(offset + k + 1);
        const prev_k: i64 = if (k == -dd or (k != dd and vt[im] < vt[ip])) k + 1 else k - 1;
        const prev_x = vt[@intCast(offset + prev_k)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            try ops.append(a, .{ .kind = .eq, .line = la[@intCast(x - 1)] });
            x -= 1;
            y -= 1;
        }
        if (dd > 0) {
            if (x == prev_x) {
                try ops.append(a, .{ .kind = .ins, .line = lb[@intCast(y - 1)] });
                y -= 1;
            } else {
                try ops.append(a, .{ .kind = .del, .line = la[@intCast(x - 1)] });
                x -= 1;
            }
        }
    }

    std.mem.reverse(Op, ops.items);
    return ops.toOwnedSlice(a);
}

fn addRange(w: *std.Io.Writer, start: usize, count: usize) !void {
    if (count == 0) {
        try w.print("{d},0", .{start - 1});
    } else {
        try w.print("{d},{d}", .{ start, count });
    }
}

pub fn unified(a: std.mem.Allocator, before: []const u8, after: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();

    const la = try splitLines(tmp, before);
    const lb = try splitLines(tmp, after);
    const ops = try myers(tmp, la, lb);

    const opref = try tmp.alloc(usize, ops.len + 1);
    const npref = try tmp.alloc(usize, ops.len + 1);
    opref[0] = 0;
    npref[0] = 0;
    for (ops, 0..) |op, i| {
        opref[i + 1] = opref[i] + @intFromBool(op.kind != .ins);
        npref[i + 1] = npref[i] + @intFromBool(op.kind != .del);
    }

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;

    var i: usize = 0;
    while (i < ops.len) {
        while (i < ops.len and ops[i].kind == .eq) i += 1;
        if (i >= ops.len) break;
        const block_start = i;
        var last = i;
        while (last < ops.len and ops[last].kind != .eq) last += 1;
        while (true) {
            var g = last;
            while (g < ops.len and ops[g].kind == .eq) g += 1;
            if (g >= ops.len) break;
            if (g - last > 2 * context) break;
            var b2 = g;
            while (b2 < ops.len and ops[b2].kind != .eq) b2 += 1;
            last = b2;
        }
        const hs = if (block_start >= context) block_start - context else 0;
        const he = if (last + context <= ops.len) last + context else ops.len;

        try w.writeAll("@@ -");
        try addRange(w, opref[hs] + 1, opref[he] - opref[hs]);
        try w.writeAll(" +");
        try addRange(w, npref[hs] + 1, npref[he] - npref[hs]);
        try w.writeAll(" @@\n");

        for (ops[hs..he]) |op| {
            const prefix: u8 = switch (op.kind) {
                .del => '-',
                .ins => '+',
                .eq => ' ',
            };
            try w.writeByte(prefix);
            try w.writeAll(op.line.p);
            try w.writeByte('\n');
            if (!op.line.nl) try w.writeAll("\\ No newline at end of file\n");
        }
        i = he;
    }
    return out.written();
}
