const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const linkpkg = @import("../link.zig");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    /// The action to perform when this matcher resolves.
    action: inputpkg.Link.Action,

    /// The terminal text region searched by this matcher.
    candidate_scope: inputpkg.Link.CandidateScope,

    /// Whether prose hard-wrap boundaries are removed before matching.
    hard_wrap_continuations: bool,

    /// Whether joined candidates receive the built-in path match delimiter.
    hard_wrap_match_delimiter: bool,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true when this matcher contributes whole-viewport highlights.
    fn alwaysActive(
        self: *const Link,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover, .hover_mods => false,
        };
    }

    /// Returns true when pointer-local hover resolution is required.
    fn hoverActive(
        self: *const Link,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .hover => true,
            .hover_mods => |v| mouse_mods.equal(v),
            .always, .always_mods => false,
        };
    }
};

/// A terminal cell identity copied while the terminal lock is held. The
/// viewport coordinate is optional because a candidate may extend outside the
/// viewport, but its stable page identity must still participate in matching.
pub const HoverCell = struct {
    node: usize,
    y: terminal.size.CellCountInt,
    x: terminal.size.CellCountInt,
    viewport: ?point.Coordinate,
    wide: bool,
};

pub const PreparedHover = linkpkg.Prepared(HoverCell);
pub const PreparedAlways = linkpkg.VisibleCandidates(HoverCell);

const RowKey = struct {
    node: usize,
    y: terminal.size.CellCountInt,
};

/// Bulk index from stable page rows to viewport rows. Building this once per
/// preparation avoids an expensive PageList traversal for every candidate
/// byte while the terminal lock is held.
const ViewportRows = struct {
    rows: std.AutoHashMapUnmanaged(RowKey, terminal.size.CellCountInt) = .empty,

    fn init(alloc: Allocator, screen: *Screen) !ViewportRows {
        var result: ViewportRows = .{};
        errdefer result.deinit(alloc);

        var it = screen.pages.getTopLeft(.viewport).rowIterator(.right_down, null);
        for (0..screen.pages.rows) |viewport_y| {
            const pin = it.next() orelse break;
            try result.rows.put(alloc, .{
                .node = @intFromPtr(pin.node),
                .y = pin.y,
            }, @intCast(viewport_y));
        }
        return result;
    }

    fn deinit(self: *ViewportRows, alloc: Allocator) void {
        self.rows.deinit(alloc);
    }
};

fn hoverCell(
    viewport_rows: *const ViewportRows,
    screen: *Screen,
    pin: terminal.Pin,
) HoverCell {
    _ = screen;
    const viewport_y = viewport_rows.rows.get(.{
        .node = @intFromPtr(pin.node),
        .y = pin.y,
    });
    return .{
        .node = @intFromPtr(pin.node),
        .y = pin.y,
        .x = pin.x,
        .viewport = if (viewport_y) |y| .{ .x = pin.x, .y = y } else null,
        .wide = if (pin.node.pageIfResident()) |page|
            page.getRowAndCell(pin.x, pin.y).cell.wide == .wide
        else
            false,
    };
}

fn putHoverCell(
    alloc: Allocator,
    result: *terminal.RenderState.CellSet,
    cell: HoverCell,
) !void {
    const viewport = cell.viewport orelse return;
    try result.put(alloc, viewport, {});
    if (cell.wide) {
        var tail = viewport;
        tail.x += 1;
        try result.put(alloc, tail, {});
    }
}

