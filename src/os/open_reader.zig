const std = @import("std");

pub fn takeLine(reader: *std.Io.Reader, chunk_size: usize) error{ReadFailed}!?[]u8 {
    return reader.takeDelimiter('\n') catch |outer| switch (outer) {
        error.ReadFailed => error.ReadFailed,
        error.StreamTooLong => reader.take(chunk_size) catch |inner| switch (inner) {
            error.ReadFailed => error.ReadFailed,
            error.EndOfStream => null,
        },
    };
}

test "open stderr reader consumes delimiters and reaches EOF" {
    var reader = std.Io.Reader.fixed("first\nsecond\n");

    try std.testing.expectEqualStrings("first", (try takeLine(&reader, 256)).?);
    try std.testing.expectEqualStrings("second", (try takeLine(&reader, 256)).?);
    try std.testing.expectEqual(null, try takeLine(&reader, 256));
}
