//! Terminal-independent inputs used to project a renderer frame.
//!
//! A projection borrows its inputs for the duration of a synchronous
//! projection call. The producer remains responsible for their storage.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const terminal = @import("../terminal/main.zig");

/// The captured terminal data needed to project a frame. This intentionally
/// contains no live terminal parser or renderer synchronization state.
pub const Projection = struct {
    terminal_state: *terminal.RenderState,
    preedit: ?Preedit,
    link_cells: *const terminal.RenderState.CellSet,
    scrollbar: terminal.Scrollbar,
};

/// Mouse state relevant while capturing a projection.
pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminal.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: input.Mods = .{},
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was created with `clone`.
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator.
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminal.size.CellCountInt,
        max: terminal.size.CellCountInt,
    ) struct {
        start: terminal.size.CellCountInt,
        end: terminal.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminal.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminal.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminal.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminal.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminal.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminal.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminal.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}

test "projection reads captured render state without a live terminal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var render_state: terminal.RenderState = .empty;
    defer render_state.deinit(alloc);

    {
        var term = try terminal.Terminal.init(alloc, .{
            .cols = 4,
            .rows = 1,
        });
        defer term.deinit(alloc);

        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice("AB");

        try render_state.update(alloc, &term);
    }

    var links: terminal.RenderState.CellSet = .empty;
    defer links.deinit(alloc);

    const projection: Projection = .{
        .terminal_state = &render_state,
        .preedit = null,
        .link_cells = &links,
        .scrollbar = .zero,
    };

    // The parser-owned terminal has been deinitialized. Projection only
    // reads storage retained by the completed render state.
    const cells = projection.terminal_state.row_data.items(.cells);
    try testing.expectEqual('A', cells[0].get(0).raw.codepoint());
    try testing.expectEqual('B', cells[0].get(1).raw.codepoint());
}