fn removeHoverCell(
    result: *terminal.RenderState.CellSet,
    cell: HoverCell,
) void {
    const viewport = cell.viewport orelse return;
    _ = result.swapRemove(viewport);
    if (cell.wide) {
        var tail = viewport;
        tail.x += 1;
        _ = result.swapRemove(tail);
    }
}

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
                .action = link.action,
                .candidate_scope = link.candidate_scope,
                .hard_wrap_continuations = link.hard_wrap_continuations,
                .hard_wrap_match_delimiter = link.hard_wrap_match_delimiter,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Copies the candidates required to resolve an interactive hover while
    /// the terminal lock is held. Regex evaluation can then happen after the
    /// lock is released without retaining terminal pins.
    pub fn prepareHover(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
        osc8_owned: bool,
    ) !?PreparedHover {
        // OSC 8 metadata is the canonical owner of the hovered cells. Keep
        // this gate in the shared preparation entrypoint so renderer
        // orchestration cannot accidentally add an overlapping regex hover.
        if (osc8_owned) return null;
        const vp = mouse_viewport orelse return null;

        for (self.links) |*link| {
            if (link.hoverActive(mouse_mods)) break;
        } else return null;

        const target = screen.pages.pin(.{ .viewport = vp }) orelse return null;
        const prepared = try linkpkg.prepareAt(
            alloc,
            screen,
            self.links,
            target,
            mouse_mods,
        );
        var viewport_rows = try ViewportRows.init(alloc, screen);
        defer viewport_rows.deinit(alloc);
        return try linkpkg.mapPrepared(
            HoverCell,
            alloc,
            screen,
            prepared,
            &viewport_rows,
            hoverCell,
        );
    }

    /// Copies unique visible candidate domains for active always matchers
    /// while the terminal lock is held. Regex resolution happens later.
    pub fn prepareAlways(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_mods: inputpkg.Mods,
    ) !PreparedAlways {
        for (self.links) |link| {
            if (linkpkg.alwaysMatcherActive(link, mouse_mods)) break;
        } else return .{};

        var viewport_rows = try ViewportRows.init(alloc, screen);
        defer viewport_rows.deinit(alloc);
        return try linkpkg.prepareVisibleAlways(
            HoverCell,
            alloc,
            screen,
            self.links,
            mouse_mods,
            &viewport_rows,
            hoverCell,
        );
    }

    /// Resolves visible always matchers with canonical candidate scope and
    /// whole-match priority, then emits only cells currently in the viewport.
    pub fn renderPreparedAlways(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        prepared: PreparedAlways,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // OSC 8 is resolved before regex links. Translate its viewport cells
        // back to stable candidate identities so overlapping always regexes
        // are rejected as a whole instead of widening the underline.
        var seed: std.ArrayList(HoverCell) = .empty;
        defer seed.deinit(alloc);
        var seen: std.AutoHashMapUnmanaged(HoverCell, void) = .empty;
        defer seen.deinit(alloc);
        if (result.count() > 0) {
            for (prepared.candidates) |candidates| {
                for (candidates) |candidate| {
                    for (candidate.map) |cell| {
                        const viewport = cell.viewport orelse continue;
                        if (!result.contains(viewport) or seen.contains(cell)) continue;
                        try seen.put(alloc, cell, {});
                        try seed.append(alloc, cell);
                    }
                }
            }
        }

        const resolved = try linkpkg.resolveVisibleAlways(
            HoverCell,
            alloc,
            prepared,
            self.links,
            mouse_mods,
            seed.items,
        );
        defer {
            for (resolved) |match| alloc.free(match.cells);
            if (resolved.len > 0) alloc.free(resolved);
        }
        for (resolved) |match| {
            for (match.cells) |cell| {
                try putHoverCell(alloc, result, cell);
            }
        }
    }

    /// Replaces raw always highlights in the pointer's canonical candidate
    /// domain, then records accepted always matches and the one hover match
    /// that owns the target. Mixed highlight modes therefore obey the same
    /// matcher priority as click and preview.
    pub fn renderPreparedHover(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        prepared: PreparedHover,
        mouse_mods: inputpkg.Mods,
    ) !void {
        for (self.links) |link| {
            if (link.alwaysActive(mouse_mods)) break;
        } else {
            const match = try linkpkg.resolveAt(
                HoverCell,
                alloc,
                prepared,
                self.links,
                mouse_mods,
            ) orelse return;
            defer alloc.free(match.cells);
            for (match.cells) |cell| {
                try putHoverCell(alloc, result, cell);
            }
            return;
        }

        for (self.links) |*link| {
            if (!link.alwaysActive(mouse_mods)) continue;
            const candidates = linkpkg.candidatesFor(
                HoverCell,
                prepared,
                link.*,
            );
            for (candidates) |candidate| {
                for (candidate.map) |cell| {
                    removeHoverCell(result, cell);
                }
            }
        }

        const resolved = try linkpkg.resolveAll(
            HoverCell,
            alloc,
            prepared,
            self.links,
            mouse_mods,
            &.{},
        );
        defer {
            for (resolved) |match| alloc.free(match.cells);
            if (resolved.len > 0) alloc.free(resolved);
        }

        for (resolved) |match| {
            const emit = switch (self.links[match.matcher_index].highlight) {
                .always, .always_mods => true,
                .hover, .hover_mods => emit: {
                    for (match.cells) |cell| {
                        if (std.meta.eql(cell, prepared.target)) break :emit true;
                    }
                    break :emit false;
                },
            };
            if (!emit) continue;

            for (match.cells) |cell| {
                try putHoverCell(alloc, result, cell);
            }
        }
    }
};

