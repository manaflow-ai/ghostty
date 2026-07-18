//! Normalization for terminal links split by prose hard-wrapping.
//!
//! Formatters commonly break long URLs and paths after punctuation, emit a
//! real newline, and indent the continuation. Link regexes need a contiguous
//! string, while hover rendering still needs each retained byte mapped back
//! to its original terminal cell.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Add a non-link delimiter after a joined candidate. This prevents path
    /// regexes from treating sentence punctuation as a valid end-of-string
    /// path character. The delimiter is for matching only, never opening.
    terminate_joined: bool = false,
};

pub fn Normalized(comptime MapItem: type) type {
    return struct {
        string: [:0]const u8,
        map: []MapItem,

        pub fn deinit(self: @This(), alloc: Allocator) void {
            alloc.free(self.string);
            alloc.free(self.map);
        }
    };
}

/// Remove recognized hard-wrap boundaries while preserving a byte-for-byte
/// coordinate map. A boundary must have indentation and follow punctuation
/// that prose formatters commonly choose as a link break point. This avoids
/// joining unrelated adjacent output lines.
pub fn normalize(
    comptime MapItem: type,
    alloc: Allocator,
    input: []const u8,
    input_map: []const MapItem,
    options: Options,
) Allocator.Error!Normalized(MapItem) {
    std.debug.assert(input.len == input_map.len);

    var string: std.ArrayList(u8) = .empty;
    defer string.deinit(alloc);
    try string.ensureTotalCapacity(alloc, input.len);

    var map: std.ArrayList(MapItem) = .empty;
    defer map.deinit(alloc);
    try map.ensureTotalCapacity(alloc, input_map.len);

    var i: usize = 0;
    var joined = false;
    while (i < input.len) {
        if (input[i] == '\n') {
            var boundary = string.items.len;
            if (boundary > 0 and string.items[boundary - 1] == '\r') {
                boundary -= 1;
            }
            while (boundary > 0 and string.items[boundary - 1] == 0) {
                boundary -= 1;
            }

            var next = i + 1;
            while (next < input.len and
                (input[next] == ' ' or input[next] == '\t'))
            {
                next += 1;
            }

            if (next > i + 1 and
                boundary > 0 and
                next < input.len and
                isBreakPunctuation(string.items[boundary - 1]) and
                isLinkByte(input[next]))
            {
                string.shrinkRetainingCapacity(boundary);
                map.shrinkRetainingCapacity(boundary);
                joined = true;
                i = next;
                continue;
            }
        }

        try string.append(alloc, input[i]);
        try map.append(alloc, input_map[i]);
        i += 1;
    }

    if (joined and options.terminate_joined) {
        try string.append(alloc, 0);
        try map.append(alloc, input_map[input_map.len - 1]);
    }

    const owned_string = try string.toOwnedSliceSentinel(alloc, 0);
    errdefer alloc.free(owned_string);
    return .{
        .string = owned_string,
        .map = try map.toOwnedSlice(alloc),
    };
}

fn isBreakPunctuation(byte: u8) bool {
    return switch (byte) {
        '-', '_', '.', '/', '?', '#', '&', '=', '%' => true,
        else => false,
    };
}

fn isLinkByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z',
        'A'...'Z',
        '0'...'9',
        '-',
        '_',
        '.',
        '~',
        ':',
        '/',
        '?',
        '#',
        '@',
        '!',
        '$',
        '&',
        '*',
        '+',
        ';',
        '=',
        '%',
        => true,
        else => false,
    };
}

test "normalize joins indented link continuation and preserves mapped cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "/tmp/build-\n    warm.app.";
    var input_map: [input.len]usize = undefined;
    for (&input_map, 0..) |*item, index| item.* = index;

    const normalized = try normalize(usize, alloc, input, &input_map, .{});
    defer normalized.deinit(alloc);

    try testing.expectEqualStrings("/tmp/build-warm.app.", normalized.string);
    try testing.expectEqual(input.len - 5, normalized.map.len);
    try testing.expectEqual(@as(usize, 10), normalized.map[10]);
    try testing.expectEqual(@as(usize, 16), normalized.map[11]);
}

test "normalize joins a CRLF link continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "/tmp/build-\r\n    warm.app";
    var input_map: [input.len]usize = undefined;
    for (&input_map, 0..) |*item, index| item.* = index;

    const normalized = try normalize(usize, alloc, input, &input_map, .{});
    defer normalized.deinit(alloc);

    try testing.expectEqualStrings("/tmp/build-warm.app", normalized.string);
}

test "normalize does not join unindented or unpunctuated lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        "/tmp/build-\nwarm.app",
        "/tmp/build\n    warm.app",
    }) |input| {
        const input_map = try alloc.alloc(usize, input.len);
        defer alloc.free(input_map);
        for (input_map, 0..) |*item, index| item.* = index;

        const normalized = try normalize(usize, alloc, input, input_map, .{});
        defer normalized.deinit(alloc);
        try testing.expectEqualStrings(input, normalized.string);
    }
}
