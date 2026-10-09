const std = @import("std");

pub const Raw = struct {
    bytes: []const u8 = "",

    pub fn jsonStringify(self: Raw, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.bytes);
        jws.endWriteRaw();
    }
};