fn renderHoverForTest(
    set: *const Set,
    alloc: Allocator,
    terminal_: *Terminal,
    result: *terminal.RenderState.CellSet,
    mouse: ?point.Coordinate,
    mods: inputpkg.Mods,
) !void {
    const prepared = try set.prepareHover(
        alloc,
        terminal_.screens.active,
        mouse,
        mods,
        false,
    ) orelse return;
    try set.renderPreparedHover(alloc, result, prepared, mods);
}

fn renderAlwaysForTest(
    set: *const Set,
    alloc: Allocator,
    terminal_: *Terminal,
    result: *terminal.RenderState.CellSet,
    mods: inputpkg.Mods,
) !void {
    var prepared = try set.prepareAlways(
        alloc,
        terminal_.screens.active,
        mods,
    );
    defer prepared.deinit(alloc);
    try set.renderPreparedAlways(alloc, result, prepared, mods);
}

test "renderPreparedAlways" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try renderAlwaysForTest(
        &set,
        alloc,
        &t,
        &result,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderPreparedAlways honors semantic scope and matcher priority" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 32, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    t.screens.active.cursorSetSemanticContent(.output);
    stream.nextSlice("FOO");
    t.screens.active.cursorSetSemanticContent(.{ .input = .clear_explicit });
    stream.nextSlice("BAR");

    for ([_]struct {
        scope: inputpkg.Link.CandidateScope,
        expected: usize,
    }{
        .{ .scope = .semantic, .expected = 0 },
        .{ .scope = .bounded_logical, .expected = 6 },
    }) |case| {
        var set = try Set.fromConfig(alloc, &.{.{
            .regex = "FOOBAR",
            .action = .{ .open = {} },
            .highlight = .always,
            .candidate_scope = case.scope,
        }});
        defer set.deinit(alloc);
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderAlwaysForTest(&set, arena.allocator(), &t, &result, .{});
        try testing.expectEqual(case.expected, result.count());
    }

    var url_terminal: terminal.Terminal = try .init(alloc, .{ .cols = 32, .rows = 2 });
    defer url_terminal.deinit(alloc);
    var url_stream = url_terminal.vtStream();
    defer url_stream.deinit();
    const value = "https://example.com.";
    url_stream.nextSlice(value);

    for ([_]struct {
        broad_first: bool,
        expected: usize,
    }{
        .{ .broad_first = false, .expected = value.len - 1 },
        .{ .broad_first = true, .expected = value.len },
    }) |case| {
        const exact: inputpkg.Link = .{
            .regex = "https://example\\.com",
            .action = .{ .open = {} },
            .highlight = .always,
        };
        const broad: inputpkg.Link = .{
            .regex = "https://example\\.com\\.",
            .action = .{ .open = {} },
            .highlight = .always,
            .candidate_scope = .bounded_logical,
        };
        const links = if (case.broad_first)
            [_]inputpkg.Link{ broad, exact }
        else
            [_]inputpkg.Link{ exact, broad };
        var set = try Set.fromConfig(alloc, &links);
        defer set.deinit(alloc);
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderAlwaysForTest(
            &set,
            arena.allocator(),
            &url_terminal,
            &result,
            .{},
        );
        try testing.expectEqual(case.expected, result.count());
    }
}

