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
    /// path character. The delimiter is for matching only and has no terminal
    /// cell mapping.
    terminate_joined: bool = false,
};

pub fn Normalized(comptime MapItem: type) type {
    return struct {
        /// Bytes available to regex matching. This may contain one synthetic
        /// terminator immediately after `mapped_len`.
        string: [:0]const u8,

        /// Number of leading string bytes that came from terminal cells.
        /// `map.len` is always equal to this value.
        mapped_len: usize,

        /// Terminal cell mapping for `string[0..mapped_len]`. Synthetic match
        /// bytes intentionally have no mapped cell.
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

            if (boundary > 0 and next < input.len) {
                const before = string.items[boundary - 1];
                const indentation = next - (i + 1);
                if (continuationKind(
                    before,
                    indentation,
                    input[next],
                )) |kind| {
                    if (!startsIndependentLink(
                        input[next..],
                        before,
                        kind,
                    )) {
                        string.shrinkRetainingCapacity(boundary);
                        map.shrinkRetainingCapacity(boundary);
                        joined = true;
                        i = next;
                        continue;
                    }
                }
            }
        }

        try string.append(alloc, input[i]);
        try map.append(alloc, input_map[i]);
        i += 1;
    }

    if (joined and options.terminate_joined) {
        try string.append(alloc, 0);
    }

    const owned_string = try string.toOwnedSliceSentinel(alloc, 0);
    errdefer alloc.free(owned_string);
    const owned_map = try map.toOwnedSlice(alloc);
    return .{
        .string = owned_string,
        .mapped_len = owned_map.len,
        .map = owned_map,
    };
}

fn isBreakPunctuation(byte: u8) bool {
    return switch (byte) {
        // A period is deliberately excluded. At a real newline it is much
        // stronger evidence of a completed sentence than a continued token.
        // The remaining bytes are common break opportunities inside URLs and
        // paths without also being ordinary sentence terminators.
        '-', '_', '/', '?', '#', '&', '=', '%' => true,
        else => false,
    };
}

pub const max_continuation_indentation = 16;

pub const ContinuationKind = enum {
    unindented,
    indented,
};

/// Return whether the first token should own its row instead of continuing
/// the preceding token. Explicit roots and schemes always qualify. A bare
/// relative path qualifies only at an indented boundary after `/`, where the
/// indentation is evidence that the formatter may have started a nested list
/// item rather than continued one unbroken token.
pub fn startsIndependentLink(
    input: []const u8,
    before: u21,
    continuation: ContinuationKind,
) bool {
    if (input.len == 0) return false;
    if (input[0] == '/') return true;
    if (std.mem.startsWith(u8, input, "./") or
        std.mem.startsWith(u8, input, "../") or
        std.mem.startsWith(u8, input, "~/")) return true;

    if (input[0] == '$' and input.len > 2 and isAsciiWordStart(input[1])) {
        var index: usize = 2;
        while (index < input.len and isAsciiWord(input[index])) : (index += 1) {}
        if (index < input.len and input[index] == '/') return true;
    }

    // RFC 3986 scheme prefix. This covers Ghostty's built-in schemes without
    // duplicating their list here, and treats other valid schemes safely.
    if (std.ascii.isAlphabetic(input[0])) {
        var index: usize = 1;
        while (index < input.len and isSchemeByte(input[index])) : (index += 1) {}
        if (index < input.len and input[index] == ':') return true;
    }

    // A hidden relative path has an explicit root-like marker. A plain bare
    // relative path is only treated as independent after `/`: in that case
    // both rows are complete path-shaped tokens, so joining would silently
    // turn adjacent list items into a different target. This deliberately
    // fails closed for the ambiguous case of a real wrap after `/`.
    var index: usize = if (input[0] == '.' and
        input.len > 1 and isWordByte(input[1]))
        2
    else if (continuation == .indented and
        before == '/' and
        isWordByte(input[0]))
        1
    else
        return false;
    while (index < input.len and isBareSegmentByte(input[index])) : (index += 1) {}
    return index < input.len and input[index] == '/';
}

fn isAsciiWordStart(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isAsciiWord(byte: u8) bool {
    return isAsciiWordStart(byte);
}

fn isWordByte(byte: u8) bool {
    return isAsciiWord(byte) or byte >= 0x80;
}

fn isSchemeByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.';
}

fn isBareSegmentByte(byte: u8) bool {
    return isWordByte(byte) or byte == '-' or byte == '.';
}

/// Classify whether two terminal rows form a recognized prose hard-wrap
/// boundary. Keeping this classifier shared with grid expansion prevents the
/// selected candidate and normalized bytes from disagreeing. Indentation is
/// common but not required: terminal UIs also hard-wrap an unbroken token at a
/// punctuation boundary without adding continuation padding.
pub fn continuationKind(
    before: u21,
    indentation: usize,
    after: u21,
) ?ContinuationKind {
    if (indentation > max_continuation_indentation or
        before > std.math.maxInt(u8)) return null;
    if (!isBreakPunctuation(@intCast(before))) return null;
    if (after <= std.math.maxInt(u8) and
        !isLinkByte(@intCast(after))) return null;
    return if (indentation == 0) .unindented else .indented;
}

