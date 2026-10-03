const std = @import("std");
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");

test "shape Hangul with a composed-only face" {
    try testHangul(font.embedded.hangul_test, false, true, null);
}

test "shape Hangul with jamo coverage and style fallback" {
    for ([_]bool{ true, false }) |complete_styles| {
        try testHangul(font.embedded.hangul_jamo_test, true, complete_styles, null);
    }
}

test "shape Hangul when styles have different jamo coverage" {
    try testHangul(font.embedded.hangul_test, false, true, font.embedded.hangul_jamo_test);
}

test "shape uncomposable Hangul jamo with a composed-only face" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fx = try Fixture.init(alloc, font.embedded.hangul_test, null, true);
    defer fx.deinit(alloc);

    // An archaic vowel has no precomposed syllable, so the cluster keeps the
    // per-jamo path. No face here covers jamo, so it must become the selected
    // face's own replacement glyph and never a foreign glyph ID.
    const input = "\u{1112}\u{1176}";
    try testing.expect(font.hangul.composedSyllable(0x1112, &.{0x1176}) == null);

    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(input);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const cells = state.row_data.get(0).cells.slice();

    var glyphs: usize = 0;
    var it = fx.shaper.runIterator(.{ .grid = &fx.grid, .cells = cells });
    while (try it.next(alloc)) |run| {
        const face = try fx.grid.resolver.collection.getFace(run.font_index);
        const replacement = face.glyphIndex(0xFFFD) orelse
            face.glyphIndex(' ') orelse
            return error.MissingGlyph;
        for (try fx.shaper.shape(run)) |cell| {
            try testing.expectEqual(@as(u16, 0), run.offset + cell.x);
            try testing.expectEqual(replacement, cell.glyph_index);
            glyphs += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), glyphs);
    try expectCopied(alloc, &t, input);
}

/// A font grid and shaper over bundled fixtures, so coverage never depends on
/// the fonts installed on the machine running the tests.
const Fixture = struct {
    lib: font.Library,
    grid: font.SharedGrid,
    shaper: font.Shaper,
    regular: font.Collection.Index,

    fn init(
        alloc: std.mem.Allocator,
        data: [:0]const u8,
        bold_data: ?[:0]const u8,
        complete_styles: bool,
    ) !Fixture {
        var lib = try font.Library.init(alloc);
        errdefer lib.deinit();
        var collection = font.Collection.init();
        collection.load_options = .{ .library = lib };
        const regular = try collection.add(alloc, try font.Face.init(
            lib,
            data,
            .{ .size = .{ .points = 12 } },
        ), .{ .style = .regular, .fallback = false, .size_adjustment = .none });
        if (bold_data) |bytes| {
            _ = try collection.add(alloc, try font.Face.init(
                lib,
                bytes,
                .{ .size = .{ .points = 12 } },
            ), .{ .style = .bold, .fallback = false, .size_adjustment = .none });
        }
        // Without a bold face, bold text must use the resolver's regular fallback.
        if (complete_styles) try collection.completeStyles(alloc, .{});
        var grid = try font.SharedGrid.init(alloc, .{ .collection = collection });
        errdefer grid.deinit(alloc);
        const shaper = try font.Shaper.init(alloc, .{});
        return .{ .lib = lib, .grid = grid, .shaper = shaper, .regular = regular };
    }

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        self.shaper.deinit();
        self.grid.deinit(alloc);
        self.lib.deinit();
    }
};