test "renderPreparedHover matches cross-scope click priority" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 16, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    t.screens.active.cursorSetSemanticContent(.output);
    stream.nextSlice("FOO");
    t.screens.active.cursorSetSemanticContent(.{ .input = .clear_explicit });
    stream.nextSlice("BAR");

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "BAR",
            .action = .{ .open = {} },
            .highlight = .hover,
            .candidate_scope = .semantic,
        },
        .{
            .regex = "FOOBAR",
            .action = .{ .open = {} },
            .highlight = .hover,
            .candidate_scope = .bounded_logical,
        },
    });
    defer set.deinit(alloc);

    for ([_]struct {
        mouse: point.Coordinate,
        expected: usize,
    }{
        .{ .mouse = .{ .x = 1, .y = 0 }, .expected = 0 },
        .{ .mouse = .{ .x = 4, .y = 0 }, .expected = 3 },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            arena.allocator(),
            &t,
            &result,
            case.mouse,
            .{},
        );
        try testing.expectEqual(case.expected, result.count());
        for (0..3) |x| try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 0 }));
        if (case.expected == 3) {
            for (3..6) |x| try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
    }
}

test "renderPreparedAlways applies priority from an offscreen joined domain" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 16, .rows = 1 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("BAR-\r\nFOO");

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "BAR-",
            .action = .{ .open = {} },
            .highlight = .always,
            .candidate_scope = .semantic,
        },
        .{
            .regex = "BAR-FOO",
            .action = .{ .open = {} },
            .highlight = .always,
            .candidate_scope = .bounded_logical,
            .hard_wrap_continuations = true,
        },
    });
    defer set.deinit(alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var result: terminal.RenderState.CellSet = .empty;
    try renderAlwaysForTest(&set, arena.allocator(), &t, &result, .{});

    // BAR- is above the viewport, but still owns cells in the joined
    // candidate. The overlapping lower-priority match is rejected as a
    // whole, so its visible FOO suffix must not be underlined.
    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderPreparedHover preserves an unrelated always candidate domain" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: terminal.Terminal = try .init(alloc, .{ .cols = 32, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    t.screens.active.cursorSetSemanticContent(.output);
    stream.nextSlice("FOO ");
    t.screens.active.cursorSetSemanticContent(.{ .input = .clear_explicit });
    stream.nextSlice("BAR");

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "FOO",
            .action = .{ .open = {} },
            .highlight = .always,
        },
        .{
            .regex = "BAR",
            .action = .{ .open = {} },
            .highlight = .hover,
            .candidate_scope = .bounded_logical,
        },
    });
    defer set.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const frame_alloc = arena.allocator();
    var result: terminal.RenderState.CellSet = .empty;
    try renderAlwaysForTest(&set, frame_alloc, &t, &result, .{});
    try renderHoverForTest(
        &set,
        frame_alloc,
        &t,
        &result,
        .{ .x = 5, .y = 0 },
        .{},
    );
    for (0..3) |x| try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
    for (4..7) |x| try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
}

test "renderPreparedAlways preserves custom hard-wrap end anchors" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 32,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("/tmp/a-\r\n    b.txt.");

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "/tmp/a-b\\.txt\\.\\z",
        .action = .{ .open = {} },
        .highlight = .always,
        .hard_wrap_continuations = true,
    }});
    defer set.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var result: terminal.RenderState.CellSet = .empty;
    try renderAlwaysForTest(&set, arena.allocator(), &t, &result, .{});
    try testing.expectEqual(@as(usize, 13), result.count());
    for (0..7) |x| {
        try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
    }
    for (0..4) |x| try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
    for (4..10) |x| {
        try testing.expect(result.contains(.{ .x = @intCast(x), .y = 1 }));
    }
    try testing.expect(!result.contains(.{ .x = 10, .y = 1 }));

    var hover_set = try Set.fromConfig(alloc, &.{.{
        .regex = "/tmp/a-b\\.txt\\.\\z",
        .action = .{ .open = {} },
        .highlight = .hover,
        .hard_wrap_continuations = true,
    }});
    defer hover_set.deinit(alloc);
    var hover_arena = std.heap.ArenaAllocator.init(alloc);
    defer hover_arena.deinit();
    var hover: terminal.RenderState.CellSet = .empty;
    try renderHoverForTest(
        &hover_set,
        hover_arena.allocator(),
        &t,
        &hover,
        .{ .x = 9, .y = 1 },
        .{},
    );
    try testing.expectEqual(result.count(), hover.count());
    var always_it = result.iterator();
    while (always_it.next()) |entry| {
        try testing.expect(hover.contains(entry.key_ptr.*));
    }
}

