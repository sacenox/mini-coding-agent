const std = @import("std");

pub const Raw = struct {
    bytes: []const u8 = "",

    pub fn jsonStringify(self: Raw, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.bytes);
        jws.endWriteRaw();
    }
};

/// A non-empty string field, or null when the key is missing or holds another type.
pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}