fn testHangul(
    data: [:0]const u8,
    has_jamo: bool,
    complete_styles: bool,
    bold_data: ?[:0]const u8,
) !void {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fx = try Fixture.init(alloc, data, bold_data, complete_styles);
    defer fx.deinit(alloc);

    // Bundled fixtures make both coverage cases independent of installed fonts.
    for ([_]u32{ 0xBB34, 0xC81C, 0xD55C, 0xBC95 }) |cp| {
        try testing.expect(fx.grid.hasCodepoint(fx.regular, cp, null));
    }
    for ([_]u32{ 0x1106, 0x116E, 0x110C, 0x1166, 0x1112, 0x1161, 0x11AB }) |cp| {
        try testing.expectEqual(has_jamo, fx.grid.hasCodepoint(fx.regular, cp, null));
    }

    const cases = [_]struct { input: []const u8, composed: []const u8 }{
        // The reported filename, surrounded by Latin characters.
        .{ .input = "A\u{1106}\u{116E}\u{110C}\u{1166}.md", .composed = "A무제.md" },
        .{ .input = "A무제.md", .composed = "A무제.md" },
        // L+V+T and the partially composed LV+T form.
        .{ .input = "\u{1112}\u{1161}\u{11AB}\u{1107}\u{1165}\u{11B8}", .composed = "한법" },
        .{ .input = "\u{D558}\u{11AB}\u{BC84}\u{11B8}", .composed = "한법" },
    };
    // Selection bounds split runs too. {1,2} covers one wide syllable of the
    // filename exactly; {2,3} starts on a spacer tail and ends on a wide head,
    // so a run begins on a cell that contributes no codepoint.
    const selections = [_]?[2]u16{ null, .{ 1, 2 }, .{ 2, 3 } };
    for ([_]bool{ false, true }) |bold| {
        for ([_]?usize{ null, 3 }) |cursor_x| {
            for (selections) |selection| {
                for (cases) |case| {
                    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
                    defer t.deinit(alloc);
                    var stream = t.vtStream();
                    defer stream.deinit();
                    if (bold) stream.nextSlice("\x1b[1m");
                    stream.nextSlice(case.input);

                    var state: terminal.RenderState = .empty;
                    defer state.deinit(alloc);
                    try state.update(alloc, &t);
                    const cells = state.row_data.get(0).cells.slice();

                    var expected = (try std.unicode.Utf8View.init(case.composed)).iterator();
                    var expected_x: u16 = 0;
                    var it = fx.shaper.runIterator(.{
                        .grid = &fx.grid,
                        .cells = cells,
                        .selection = selection,
                        .cursor_x = cursor_x,
                    });
                    while (try it.next(alloc)) |run| {
                        try testing.expect(run.font_index.special() == null);
                        try testing.expectEqual(
                            if (bold and complete_styles) font.Style.bold else font.Style.regular,
                            run.font_index.style,
                        );
                        const face = try fx.grid.resolver.collection.getFace(run.font_index);
                        for (try fx.shaper.shape(run)) |cell| {
                            const cp = expected.nextCodepoint() orelse return error.UnexpectedGlyph;
                            const glyph = face.glyphIndex(cp) orelse return error.MissingGlyph;
                            try testing.expectEqual(expected_x, run.offset + cell.x);
                            try testing.expectEqual(glyph, cell.glyph_index);
                            expected_x += if (cp >= 0xAC00 and cp <= 0xD7A3) @as(u16, 2) else 1;
                        }
                    }
                    try testing.expect(expected.nextCodepoint() == null);
                    try testing.expectEqual(expected_x, t.screens.active.cursor.x);

                    // The rendering transform must preserve the stored spelling
                    // used by selection/copy, including decomposed filename bytes.
                    var stored: std.ArrayList(u8) = .empty;
                    defer stored.deinit(alloc);
                    for (cells.items(.raw), cells.items(.grapheme)) |cell, rest| {
                        switch (cell.wide) {
                            .spacer_head, .spacer_tail => continue,
                            else => {},
                        }
                        if (cell.codepoint() == 0) continue;
                        try appendUtf8(alloc, &stored, cell.codepoint());
                        if (cell.hasGrapheme()) {
                            for (rest) |cp| try appendUtf8(alloc, &stored, cp);
                        }
                    }
                    try testing.expectEqualStrings(case.input, stored.items);
                    try expectCopied(alloc, &t, case.input);
                }
            }
        }
    }
}

/// Copying the line through the terminal's own selection path (what a
/// triple-click and copy uses) must return the bytes the program wrote.
fn expectCopied(alloc: std.mem.Allocator, t: *terminal.Terminal, want: []const u8) !void {
    const screen = t.screens.active;
    var sel = screen.selectLine(.{
        .pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
    }) orelse return error.MissingSelection;
    defer sel.deinit(screen);
    const copied = try screen.selectionString(alloc, .{ .sel = sel, .trim = false });
    defer alloc.free(copied);
    try std.testing.expectEqualStrings(want, copied);
}

fn appendUtf8(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u21) !void {
    var bytes: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &bytes);
    try buf.appendSlice(alloc, bytes[0..len]);
}