test "renderPreparedHover matches exact user path with default matchers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const prefix = "The built app is ";
    const first = "/Users/cmux-lawrence/Applications/cmux-browser-resize-modes-";
    const second = "20260716-warm.app";

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 160,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(prefix ++ first ++ "\r\n    " ++ second ++ ".");

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = url.scheme_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .candidate_scope = .bounded_logical,
            .hard_wrap_continuations = true,
        },
        .{
            .regex = url.path_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .hard_wrap_continuations = true,
            .hard_wrap_match_delimiter = true,
        },
    });
    defer set.deinit(alloc);

    for ([_]point.Coordinate{
        .{ .x = prefix.len + 20, .y = 0 },
        .{ .x = 10, .y = 1 },
    }) |mouse| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            mouse,
            inputpkg.ctrlOrSuper(.{}),
        );

        try testing.expectEqual(first.len + second.len, result.count());
        for (0..prefix.len) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
        for (prefix.len..prefix.len + first.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
        for (0..4) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (4..4 + second.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        try testing.expect(!result.contains(.{
            .x = 4 + second.len,
            .y = 1,
        }));
    }
}

test "renderPreparedHover owns mapped spaces but not sentence punctuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const first = "/tmp/build-";
    const second = "warm.app";
    const cases = [_]struct {
        suffix: []const u8,
        owned_suffix_cells: usize,
    }{
        .{ .suffix = "   ", .owned_suffix_cells = 3 },
        .{ .suffix = ".   ", .owned_suffix_cells = 0 },
    };

    for (cases) |case| {
        var t: terminal.Terminal = try .init(alloc, .{ .cols = 64, .rows = 3 });
        defer t.deinit(alloc);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(first ++ "\r\n    " ++ second);
        stream.nextSlice(case.suffix);

        var set = try Set.fromConfig(alloc, &.{.{
            .regex = url.path_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .hard_wrap_continuations = true,
            .hard_wrap_match_delimiter = true,
        }});
        defer set.deinit(alloc);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            arena.allocator(),
            &t,
            &result,
            .{ .x = 6, .y = 1 },
            inputpkg.ctrlOrSuper(.{}),
        );

        try testing.expectEqual(
            first.len + second.len + case.owned_suffix_cells,
            result.count(),
        );
        for (0..first.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
        for (0..4) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (4..4 + second.len + case.owned_suffix_cells) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (4 + second.len + case.owned_suffix_cells..4 + second.len + case.suffix.len) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
    }
}

test "renderPreparedHover excludes punctuation from a wrapped bare relative path" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const first = "src/foo-";
    const second = "bar/file.zig";

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 32,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(first ++ "\r\n    " ++ second ++ ".,");

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = url.path_regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
        .hard_wrap_continuations = true,
        .hard_wrap_match_delimiter = true,
    }});
    defer set.deinit(alloc);

    for ([_]point.Coordinate{
        .{ .x = 3, .y = 0 },
        .{ .x = 7, .y = 1 },
    }) |mouse| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            arena.allocator(),
            &t,
            &result,
            mouse,
            inputpkg.ctrlOrSuper(.{}),
        );
        for (0..first.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
        for (0..4) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (4..4 + second.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (4 + second.len..4 + second.len + 2) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
    }
}

