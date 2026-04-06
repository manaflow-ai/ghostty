const std = @import("std");

/// Encode committed text input for terminal delivery.
///
/// This differs from paste encoding:
/// - no bracketed paste wrappers
/// - no control-byte stripping
/// - `\n` is normalized to `\r` to match Enter key semantics
pub fn encode(
    data: anytype,
) switch (@TypeOf(data)) {
    []u8 => []const u8,
    []const u8 => Error![]const u8,
    else => unreachable,
} {
    const mutable = @TypeOf(data) == []u8;

    if (comptime mutable) {
        std.mem.replaceScalar(u8, data, '\n', '\r');
        return data;
    }

    if (std.mem.indexOfScalar(u8, data, '\n') != null) {
        return Error.MutableRequired;
    }

    return data;
}

pub const Error = error{
    MutableRequired,
};

test "encode committed text without newlines" {
    const testing = std.testing;
    const result = try encode(@as([]const u8, "hello"));
    try testing.expectEqualStrings("hello", result);
}

test "encode committed text with newline const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\nworld"),
    ));
}

test "encode committed text with newline mutable" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(data);
    const result = encode(data);
    try testing.expectEqualStrings("hello\rworld", result);
}