fn isLinkByte(byte: u8) bool {
    // Any non-ASCII byte can be part of a UTF-8 codepoint matched by `\w` in
    // the default URL expressions. Validation remains the regex's job.
    if (byte >= 0x80) return true;

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
        ',',
        ';',
        '=',
        '%',
        '(',
        ')',
        '[',
        ']',
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

test "normalize joins unindented continuation but not unpunctuated lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const joined = "/tmp/build-\nwarm.app";
    var joined_map: [joined.len]usize = undefined;
    for (&joined_map, 0..) |*item, index| item.* = index;
    const normalized_joined = try normalize(
        usize,
        alloc,
        joined,
        &joined_map,
        .{},
    );
    defer normalized_joined.deinit(alloc);
    try testing.expectEqualStrings("/tmp/build-warm.app", normalized_joined.string);

    const separate = "/tmp/build\n    warm.app";
    var separate_map: [separate.len]usize = undefined;
    for (&separate_map, 0..) |*item, index| item.* = index;
    const normalized_separate = try normalize(
        usize,
        alloc,
        separate,
        &separate_map,
        .{},
    );
    defer normalized_separate.deinit(alloc);
    try testing.expectEqualStrings(separate, normalized_separate.string);
}

test "startsIndependentLink recognizes independent URL and path prefixes" {
    const testing = std.testing;

    for ([_][]const u8{
        "/tmp/foo",
        "./foo",
        "../foo",
        "~/foo",
        "$HOME/foo",
        "https://example.com",
        "file:///tmp/foo",
    }) |input| try testing.expect(startsIndependentLink(
        input,
        '-',
        .indented,
    ));

    try testing.expect(startsIndependentLink(".config/foo", '-', .indented));
    try testing.expect(startsIndependentLink("src/foo", '/', .indented));
    try testing.expect(startsIndependentLink("日本語/foo", '/', .indented));

    for ([_][]const u8{
        "20260716-warm.app",
        "012345",
        "(video_game)",
        "日本語",
        "continuation",
    }) |input| try testing.expect(!startsIndependentLink(
        input,
        '-',
        .indented,
    ));

    try testing.expect(!startsIndependentLink("src/foo", '-', .indented));
    try testing.expect(!startsIndependentLink("src/foo", '/', .unindented));
}

test "normalize keeps adjacent independent links separate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    for ([_][]const u8{
        "/tmp/foo/\n    /tmp/bar",
        "https://example.com/path-\n    https://example.org",
        "src/foo/\n    other/bar.zig",
    }) |input| {
        const input_map = try alloc.alloc(usize, input.len);
        defer alloc.free(input_map);
        for (input_map, 0..) |*item, index| item.* = index;

        const normalized = try normalize(usize, alloc, input, input_map, .{});
        defer normalized.deinit(alloc);
        try testing.expectEqualStrings(input, normalized.string);
        try testing.expectEqual(input.len, normalized.mapped_len);
    }
}

test "normalize rejects sentence endings and deep indentation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_][]const u8{
        "See https://example.com.\n    /tmp/foo",
        "/tmp/build-\n                 warm.app",
    };
    for (cases) |input| {
        const input_map = try alloc.alloc(usize, input.len);
        defer alloc.free(input_map);
        for (input_map, 0..) |*item, index| item.* = index;

        const normalized = try normalize(
            usize,
            alloc,
            input,
            input_map,
            .{},
        );
        defer normalized.deinit(alloc);

        try testing.expectEqualStrings(input, normalized.string);
        try testing.expectEqual(input.len, normalized.mapped_len);
    }
}

test "normalize accepts every default URL continuation class" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "https://example.com/foo-\n    ,bar",
            .expected = "https://example.com/foo-,bar",
        },
        .{
            .input = "https://example.com/foo#\n    [section]",
            .expected = "https://example.com/foo#[section]",
        },
        .{
            .input = "https://example.com/wiki/\n    日本語",
            .expected = "https://example.com/wiki/日本語",
        },
    };

    for (cases) |case| {
        const input_map = try alloc.alloc(usize, case.input.len);
        defer alloc.free(input_map);
        for (input_map, 0..) |*item, index| item.* = index;

        const normalized = try normalize(
            usize,
            alloc,
            case.input,
            input_map,
            .{},
        );
        defer normalized.deinit(alloc);

        try testing.expectEqualStrings(case.expected, normalized.string);
        try testing.expectEqual(normalized.string.len, normalized.mapped_len);
        try testing.expectEqual(normalized.mapped_len, normalized.map.len);
    }
}

test "normalize match terminator has no terminal cell mapping" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "/tmp/build-\n    warm.app.";
    var input_map: [input.len]usize = undefined;
    for (&input_map, 0..) |*item, index| item.* = index;

    const normalized = try normalize(
        usize,
        alloc,
        input,
        &input_map,
        .{ .terminate_joined = true },
    );
    defer normalized.deinit(alloc);

    const expected = "/tmp/build-warm.app.";
    try testing.expectEqual(expected.len, normalized.mapped_len);
    try testing.expectEqual(normalized.mapped_len, normalized.map.len);
    try testing.expectEqual(normalized.mapped_len + 1, normalized.string.len);
    try testing.expectEqualSlices(
        u8,
        expected ++ "\x00",
        normalized.string,
    );
    try testing.expectEqual(@as(u8, 0), normalized.string[normalized.mapped_len]);
}