test "renderPreparedHover keeps sentence URL and indented path separate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const prefix = "See ";
    const first = "https://example.com";
    const second = "/tmp/foo";

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 80, .rows = 3 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(prefix ++ first ++ ".\r\n    " ++ second);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = url.scheme_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .candidate_scope = .bounded_logical,
            .hard_wrap_continuations = true,
        },
        .{
            .regex = url.path_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .hard_wrap_continuations = true,
            .hard_wrap_match_delimiter = true,
        },
    });
    defer set.deinit(alloc);

    const cases = [_]struct {
        mouse: point.Coordinate,
        row: terminal.size.CellCountInt,
        start: usize,
        len: usize,
    }{
        .{
            .mouse = .{ .x = prefix.len + 8, .y = 0 },
            .row = 0,
            .start = prefix.len,
            .len = first.len,
        },
        .{
            .mouse = .{ .x = 6, .y = 1 },
            .row = 1,
            .start = 4,
            .len = second.len,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            arena.allocator(),
            &t,
            &result,
            case.mouse,
            inputpkg.ctrlOrSuper(.{}),
        );
        try testing.expectEqual(case.len, result.count());
        for (case.start..case.start + case.len) |x| {
            try testing.expect(result.contains(.{
                .x = @intCast(x),
                .y = case.row,
            }));
        }
    }
}

test "renderPreparedHover keeps adjacent independent links separate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const values = [_][]const u8{
        "/tmp/foo/",
        "/tmp/bar",
        "https://example.com/path-",
        "https://example.org",
    };

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 80,
        .rows = values.len,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(
        values[0] ++ "\r\n    " ++ values[1] ++
            "\r\n" ++ values[2] ++ "\r\n    " ++ values[3],
    );

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = url.scheme_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .candidate_scope = .bounded_logical,
            .hard_wrap_continuations = true,
        },
        .{
            .regex = url.path_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .hard_wrap_continuations = true,
            .hard_wrap_match_delimiter = true,
        },
    });
    defer set.deinit(alloc);

    for (values, 0..) |expected, y| {
        const indentation: usize = if (y == 1 or y == 3) 4 else 0;
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            arena.allocator(),
            &t,
            &result,
            .{
                .x = @intCast(indentation + expected.len / 2),
                .y = @intCast(y),
            },
            inputpkg.ctrlOrSuper(.{}),
        );
        try testing.expectEqual(expected.len, result.count());
        for (indentation..indentation + expected.len) |x| {
            try testing.expect(result.contains(.{
                .x = @intCast(x),
                .y = @intCast(y),
            }));
        }
    }
}

test "renderPreparedHover does not merge adjacent bare path after slash" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const first = "src/foo/";
    const second = "src/bar.zig";

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 80, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(first ++ "\r\n    " ++ second);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = url.path_regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
        .hard_wrap_continuations = true,
        .hard_wrap_match_delimiter = true,
    }});
    defer set.deinit(alloc);

    var upper_arena = std.heap.ArenaAllocator.init(alloc);
    defer upper_arena.deinit();
    var upper: terminal.RenderState.CellSet = .empty;
    try renderHoverForTest(
        &set,
        upper_arena.allocator(),
        &t,
        &upper,
        .{ .x = 3, .y = 0 },
        inputpkg.ctrlOrSuper(.{}),
    );
    try testing.expectEqual(@as(usize, 0), upper.count());

    var lower_arena = std.heap.ArenaAllocator.init(alloc);
    defer lower_arena.deinit();
    var lower: terminal.RenderState.CellSet = .empty;
    try renderHoverForTest(
        &set,
        lower_arena.allocator(),
        &t,
        &lower,
        .{ .x = 8, .y = 1 },
        inputpkg.ctrlOrSuper(.{}),
    );
    try testing.expectEqual(second.len, lower.count());
    for (4..4 + second.len) |x| {
        try testing.expect(lower.contains(.{ .x = @intCast(x), .y = 1 }));
    }
}

test "renderPreparedHover highlights both columns of wide UTF-8 glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const first = "https://example.com/wiki/";

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 64,
        .rows = 3,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(first ++ "\r\n    日本語.");

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "https://example\\.com/wiki/日本語",
        .action = .{ .open = {} },
        .highlight = .hover,
        .hard_wrap_continuations = true,
    }});
    defer set.deinit(alloc);

    for ([_]point.Coordinate{
        .{ .x = 8, .y = 0 },
        .{ .x = 4, .y = 1 },
        .{ .x = 5, .y = 1 },
        .{ .x = 9, .y = 1 },
    }) |mouse| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            arena.allocator(),
            &t,
            &result,
            mouse,
            .{},
        );
        for (0..first.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
        for (0..4) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (4..10) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        try testing.expect(!result.contains(.{ .x = 10, .y = 1 }));
    }
}

test "renderPreparedAlways cannot widen an OSC 8 link" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const visible = "https://visible.example";

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 64, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(
        "\x1b]8;;https://target.example/osc8\x1b\\" ++ visible ++
            "\x1b]8;;\x1b\\.",
    );
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "https://visible\\.example\\.",
        .action = .{ .open = {} },
        .highlight = .always,
    }});
    defer set.deinit(alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const frame_alloc = arena.allocator();
    var result = try state.linkCells(frame_alloc, .{ .x = 8, .y = 0 });
    const prepared = try set.prepareAlways(frame_alloc, t.screens.active, .{});
    try set.renderPreparedAlways(frame_alloc, &result, prepared, .{});
    try testing.expectEqual(visible.len, result.count());
    try testing.expect(!result.contains(.{ .x = @intCast(visible.len), .y = 0 }));
}

test "prepareHover gives OSC 8 ownership over an overlapping regex" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const visible = "https://visible.example";

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 64, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(
        "\x1b]8;;https://target.example/osc8\x1b\\" ++ visible ++
            "\x1b]8;;\x1b\\.",
    );
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "https://visible\\.example\\.",
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
    }});
    defer set.deinit(alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const frame_alloc = arena.allocator();
    const mouse: point.Coordinate = .{ .x = 8, .y = 0 };
    const result = try state.linkCells(frame_alloc, mouse);
    const prepared = try set.prepareHover(
        frame_alloc,
        t.screens.active,
        mouse,
        inputpkg.ctrlOrSuper(.{}),
        result.count() > 0,
    );
    try testing.expect(prepared == null);
    try testing.expectEqual(visible.len, result.count());
    try testing.expect(!result.contains(.{ .x = @intCast(visible.len), .y = 0 }));
}

test "mapPrepared does not restore a compressed target page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows + 24) |_| stream.nextSlice("history\r\n");
    _ = pages.compress(.full);

    const compressed = pages.pages.first.?;
    try testing.expectEqual(.compressed, compressed.storage());
    var viewport_rows = try ViewportRows.init(alloc, t.screens.active);
    defer viewport_rows.deinit(alloc);
    const prepared: linkpkg.Prepared(terminal.Pin) = .{
        .target = .{ .node = compressed, .x = 0, .y = 0 },
    };
    const mapped = try linkpkg.mapPrepared(
        HoverCell,
        alloc,
        t.screens.active,
        prepared,
        &viewport_rows,
        hoverCell,
    );
    try testing.expect(mapped.target.viewport == null);
    try testing.expect(!mapped.target.wide);
    try testing.expectEqual(.compressed, compressed.storage());
}

test "renderPreparedHover default matcher priority excludes non-link cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const first = "https://github.com/manaflow-ai/cmux/issues/8059#issuecomment-";
    const second = "01234-";
    const third = "56789";

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 96,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(first ++ "\r\n    " ++ second ++ "\r\n    " ++ third ++ ".,");

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = url.scheme_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .candidate_scope = .bounded_logical,
            .hard_wrap_continuations = true,
        },
        .{
            .regex = url.path_regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = inputpkg.ctrlOrSuper(.{}) },
            .hard_wrap_continuations = true,
            .hard_wrap_match_delimiter = true,
        },
    });
    defer set.deinit(alloc);

    // Hovering either segment resolves the same exact URL cells.
    for ([_]point.Coordinate{
        .{ .x = 20, .y = 0 },
        .{ .x = 8, .y = 1 },
        .{ .x = 6, .y = 2 },
    }) |mouse| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            mouse,
            inputpkg.ctrlOrSuper(.{}),
        );

        for (0..first.len) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
        }
        try testing.expect(!result.contains(.{ .x = 3, .y = 1 }));
        for (4..10) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 1 }));
        }
        for (0..4) |x| {
            try testing.expect(!result.contains(.{ .x = @intCast(x), .y = 2 }));
        }
        for (4..9) |x| {
            try testing.expect(result.contains(.{ .x = @intCast(x), .y = 2 }));
        }
        try testing.expect(!result.contains(.{ .x = 9, .y = 2 }));
        try testing.expect(!result.contains(.{ .x = 10, .y = 2 }));
    }

    // Indentation and sentence punctuation are not hover targets, including
    // where the lower-priority path matcher would otherwise claim the period.
    for ([_]point.Coordinate{
        .{ .x = 3, .y = 1 },
        .{ .x = 3, .y = 2 },
        .{ .x = 9, .y = 2 },
        .{ .x = 10, .y = 2 },
    }) |mouse| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();
        var result: terminal.RenderState.CellSet = .empty;
        try renderHoverForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            mouse,
            inputpkg.ctrlOrSuper(.{}),
        );
        try testing.expectEqual(@as(usize, 0), result.count());
    }
}

test "renderPreparedHover arbitrates mixed always and hover matchers" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const value = "https://example.com.";
    const exact_len = value.len - 1;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 32,
        .rows = 2,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(value);

    const cases = [_]struct {
        exact_highlight: inputpkg.Link.Highlight,
        broad_highlight: inputpkg.Link.Highlight,
        mouse_x: usize,
        expected_count: usize,
    }{
        .{
            .exact_highlight = .always,
            .broad_highlight = .hover,
            .mouse_x = exact_len,
            .expected_count = exact_len,
        },
        .{
            .exact_highlight = .hover,
            .broad_highlight = .always,
            .mouse_x = 8,
            .expected_count = exact_len,
        },
        .{
            .exact_highlight = .hover,
            .broad_highlight = .always,
            .mouse_x = exact_len,
            .expected_count = 0,
        },
    };

    for (cases) |case| {
        var set = try Set.fromConfig(alloc, &.{
            .{
                .regex = "https://example\\.com",
                .action = .{ .open = {} },
                .highlight = case.exact_highlight,
            },
            .{
                .regex = "https://example\\.com\\.",
                .action = .{ .open = {} },
                .highlight = case.broad_highlight,
            },
        });
        defer set.deinit(alloc);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();
        var result: terminal.RenderState.CellSet = .empty;
        try renderAlwaysForTest(&set, frame_alloc, &t, &result, .{});
        try renderHoverForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            .{ .x = @intCast(case.mouse_x), .y = 0 },
            .{},
        );

        try testing.expectEqual(case.expected_count, result.count());
        try testing.expect(!result.contains(.{ .x = @intCast(exact_len), .y = 0 }));
    }

    // Reversing matcher order intentionally gives the broad matcher ownership
    // of the sentence period.
    var reverse = try Set.fromConfig(alloc, &.{
        .{
            .regex = "https://example\\.com\\.",
            .action = .{ .open = {} },
            .highlight = .always,
        },
        .{
            .regex = "https://example\\.com",
            .action = .{ .open = {} },
            .highlight = .hover,
        },
    });
    defer reverse.deinit(alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const frame_alloc = arena.allocator();
    var result: terminal.RenderState.CellSet = .empty;
    try renderAlwaysForTest(&reverse, frame_alloc, &t, &result, .{});
    try renderHoverForTest(
        &reverse,
        frame_alloc,
        &t,
        &result,
        .{ .x = @intCast(exact_len), .y = 0 },
        .{},
    );
    try testing.expectEqual(value.len, result.count());
    try testing.expect(result.contains(.{ .x = @intCast(exact_len), .y = 0 }));
}

test "render hover links alongside always links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();
        var result: terminal.RenderState.CellSet = .empty;
        try renderAlwaysForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            .{},
        );
        try renderHoverForTest(&set, frame_alloc, &t, &result, null, .{});

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const frame_alloc = arena.allocator();
        var result: terminal.RenderState.CellSet = .empty;
        try renderAlwaysForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            .{},
        );
        try renderHoverForTest(
            &set,
            frame_alloc,
            &t,
            &result,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    const prepared_always = try set.prepareAlways(
        failing_alloc,
        t.screens.active,
        .{},
    );
    try set.renderPreparedAlways(failing_alloc, &result, prepared_always, .{});
    try testing.expect(try set.prepareHover(
        failing_alloc,
        t.screens.active,
        null,
        .{},
        false,
    ) == null);

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderPreparedAlways mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try renderAlwaysForTest(
        &set,
        alloc,
        &t,
        &result,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}
