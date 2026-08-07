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

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 32, .rows = 2 });
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

    var url_terminal: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 32, .rows = 2 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 16, .rows = 2 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 16, .rows = 1 });
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
    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 32, .rows = 2 });
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
    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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
        var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 64, .rows = 3 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 3 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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

test "renderPreparedHover does not join a short URL row ending in slash" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const first = "https://google.com/";
    const second = "foobar";

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice(first ++ "\r\n" ++ second);

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

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var result: terminal.RenderState.CellSet = .empty;
    try renderHoverForTest(
        &set,
        arena.allocator(),
        &t,
        &result,
        .{ .x = 10, .y = 0 },
        inputpkg.ctrlOrSuper(.{}),
    );

    try testing.expectEqual(first.len, result.count());
    for (0..first.len) |x| {
        try testing.expect(result.contains(.{ .x = @intCast(x), .y = 0 }));
    }
}

test "renderPreparedHover does not merge adjacent bare path after slash" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");
    const first = "src/foo/";
    const second = "src/bar.zig";

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 2 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 64, .rows = 2 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 64, .rows = 2 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 80, .rows = 24 });
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
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

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
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
    const io = testing.io;

    var t: terminal.Terminal = try .init(io, alloc, .{
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

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
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

// cmux fork: (B) ExternalHover — lets the embedding host (which has context
// Ghostty intentionally doesn't, like a working directory and filesystem
// existence) own interactive hover rendering for a resolved link, instead
// of a native regex partial match drawing a competing underline. See
// `ExternalHover` below and its usage in `generic.zig`'s render loop and
// `Surface.setExternalLinkHover`.

/// Opaque cross-thread/cross-ABI identity for a captured physical-row
/// content snapshot: surface+screen identity, the row scope the snapshot
/// was taken over (fixed at mint time — never re-derived from a "current"
/// mouse cell), and a bounded content fingerprint of exactly that scope.
/// Two tokens compare equal only if all four words match; a real content or
/// scope change is astronomically unlikely to produce a matching token by
/// chance, which is the only property this type needs (it is a fast-path
/// equality gate, not a security boundary).
pub const PhysicalSnapshotToken = extern struct {
    bits: [4]u64,

    pub const zero: PhysicalSnapshotToken = .{ .bits = .{ 0, 0, 0, 0 } };

    pub fn eql(a: PhysicalSnapshotToken, b: PhysicalSnapshotToken) bool {
        return std.mem.eql(u64, &a.bits, &b.bits);
    }
};

/// Maximum physical rows a single `PhysicalSnapshotToken` may fingerprint.
/// The cmux click/hover resolver reads at most 3 rows (previous/clicked/
/// next); this leaves margin without letting a pathological caller make
/// fingerprinting unbounded.
pub const max_snapshot_rows: usize = 8;

/// Maximum columns per fingerprinted row. Fingerprinting a row wider than
/// this fails closed (returns `null`) rather than truncating, since a
/// truncated fingerprint could match content it never actually observed.
pub const max_snapshot_row_columns: usize = 512;

/// Builds a `PhysicalSnapshotToken` from a caller-supplied row range and its
/// joined physical-row text (one line per physical row, in the exact form
/// `ghostty_surface_read_text_physical_rows` returns for the same range —
/// see the cmux fork's (A) addition), or `null` if `row_count` or the text
/// length exceed the bounds above. Pure and does not itself allocate, so it
/// never needs a live `Screen` to unit test; the caller (the render loop,
/// re-fingerprinting every frame, and the setter, fingerprinting once at
/// mint time) is responsible for producing that text via a bounded,
/// frame-arena-scoped read — never an unbounded per-frame heap allocation.
/// (B) flicker fix §4 (review-flicker-fix-confirm.md §3) — `row_space_revision`
/// and `viewport_offset` (from `PageList.scrollbar()`) fold into the scope
/// hash so a token minted at one scroll position can never validate at a
/// different one. Neither `ScreenSet.generation` nor `row_space_revision`
/// alone changes on an ordinary scroll (`row_space_revision` only bumps
/// when retained rows' absolute offsets are reassigned, e.g. scrollback
/// trim/resize) — only `viewport_offset` reliably does, so the pair is
/// required together; `viewport_offset` identifies WHICH rows are visible,
/// while the existing content fingerprint identifies WHAT those rows show,
/// and neither substitutes for the other.
pub fn buildPhysicalSnapshotToken(
    surface_id: u64,
    screen_key_byte: u8,
    screen_generation: usize,
    top_row: u32,
    row_count: u32,
    joined_physical_rows_text: []const u8,
    row_space_revision: u64,
    viewport_offset: usize,
) ?PhysicalSnapshotToken {
    if (row_count == 0 or row_count > max_snapshot_rows) return null;
    if (joined_physical_rows_text.len > max_snapshot_rows * max_snapshot_row_columns) return null;

    var content_hash = std.hash.Wyhash.init(surface_id);
    content_hash.update(std.mem.asBytes(&screen_key_byte));
    content_hash.update(std.mem.asBytes(&screen_generation));
    content_hash.update(joined_physical_rows_text);
    const content_word = content_hash.final();

    var scope_hash = std.hash.Wyhash.init(surface_id +% 1);
    scope_hash.update(std.mem.asBytes(&screen_key_byte));
    scope_hash.update(std.mem.asBytes(&screen_generation));
    scope_hash.update(std.mem.asBytes(&top_row));
    scope_hash.update(std.mem.asBytes(&row_count));
    scope_hash.update(std.mem.asBytes(&row_space_revision));
    scope_hash.update(std.mem.asBytes(&viewport_offset));
    const scope_word = scope_hash.final();

    return .{ .bits = .{ content_word, scope_word, top_row, row_count } };
}

/// A `PhysicalSnapshotToken` combined with the pointer cell, normalized
/// mods, and hover-input epoch active when the token was minted. This is
/// the unit of identity `ExternalHover.validateOrInvalidate` checks on
/// every render: a mismatch in the underlying content, the row scope, or
/// the pointer context all invalidate it. The setter mints this itself and
/// returns it to the host as an out parameter — the host never
/// reconstructs one from a snapshot token, so it can't accidentally widen
/// what a stale token matches.
pub const HoverActivationToken = extern struct {
    bits: [4]u64,

    pub const zero: HoverActivationToken = .{ .bits = .{ 0, 0, 0, 0 } };

    pub fn eql(a: HoverActivationToken, b: HoverActivationToken) bool {
        return std.mem.eql(u64, &a.bits, &b.bits);
    }
};

/// Combines a physical snapshot token with pointer/mods/epoch context into
/// a `HoverActivationToken`. Each output word is an independent Wyhash of
/// every input (with a distinct seed), so equality reduces to a plain
/// 4-word memcmp without needing to decode or partially compare fields.
pub fn buildHoverActivationToken(
    physical: PhysicalSnapshotToken,
    pointer_cell: ?point.Coordinate,
    mods_bits: u16,
    epoch: u64,
) HoverActivationToken {
    const cell_x: u32 = if (pointer_cell) |c| c.x else std.math.maxInt(u32);
    const cell_y: u32 = if (pointer_cell) |c| c.y else std.math.maxInt(u32);

    var bits: [4]u64 = undefined;
    inline for (&bits, 0..) |*out, i| {
        var hash = std.hash.Wyhash.init(@as(u64, i) +% 0x9E3779B97F4A7C15);
        hash.update(std.mem.asBytes(&physical.bits));
        hash.update(std.mem.asBytes(&cell_x));
        hash.update(std.mem.asBytes(&cell_y));
        hash.update(std.mem.asBytes(&mods_bits));
        hash.update(std.mem.asBytes(&epoch));
        out.* = hash.final();
    }
    return .{ .bits = bits };
}

/// One half-open viewport row range the host resolved as part of a hover
/// candidate. Half-open: `[start_column, end_column)`.
pub const ExternalHoverCellRange = extern struct {
    row: u16,
    start_column: u16,
    end_column: u16,
};

/// A host-resolved path can cross at most the visible viewport. Keeping
/// the ranges inline (no allocation) avoids allocator ownership and
/// cross-thread lifetime concerns on the mouse-move hot path.
pub const max_external_hover_ranges: usize = 256;
/// Total cells across all ranges, independent of range count, so a few
/// very wide ranges can't blow past the render-loop's per-frame cell
/// budget the way `max_external_hover_ranges` alone would allow.
pub const max_external_hover_cells: u32 = 4096;

/// Whether `ranges` contains `cell` — `cell.y` matches some range's `row`
/// (an absolute viewport row, per `ExternalHoverCellRange`'s doc) and
/// `cell.x` falls in that range's half-open `[start_column, end_column)`.
/// Shared by `ExternalHover.set`'s setter-containment guard and
/// `validateOrInvalidate`'s render-time check — the same "is the pointer
/// currently over this candidate" question, asked at two different times
/// (review-flicker-fix-confirm.md §1).
pub fn rangesContainCell(ranges: []const ExternalHoverCellRange, cell: point.Coordinate) bool {
    for (ranges) |r| {
        if (r.row == cell.y and cell.x >= r.start_column and cell.x < r.end_column) return true;
    }
    return false;
}

// cmux fork: (C) ExternalHover diagnostics — bug C (#8810) hover lifecycle
// tracing (design-hover-diagnostics-v4-final.md). POD-only: entries carry
// enum raw values, never strings — string formation happens exclusively on
// the host side, after a destructive drain has released the renderer
// mutex. See `ExternalHoverDiagRing`'s doc for the ring itself.

/// Debug-only diagnostics gate, but present in ALL build modes (Debug,
/// Release, ReleaseFast) — NOT `builtin.mode`-gated. Dogfood runs a Debug
/// cmux app against a ReleaseFast GhosttyKit, so gating this behind
/// `std.debug.runtime_safety`/`builtin.mode` would silently produce zero
/// diagnostics in exactly the build combination that matters. Read once
/// (lock-free memoized read, benign to race since the computed value is
/// idempotent) from `CMUX_EXTERNAL_HOVER_DIAGNOSTICS=1`, mirroring the
/// host's own gate-once contract (design v4 §6.2).
var external_hover_diag_gate_state: std.atomic.Value(u8) = .init(0); // 0=unread 1=false 2=true

pub fn externalHoverDiagnosticsEnabled() bool {
    const cached = external_hover_diag_gate_state.load(.monotonic);
    if (cached != 0) return cached == 2;
    const enabled = if (std.c.getenv("CMUX_EXTERNAL_HOVER_DIAGNOSTICS")) |raw|
        std.mem.eql(u8, std.mem.span(raw), "1")
    else
        false;
    external_hover_diag_gate_state.store(if (enabled) @as(u8, 2) else 1, .monotonic);
    return enabled;
}

/// `source` field of `ExternalHoverDiagEntry` — which lifecycle stage
/// produced this entry. No `.none`: every entry has exactly one source.
pub const ExternalHoverDiagSource = enum(u8) {
    setter = 1,
    input = 2,
    render = 3,
};

/// `reason` field — populated for `source=setter` (setter rejection, plus
/// the post-accept `renderQueueFailed` side-failure) and `source=input`
/// (input-time range/viewport exit). `.none` (raw 0) means "not
/// applicable to this entry", always distinguishable from a real reason
/// (which starts at 1) so a zeroed/never-written slot can never be
/// misread as one.
pub const ExternalHoverDiagReason = enum(u8) {
    none = 0,
    zeroRowCount = 1,
    hoverIneligible = 2,
    scopeOutOfBounds = 3,
    snapshotBuildFailed = 4,
    pointerMissing = 5,
    pointerNotInRanges = 6,
    rangeCountExceeded = 7,
    rangeOutOfScope = 8,
    rangeEmptyOrInverted = 9,
    cellBudgetExceeded = 10,
    viewportExit = 11,
    renderQueueFailed = 12,
};

/// `verdict` field — populated for `source=render` (per-frame
/// validation). `.none` (raw 0) means "not applicable" (every
/// setter/input entry leaves this at `.none`).
pub const ExternalHoverDiagVerdict = enum(u8) {
    none = 0,
    valid = 1,
    osc8Present = 2,
    hoverIneligible = 3,
    scopeOutOfBounds = 4,
    pointerMissing = 5,
    pointerNotInRanges = 6,
    viewportExit = 7,
    physicalTokenMismatch = 8,
    contextEpochMismatch = 9,
    snapshotBuildFailed = 10,
    renderQueueFailed = 11,
};

/// `flags` bit 0: this is the first render-validation entry for the
/// activation `event` currently identifies. The entry itself must carry
/// this — a host that infers "first" from log history gets it wrong
/// across a ring overflow, which can drop the actual first entry.
pub const external_hover_diag_flag_first_for_activation: u8 = 1 << 0;

/// One fixed-size diagnostic entry. `extern struct` with explicit field
/// order so the Zig writer and the host's Swift decoder agree on layout
/// without a shared header — `ghostty_external_hover_diag_entry_s` in
/// `include/ghostty.h` mirrors this exactly, field-for-field.
pub const ExternalHoverDiagEntry = extern struct {
    event: u64 = 0,
    source: u8 = 0,
    reason: u8 = 0,
    verdict: u8 = 0,
    flags: u8 = 0,
    seq: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(ExternalHoverDiagEntry) == 16);
    std.debug.assert(@alignOf(ExternalHoverDiagEntry) == 8);
}

/// Fixed 64-entry POD ring buffer, one per surface (see
/// `renderer/State.zig`'s `Mouse.external_hover_diag`). `push` is the only
/// hot-path entry point: called only while the caller already holds
/// `renderer_state.mutex` (`Surface.zig`'s setter and `generic.zig`'s
/// render loop), does no allocation, and never fails — on overflow it
/// silently discards the oldest entry and bumps `dropped_count`.
pub const ExternalHoverDiagRing = struct {
    pub const capacity: usize = 64;

    entries: [capacity]ExternalHoverDiagEntry = [_]ExternalHoverDiagEntry{.{}} ** capacity,
    /// Index of the OLDEST live entry.
    head: u32 = 0,
    /// Number of live entries, `0...capacity`.
    len: u32 = 0,
    /// Monotonic cumulative count of entries ever discarded by overflow.
    /// Never reset, never wrapped in practice (a u64 would take centuries
    /// of 64-entry overflows at any plausible hover rate); the host keeps
    /// its own previous value per surface and reports only the delta
    /// (design v4 §3.3) since the same cumulative value must never be
    /// double-reported across drains.
    dropped_count: u64 = 0,
    /// Monotonic per-push sequence number, independent of `dropped_count`
    /// — lets the host detect gaps/reordering even within one drain.
    next_seq: u32 = 0,

    /// Appends `entry` (with `seq` overwritten by the ring's own
    /// counter). Caller must already hold the renderer mutex. A no-op if
    /// the diagnostics gate is off — this is the single choke point every
    /// diagnostic append goes through, so "gate off means no ring
    /// append" (design v4 §7 guard 4) holds regardless of call site.
    pub fn push(self: *ExternalHoverDiagRing, entry: ExternalHoverDiagEntry) void {
        if (!externalHoverDiagnosticsEnabled()) return;
        self.pushUnchecked(entry);
    }

    /// The gate-free append logic `push` delegates to. Exposed
    /// separately so ring-behavior unit tests (FIFO/wrap/overflow) can
    /// exercise it independent of the process-memoized diagnostics gate
    /// (`externalHoverDiagnosticsEnabled`'s cached value can't be reset
    /// mid test-binary once another test has resolved it) — every real
    /// production call site goes through `push`, never this directly.
    pub fn pushUnchecked(self: *ExternalHoverDiagRing, entry: ExternalHoverDiagEntry) void {
        var e = entry;
        e.seq = self.next_seq;
        self.next_seq +%= 1;
        if (self.len == capacity) {
            // Overflow: drop the oldest entry, which is exactly the slot
            // we're about to overwrite.
            self.head = (self.head + 1) % @as(u32, capacity);
            self.dropped_count +%= 1;
        } else {
            self.len += 1;
        }
        const write_index = (self.head + self.len - 1) % @as(u32, capacity);
        self.entries[write_index] = e;
    }

    /// Destructively drains up to `out.len` of the oldest live entries
    /// into `out`, advancing `head` and decrementing `len` by exactly the
    /// number copied. Entries beyond `out.len` are left in the ring (NOT
    /// discarded) — the caller can call again to continue draining. Only
    /// ever call while holding the renderer mutex; unlocking, enum
    /// decoding, string formation, and logging must all happen strictly
    /// after this returns (design v4 §3.3).
    pub fn drain(self: *ExternalHoverDiagRing, out: []ExternalHoverDiagEntry) usize {
        const n: u32 = @intCast(@min(out.len, self.len));
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            out[i] = self.entries[(self.head + i) % @as(u32, capacity)];
        }
        self.head = (self.head + n) % @as(u32, capacity);
        self.len -= n;
        return n;
    }
};

test "ExternalHoverDiagEntry is a 16-byte, 8-byte-aligned POD" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ExternalHoverDiagEntry));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(ExternalHoverDiagEntry));
}

// Raw discriminant values cross the C ABI (`include/ghostty.h`'s
// `ghostty_external_hover_diag_entry_s`'s `source`/`reason`/`verdict`
// bytes) and are decoded by the host's own copy of these enums —
// reordering a variant would silently reinterpret every already-shipped
// entry as a different meaning. Pin them.
test "ExternalHoverDiagSource/Reason/Verdict raw values are pinned (host ABI stability)" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ExternalHoverDiagSource.setter));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ExternalHoverDiagSource.input));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ExternalHoverDiagSource.render));

    try testing.expectEqual(@as(u8, 0), @intFromEnum(ExternalHoverDiagReason.none));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ExternalHoverDiagReason.zeroRowCount));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ExternalHoverDiagReason.hoverIneligible));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ExternalHoverDiagReason.scopeOutOfBounds));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ExternalHoverDiagReason.snapshotBuildFailed));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(ExternalHoverDiagReason.pointerMissing));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(ExternalHoverDiagReason.pointerNotInRanges));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(ExternalHoverDiagReason.rangeCountExceeded));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(ExternalHoverDiagReason.rangeOutOfScope));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(ExternalHoverDiagReason.rangeEmptyOrInverted));
    try testing.expectEqual(@as(u8, 10), @intFromEnum(ExternalHoverDiagReason.cellBudgetExceeded));
    try testing.expectEqual(@as(u8, 11), @intFromEnum(ExternalHoverDiagReason.viewportExit));
    try testing.expectEqual(@as(u8, 12), @intFromEnum(ExternalHoverDiagReason.renderQueueFailed));

    try testing.expectEqual(@as(u8, 0), @intFromEnum(ExternalHoverDiagVerdict.none));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(ExternalHoverDiagVerdict.valid));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(ExternalHoverDiagVerdict.osc8Present));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(ExternalHoverDiagVerdict.hoverIneligible));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(ExternalHoverDiagVerdict.scopeOutOfBounds));
    try testing.expectEqual(@as(u8, 5), @intFromEnum(ExternalHoverDiagVerdict.pointerMissing));
    try testing.expectEqual(@as(u8, 6), @intFromEnum(ExternalHoverDiagVerdict.pointerNotInRanges));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(ExternalHoverDiagVerdict.viewportExit));
    try testing.expectEqual(@as(u8, 8), @intFromEnum(ExternalHoverDiagVerdict.physicalTokenMismatch));
    try testing.expectEqual(@as(u8, 9), @intFromEnum(ExternalHoverDiagVerdict.contextEpochMismatch));
    try testing.expectEqual(@as(u8, 10), @intFromEnum(ExternalHoverDiagVerdict.snapshotBuildFailed));
    try testing.expectEqual(@as(u8, 11), @intFromEnum(ExternalHoverDiagVerdict.renderQueueFailed));
}

test "ExternalHoverDiagRing.pushUnchecked appends in FIFO order; drain returns oldest first" {
    const testing = std.testing;
    var ring: ExternalHoverDiagRing = .{};

    ring.pushUnchecked(.{ .event = 1 });
    ring.pushUnchecked(.{ .event = 2 });
    ring.pushUnchecked(.{ .event = 3 });
    try testing.expectEqual(@as(u32, 3), ring.len);

    var out: [2]ExternalHoverDiagEntry = undefined;
    try testing.expectEqual(@as(usize, 2), ring.drain(&out));
    try testing.expectEqual(@as(u64, 1), out[0].event);
    try testing.expectEqual(@as(u64, 2), out[1].event);
    try testing.expectEqual(@as(u32, 1), ring.len);

    // The remainder (event 3) is still there for a follow-up drain.
    try testing.expectEqual(@as(usize, 1), ring.drain(&out));
    try testing.expectEqual(@as(u64, 3), out[0].event);
    try testing.expectEqual(@as(u32, 0), ring.len);
}

test "ExternalHoverDiagRing.pushUnchecked assigns a monotonic per-entry seq" {
    const testing = std.testing;
    var ring: ExternalHoverDiagRing = .{};
    ring.pushUnchecked(.{ .event = 10 });
    ring.pushUnchecked(.{ .event = 20 });

    var out: [2]ExternalHoverDiagEntry = undefined;
    try testing.expectEqual(@as(usize, 2), ring.drain(&out));
    try testing.expectEqual(@as(u32, 0), out[0].seq);
    try testing.expectEqual(@as(u32, 1), out[1].seq);
}

test "ExternalHoverDiagRing.pushUnchecked wraps head/write-index around capacity" {
    const testing = std.testing;
    var ring: ExternalHoverDiagRing = .{};

    // Fill, drain most of it, then push more — this exercises a
    // write-index/head that has wrapped past the physical array's end,
    // not just a ring that has never wrapped.
    for (0..ExternalHoverDiagRing.capacity) |i| {
        ring.pushUnchecked(.{ .event = @intCast(i) });
    }
    var out: [ExternalHoverDiagRing.capacity - 4]ExternalHoverDiagEntry = undefined;
    try testing.expectEqual(out.len, ring.drain(&out));
    try testing.expectEqual(@as(u32, 4), ring.len);

    // head now sits at index (capacity - 4) mod capacity; the next
    // several pushes wrap the physical write index around the array.
    for (0..10) |i| {
        ring.pushUnchecked(.{ .event = 1000 + @as(u64, i) });
    }
    try testing.expectEqual(@as(u32, 14), ring.len);

    var out2: [14]ExternalHoverDiagEntry = undefined;
    try testing.expectEqual(out2.len, ring.drain(&out2));
    // The 4 originally-remaining entries (events capacity-4..capacity-1)
    // must still come out FIRST, in order, ahead of the 10 new ones.
    for (0..4) |i| {
        try testing.expectEqual(@as(u64, ExternalHoverDiagRing.capacity - 4 + i), out2[i].event);
    }
    for (0..10) |i| {
        try testing.expectEqual(@as(u64, 1000 + i), out2[4 + i].event);
    }
}

test "ExternalHoverDiagRing.pushUnchecked overflow drops the oldest entry and bumps dropped_count once per drop" {
    const testing = std.testing;
    var ring: ExternalHoverDiagRing = .{};

    for (0..ExternalHoverDiagRing.capacity) |i| {
        ring.pushUnchecked(.{ .event = @intCast(i) });
    }
    try testing.expectEqual(@as(u64, 0), ring.dropped_count);
    try testing.expectEqual(@as(u32, ExternalHoverDiagRing.capacity), ring.len);

    // One more push over a full ring: oldest (event 0) is dropped, len
    // stays saturated at capacity, dropped_count bumps by exactly 1.
    ring.pushUnchecked(.{ .event = 9999 });
    try testing.expectEqual(@as(u64, 1), ring.dropped_count);
    try testing.expectEqual(@as(u32, ExternalHoverDiagRing.capacity), ring.len);

    var out: [ExternalHoverDiagRing.capacity]ExternalHoverDiagEntry = undefined;
    try testing.expectEqual(out.len, ring.drain(&out));
    // event 0 is gone; event 1 is now the oldest survivor, and the new
    // push (9999) is the newest entry.
    try testing.expectEqual(@as(u64, 1), out[0].event);
    try testing.expectEqual(@as(u64, 9999), out[out.len - 1].event);

    // Overflowing a second time bumps dropped_count again — the host
    // computes its own delta across drains, but the ring's own
    // cumulative counter itself must never reset or double-count a
    // single drop.
    for (0..ExternalHoverDiagRing.capacity) |i| {
        ring.pushUnchecked(.{ .event = @intCast(i) });
    }
    ring.pushUnchecked(.{ .event = 8888 });
    try testing.expectEqual(@as(u64, 2), ring.dropped_count);
}

test "ExternalHoverDiagRing.drain never copies more than out.len and leaves the remainder in place" {
    const testing = std.testing;
    var ring: ExternalHoverDiagRing = .{};
    ring.pushUnchecked(.{ .event = 1 });
    ring.pushUnchecked(.{ .event = 2 });
    ring.pushUnchecked(.{ .event = 3 });

    var out: [0]ExternalHoverDiagEntry = undefined;
    try testing.expectEqual(@as(usize, 0), ring.drain(&out));
    try testing.expectEqual(@as(u32, 3), ring.len);
}

// Design v4 §7 guard 4: when the diagnostics gate is off, `push` must
// not append to the ring at all. `externalHoverDiagnosticsEnabled`'s
// result is memoized process-wide on first read, so this test can't
// force the gate on/off mid test-binary — it instead pins the
// observable contract at the level every real caller actually uses
// (`push`, not `pushUnchecked`): in this test binary's environment
// (`CMUX_EXTERNAL_HOVER_DIAGNOSTICS` unset), `push` is a no-op.
test "ExternalHoverDiagRing.push is a no-op when the diagnostics gate is off" {
    const testing = std.testing;
    try testing.expect(!externalHoverDiagnosticsEnabled());
    var ring: ExternalHoverDiagRing = .{};
    ring.push(.{ .event = 42 });
    try testing.expectEqual(@as(u32, 0), ring.len);
    try testing.expectEqual(@as(u64, 0), ring.dropped_count);
}

/// Host-resolved link-hover override. When active, it owns interactive
/// hover rendering in place of Ghostty's own regex/OSC8 hover for the same
/// pointer — see `generic.zig`'s render-loop priority.
///
/// Invalidation is destructive and one-way: once `validateOrInvalidate`
/// (or the input-time `invalidateIfPointerLeftRanges`) observes an
/// invalidating condition, the state is discarded immediately, so a later
/// coincidental match of the *same* stale identity can never resurrect it
/// (ABA protection). The only way back to `active() == true` is a fresh
/// `set` call with a fresh token.
///
/// (B) flicker fix §3 (review-flicker-fix-confirm.md §2's blocking
/// finding) — `token`, `physical`, and `context_epoch` are deliberately
/// separate fields, not one opaque hash: `token` is the host-visible
/// clear/transition/ack identity ONLY (still minted from physical/
/// pointer/mods/epoch, so it's unique per activation, but never itself
/// compared for render validity); `physical` and `context_epoch` are what
/// `validateOrInvalidate` actually checks, independently, alongside live
/// range containment. An earlier revision folded pointer cell into the
/// same opaque token render validity was decided from, which made "ignore
/// cell movement within the same ranges, but still catch mods/eligibility
/// ABA" impossible to express — a real dogfood regression (indicator
/// flicker while moving along a stable, still-valid link) traced to
/// exactly that conflation.
pub const ExternalHover = struct {
    token: HoverActivationToken = HoverActivationToken.zero,
    /// Fixed scope/content/viewport identity captured at `set` time —
    /// compared against a fresh re-fingerprint every render frame
    /// (`validateOrInvalidate`), never re-derived from "the current
    /// mouse cell". Catches an in-place text rewrite or scroll under a
    /// stationary pointer, not just pointer/mods movement.
    physical: PhysicalSnapshotToken = PhysicalSnapshotToken.zero,
    /// Monotonic ABA guard for normalized mods and hover eligibility
    /// ONLY — see `hover_context_epoch`'s doc in `renderer/State.zig`. A
    /// plain in-bounds pointer/cell change never bumps the epoch that
    /// mints this, so moving between two cells inside the same `ranges`
    /// never invalidates on epoch grounds; `validateOrInvalidate`'s range
    /// check is what actually gates pointer/cell validity.
    context_epoch: u64 = 0,
    /// The physical row scope `token`/`physical` were minted over. The
    /// render loop re-reads exactly this scope every frame (never
    /// re-deriving it from the current mouse cell) to rebuild a fresh
    /// `PhysicalSnapshotToken` for `validateOrInvalidate`.
    top_row: u32 = 0,
    row_count: u32 = 0,
    ranges: [max_external_hover_ranges]ExternalHoverCellRange = undefined,
    len: u16 = 0,

    // cmux fork: (C) ExternalHover diagnostics — activation-scoped
    // bookkeeping, reset by `set`/`invalidate`, never touched by
    // `replaceCells`/`active`. `diagnostic_event` is the host's
    // `host_event_id` for the setter call that created this activation
    // (design v4 §1's correlation key's `event` half — `surfaceSerial` is
    // a host-only addition, never stored here). Left at 0 whenever the
    // diagnostics gate is off, so a gate-off activation never leaks an
    // event id even if the gate flips on mid-activation.
    diagnostic_event: u64 = 0,
    /// Whether `recordRenderVerdict` has already emitted a render-verdict
    /// entry for this activation — the first one always fires regardless
    /// of verdict; only the 2nd-and-later repeat of the SAME verdict is
    /// suppressed (design v4 §4).
    diag_emitted_first_verdict: bool = false,
    /// Raw `ExternalHoverDiagVerdict` of the last verdict actually
    /// emitted (or `.none` before any has been). Compared, not
    /// re-derived, so a verdict change (even between two "invalid"
    /// reasons) always emits.
    diag_last_verdict: u8 = @intFromEnum(ExternalHoverDiagVerdict.none),

    pub fn active(self: *const ExternalHover) bool {
        return self.len > 0;
    }

    /// Pushes a `source=render` diagnostic entry for `verdict` unless
    /// this activation already emitted this exact verdict (2nd-and-later
    /// frame suppression — design v4 §4). A no-op if no activation is
    /// active (`len == 0`) — there is nothing to attribute a render
    /// verdict to. Must be called BEFORE any subsequent `invalidate()`,
    /// since `invalidate()` zeroes `diagnostic_event`/the emitted-verdict
    /// bookkeeping this reads (design v4 §7 guard 2/3: determine the
    /// structured verdict before mutating state, never re-infer after).
    pub fn recordRenderVerdict(
        self: *ExternalHover,
        ring: *ExternalHoverDiagRing,
        verdict: ExternalHoverDiagVerdict,
    ) void {
        if (!self.active()) return;
        const first = !self.diag_emitted_first_verdict;
        const verdict_raw = @intFromEnum(verdict);
        const suppress = !first and self.diag_last_verdict == verdict_raw;
        if (!suppress) {
            ring.push(.{
                .event = self.diagnostic_event,
                .source = @intFromEnum(ExternalHoverDiagSource.render),
                .verdict = verdict_raw,
                .flags = if (first) external_hover_diag_flag_first_for_activation else 0,
            });
        }
        self.diag_emitted_first_verdict = true;
        self.diag_last_verdict = verdict_raw;
    }

    /// Returns whether `self` is still valid, independently checking
    /// (review §2's required split, all four independent — see the type
    /// doc):
    ///
    /// 1. `current_pointer` is non-null and inside `self.ranges`.
    /// 2. `current_physical` matches `self.physical`.
    /// 3. `current_context_epoch` matches `self.context_epoch`.
    /// 4. `hover_eligible == true`.
    ///
    /// (OSC8 priority — review's independent condition 5 — is the
    /// existing, unchanged destructive `invalidate()` call the render
    /// loop already makes BEFORE ever reaching this check when an OSC8
    /// link is present this frame; it is not re-checked here.)
    ///
    /// Any failure destructively invalidates before returning — see the
    /// type doc for why this must be one-way.
    ///
    /// (C) diagnostics — returns the single structured
    /// `ExternalHoverDiagVerdict` this call determined (`.none` if there
    /// was no activation to validate), reused for BOTH the production
    /// accept/reject decision and the diagnostic entry `recordVerdict`
    /// pushes — never re-derived after the fact (design v4 §7 guards
    /// 1/2). The check order below (pointer-null, then eligibility,
    /// ranges, physical, epoch) is behavior-identical to the prior
    /// combined OR-check: accept/reject depends only on whether ANY
    /// check fails, never on which one is checked first — the order only
    /// picks which single reason is reported when more than one would
    /// fail simultaneously.
    pub fn validateOrInvalidate(
        self: *ExternalHover,
        current_pointer: ?point.Coordinate,
        current_physical: PhysicalSnapshotToken,
        current_context_epoch: u64,
        hover_eligible: bool,
        diag: *ExternalHoverDiagRing,
    ) ExternalHoverDiagVerdict {
        if (self.len == 0) return .none;
        const verdict: ExternalHoverDiagVerdict = verdict: {
            const cell = current_pointer orelse break :verdict .pointerMissing;
            if (!hover_eligible) break :verdict .hoverIneligible;
            if (!rangesContainCell(self.ranges[0..self.len], cell)) break :verdict .pointerNotInRanges;
            if (!self.physical.eql(current_physical)) break :verdict .physicalTokenMismatch;
            if (self.context_epoch != current_context_epoch) break :verdict .contextEpochMismatch;
            break :verdict .valid;
        };
        self.recordRenderVerdict(diag, verdict);
        if (verdict != .valid) self.invalidate();
        return verdict;
    }

    /// (B) flicker fix §1 — the input-time counterpart to
    /// `validateOrInvalidate`'s render-time check. Destructively
    /// invalidates immediately if active and `new_pointer_cell` is
    /// outside `self.ranges` (or `null`, i.e. viewport exit), rather than
    /// waiting for the next render frame — mouse events and render frames
    /// aren't 1:1, so a render-time-only check can miss an
    /// A->outside->A sequence coalesced within a single frame (the exact
    /// ABA case `validateOrInvalidate`'s token-mismatch check already
    /// closes for content/scope changes, now closed for pointer movement
    /// too). Never itself checks physical/context/eligibility — those
    /// stay `validateOrInvalidate`'s job; this is pointer/ranges only.
    ///
    /// - Returns `true` if this call actually invalidated (so the caller
    ///   can conditionally mark the hover row dirty and queue a render —
    ///   see `Surface.cursorPosCallback`); `false` if already inactive or
    ///   still valid (still active and either the pointer stayed inside
    ///   `self.ranges`, or the caller is between-events with no pointer
    ///   change at all).
    ///
    /// (C) diagnostics — design v4 §7 guard 3: pushes `source=input`
    /// (`reason=viewportExit` for a `null` cell, `pointerNotInRanges`
    /// otherwise) BEFORE `invalidate()` clears the state this needs
    /// (`diagnostic_event`), never after.
    pub fn invalidateIfPointerLeftRanges(
        self: *ExternalHover,
        new_pointer_cell: ?point.Coordinate,
        diag: *ExternalHoverDiagRing,
    ) bool {
        if (!self.active()) return false;
        if (new_pointer_cell) |cell| {
            if (rangesContainCell(self.ranges[0..self.len], cell)) return false;
        }
        const reason: ExternalHoverDiagReason = if (new_pointer_cell == null)
            .viewportExit
        else
            .pointerNotInRanges;
        diag.push(.{
            .event = self.diagnostic_event,
            .source = @intFromEnum(ExternalHoverDiagSource.input),
            .reason = @intFromEnum(reason),
        });
        self.invalidate();
        return true;
    }

    /// Unconditionally discards state, regardless of token. Used when the
    /// core itself observes a competing signal (an OSC8 link present this
    /// frame) that must never coexist with a possibly-stale override.
    pub fn invalidate(self: *ExternalHover) void {
        self.token = HoverActivationToken.zero;
        self.physical = PhysicalSnapshotToken.zero;
        self.context_epoch = 0;
        self.top_row = 0;
        self.row_count = 0;
        self.len = 0;
        self.diagnostic_event = 0;
        self.diag_emitted_first_verdict = false;
        self.diag_last_verdict = @intFromEnum(ExternalHoverDiagVerdict.none);
    }

    /// Validates and stores `ranges` under `token`/`physical`/
    /// `context_epoch`/`top_row`/`row_count`. Rejects (returns `false`,
    /// state unchanged) if:
    /// - `pointer_cell` is `null` or outside `ranges` — (B) flicker fix
    ///   §1's setter-containment guard: the current pointer can have
    ///   moved between the host's currentness check and this call, so
    ///   the setter itself must re-verify, not just trust the caller.
    /// - the range count or total cell count exceeds the bounds above.
    /// - any range is empty/inverted, or falls outside `[top_row, top_row
    ///   + row_count)`.
    ///
    /// Ranges are assumed ordered and non-overlapping by the caller; this
    /// does not itself check for overlap (the render-time defensive
    /// bounds check in `replaceCells` only needs per-range validity, not
    /// global non-overlap, to stay safe).
    ///
    /// (C) diagnostics — returns the single structured
    /// `ExternalHoverDiagReason` (`.none` on success), reused for BOTH
    /// the production accept/reject decision and the diagnostic entry the
    /// caller (`Surface.setExternalLinkHover`) pushes on rejection — see
    /// design v4 §7 guard 1. `event` is `host_event_id` from the C ABI
    /// (design v4 §2); stored into `diagnostic_event` only when the
    /// diagnostics gate is on (received but not stored when off), and the
    /// activation's verdict-suppression bookkeeping is reset regardless
    /// (design v4 §4's "setter accepted 時に diagnosticEvent と
    /// lastVerdict を同時に設定").
    pub fn set(
        self: *ExternalHover,
        token: HoverActivationToken,
        physical: PhysicalSnapshotToken,
        context_epoch: u64,
        pointer_cell: ?point.Coordinate,
        top_row: u32,
        row_count: u32,
        ranges: []const ExternalHoverCellRange,
        event: u64,
    ) ExternalHoverDiagReason {
        if (ranges.len > max_external_hover_ranges) return .rangeCountExceeded;
        const cell = pointer_cell orelse return .pointerMissing;
        if (!rangesContainCell(ranges, cell)) return .pointerNotInRanges;
        var total: u32 = 0;
        for (ranges) |r| {
            // r.row is an absolute viewport row (see replaceCells, which
            // draws it directly with no top_row offset) — reject any range
            // that doesn't actually fall within the scope this call is
            // claiming.
            if (r.row < top_row or r.row >= top_row + row_count) return .rangeOutOfScope;
            if (r.start_column >= r.end_column) return .rangeEmptyOrInverted;
            const width = @as(u32, r.end_column) - r.start_column;
            if (width > max_external_hover_cells - total) return .cellBudgetExceeded;
            total += width;
        }
        self.token = token;
        self.physical = physical;
        self.context_epoch = context_epoch;
        self.top_row = top_row;
        self.row_count = row_count;
        self.len = @intCast(ranges.len);
        @memcpy(self.ranges[0..ranges.len], ranges);
        self.diagnostic_event = if (externalHoverDiagnosticsEnabled()) event else 0;
        self.diag_emitted_first_verdict = false;
        self.diag_last_verdict = @intFromEnum(ExternalHoverDiagVerdict.none);
        return .none;
    }

    /// Replaces `result`'s contents with this override's cells, re-checking
    /// each range against the *current* grid bounds (`rows`/`cols`) even
    /// though `set` already validated shape — a resize between `set` and
    /// this render could otherwise let a stale range read past the grid.
    /// A no-op (result cleared, nothing added) when inactive.
    pub fn replaceCells(
        self: *const ExternalHover,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        rows: terminal.size.CellCountInt,
        cols: terminal.size.CellCountInt,
    ) Allocator.Error!void {
        result.clearRetainingCapacity();
        if (!self.active()) return;
        for (self.ranges[0..self.len]) |range| {
            if (range.row >= rows) continue;
            if (range.end_column > cols) continue;
            if (range.start_column >= range.end_column) continue;
            for (range.start_column..range.end_column) |column| {
                try result.put(alloc, .{ .x = @intCast(column), .y = range.row }, {});
            }
        }
    }
};

/// The value snapshot a render pass hands off to the renderer thread for
/// out-of-mutex apprt delivery — see `generic.zig`'s render loop and
/// `Thread.notifyExternalHoverTransition` (mirrors the existing
/// `notifySelectionChanged` precedent: mutex-protected code only ever
/// writes a plain value here, never calls into the apprt itself).
pub const ExternalHoverTransition = struct {
    token: HoverActivationToken,
    active: bool,
};

/// A single-byte discriminant for the active screen (primary/alternate),
/// used consistently by both `Surface.setExternalLinkHover` and
/// `generic.zig`'s per-frame re-fingerprint so the two sides of a
/// `PhysicalSnapshotToken` comparison always agree on this bit.
pub fn externalHoverScreenKeyByte(key: terminal.ScreenSet.Key) u8 {
    return switch (key) {
        .primary => 0,
        .alternate => 1,
    };
}

test "physical snapshot token differs on content, scope, screen identity, or viewport" {
    const testing = std.testing;
    const base = buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abc", 0, 0).?;

    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abd", 0, 0).?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 0, 0, 6, 1, "abc", 0, 0).?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 1, 0, 5, 1, "abc", 0, 0).?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(2, 0, 0, 5, 1, "abc", 0, 0).?));
    // (B) flicker fix §4 — same content/scope/screen identity, different
    // viewport identity (row-space revision, offset) must still differ.
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abc", 1, 0).?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abc", 0, 1).?));
    try testing.expect(base.eql(buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abc", 0, 0).?));
}

test "physical snapshot token rejects rows or columns past the bound" {
    const oversized_text = [_]u8{'a'} ** (max_snapshot_rows * max_snapshot_row_columns + 1);
    try std.testing.expect(buildPhysicalSnapshotToken(1, 0, 0, 0, 1, &oversized_text, 0, 0) == null);
    try std.testing.expect(buildPhysicalSnapshotToken(1, 0, 0, 0, max_snapshot_rows + 1, "", 0, 0) == null);
    try std.testing.expect(buildPhysicalSnapshotToken(1, 0, 0, 0, 0, "", 0, 0) == null);
}

test "hover activation token differs on pointer cell, mods, or epoch" {
    const testing = std.testing;
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 2, 3, 4 } };
    const cell: point.Coordinate = .{ .x = 2, .y = 3 };

    const base = buildHoverActivationToken(physical, cell, 0, 10);
    try testing.expect(base.eql(buildHoverActivationToken(physical, cell, 0, 10)));
    try testing.expect(!base.eql(buildHoverActivationToken(physical, .{ .x = 3, .y = 3 }, 0, 10)));
    try testing.expect(!base.eql(buildHoverActivationToken(physical, cell, 1, 10)));
    try testing.expect(!base.eql(buildHoverActivationToken(physical, cell, 0, 11)));
    try testing.expect(!base.eql(buildHoverActivationToken(physical, null, 0, 10)));
}

test "ExternalHover destructively invalidates on physical/context mismatch (ABA protection)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var hover: ExternalHover = .{};
    var diag: ExternalHoverDiagRing = .{};
    const token_a: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical_a: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical_b: PhysicalSnapshotToken = .{ .bits = .{ 2, 2, 2, 2 } };
    const cell: point.Coordinate = .{ .x = 1, .y = 0 };

    try testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token_a, physical_a, 5, cell, 0, 1, &.{.{ .row = 0, .start_column = 0, .end_column = 3 }}, 0));
    try testing.expect(hover.active());
    try testing.expectEqual(ExternalHoverDiagVerdict.valid, hover.validateOrInvalidate(cell, physical_a, 5, true, &diag));

    // A physical mismatch discards state...
    try testing.expectEqual(ExternalHoverDiagVerdict.physicalTokenMismatch, hover.validateOrInvalidate(cell, physical_b, 5, true, &diag));
    try testing.expect(!hover.active());

    // ...so a later re-observation of the *original* physical/context
    // does not resurrect it: the only way back is a fresh `set`.
    try testing.expectEqual(ExternalHoverDiagVerdict.none, hover.validateOrInvalidate(cell, physical_a, 5, true, &diag));
    try testing.expect(!hover.active());

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try hover.replaceCells(alloc, &result, 10, 10);
    try testing.expectEqual(@as(usize, 0), result.count());
}

test "ExternalHover.set rejects ranges past the count or cell bound" {
    var hover: ExternalHover = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const cell: point.Coordinate = .{ .x = 0, .y = 0 };

    // Inverted range: containment passes via the first (normal) range, so
    // the second (inverted, width 0) range is what the per-range
    // validation loop actually rejects on — a range whose containment
    // could never itself succeed can't otherwise reach the inversion
    // check at all.
    try std.testing.expectEqual(ExternalHoverDiagReason.rangeEmptyOrInverted, hover.set(token, physical, 0, cell, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
        .{ .row = 0, .start_column = 5, .end_column = 5 },
    }, 0));
    try std.testing.expect(!hover.active());

    // Total cells past the bound.
    try std.testing.expectEqual(ExternalHoverDiagReason.cellBudgetExceeded, hover.set(token, physical, 0, cell, 0, 1, &.{.{ .row = 0, .start_column = 0, .end_column = max_external_hover_cells + 1 }}, 0));
    try std.testing.expect(!hover.active());

    // Exactly at the bound succeeds.
    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical, 0, cell, 0, 1, &.{.{ .row = 0, .start_column = 0, .end_column = @intCast(max_external_hover_cells) }}, 0));
    try std.testing.expect(hover.active());
}

// cmux fork: (B) wiring review Blocking 2 — `range.row` is an absolute
// viewport row, NOT relative to `top_row` (see `replaceCells`, which uses
// `range.row` directly as the drawn cell's `.y` with no offset by
// `top_row`). A range whose row falls outside `[top_row, top_row +
// row_count)` can never legitimately belong to a scope `set` was just
// asked to claim, so it must be rejected the same way an inverted or
// oversized range already is.
test "ExternalHover.set rejects a range whose row falls outside [top_row, top_row + row_count)" {
    var hover: ExternalHover = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };

    // Scope is rows [5, 8) (top_row=5, row_count=3). Row 4 is just before
    // it, row 8 is just past it — both out of scope. The pointer used for
    // each sub-case is inside the ONE range being set, so the setter's
    // containment guard passes and the out-of-scope check is what
    // actually rejects here (not containment).
    try std.testing.expectEqual(ExternalHoverDiagReason.rangeOutOfScope, hover.set(token, physical, 0, .{ .x = 0, .y = 4 }, 5, 3, &.{.{ .row = 4, .start_column = 0, .end_column = 1 }}, 0));
    try std.testing.expect(!hover.active());
    try std.testing.expectEqual(ExternalHoverDiagReason.rangeOutOfScope, hover.set(token, physical, 0, .{ .x = 0, .y = 8 }, 5, 3, &.{.{ .row = 8, .start_column = 0, .end_column = 1 }}, 0));
    try std.testing.expect(!hover.active());

    // Every row actually inside [5, 8) succeeds — pointer at row 5, which
    // is one of the ranges being set.
    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical, 0, .{ .x = 0, .y = 5 }, 5, 3, &.{
        .{ .row = 5, .start_column = 0, .end_column = 1 },
        .{ .row = 6, .start_column = 0, .end_column = 1 },
        .{ .row = 7, .start_column = 0, .end_column = 1 },
    }, 0));
    try std.testing.expect(hover.active());
}

// cmux fork: (B) wiring review Blocking 2 — `top_row`/`row_count` are
// VIEWPORT-RELATIVE physical rows, not absolute/scrollback-inclusive
// screen rows: `Surface.setExternalLinkHover`'s bound check and the
// render loop's re-fingerprint (`generic.zig`) both pin `top_row` as
// `.viewport`. A caller (or a doc reader) who instead treated it as an
// absolute row would read/underline the wrong line the moment the
// viewport has scrolled away from the bottom. This exercises the exact
// `pages.pin(.{.viewport = ...})` lookup those call sites use, at a
// nonzero viewport scroll offset and a nonzero `top_row`, and confirms it
// tracks the viewport rather than resolving to a fixed absolute row.
test "viewport-relative row lookup tracks the viewport at a nonzero scroll offset and top_row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("line0\r\nline1\r\nline2\r\nline3\r\nline4\r\nline5\r\n");
    t.scrollViewport(.top);

    const screen = t.screens.active;
    const readViewportRow = struct {
        fn call(s: *Screen, a: std.mem.Allocator, row: u32) ![:0]const u8 {
            const top_left = s.pages.pin(.{ .viewport = .{ .x = 0, .y = row } }).?;
            const bottom_right = s.pages.pin(.{ .viewport = .{ .x = 9, .y = row } }).?;
            return s.selectionString(a, .{
                .sel = terminal.Selection.init(top_left, bottom_right, false),
                .trim = false,
                .unwrap = false,
            });
        }
    }.call;

    // top_row = 1 (nonzero) while the viewport itself sits at a nonzero
    // scroll offset (scrolled to the top of scrollback, not the bottom).
    const before = try readViewportRow(screen, alloc, 1);
    defer alloc.free(before);

    t.scrollViewport(.{ .delta = 1 });
    const after = try readViewportRow(screen, alloc, 1);
    defer alloc.free(after);

    // The SAME viewport row (1) must resolve to different content once
    // the viewport has moved — an absolute-row interpretation would have
    // returned identical text both times, since nothing at that fixed
    // absolute row changed.
    try testing.expect(!std.mem.eql(u8, before, after));
}

// design-hover-diagnostics-v4-final.md §8 — Ghostty selection read focused
// test: reads a genuinely multi-row (row_count=3) span at a NONZERO
// top_row with trim=false/unwrap=false — the exact selection shape both
// the setter's physical fingerprint (`ghostty_surface_read_text_physical_rows`)
// and `generic.zig`'s per-frame re-fingerprint read — across a hard
// newline, a blank row, and a row containing wide/combining glyphs, and
// confirms rows outside the window never leak into the result.
test "multi-row physical selection read at a nonzero top_row preserves hard newlines, blank rows, and wide/combining glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    // Row 0: plain ascii, OUTSIDE the [1, 4) window under test.
    // Row 1: plain ascii — top of the window.
    // Row 2: blank.
    // Row 3: a wide CJK glyph followed by a combining accent — bottom of
    // the window.
    // Row 4: plain ascii, OUTSIDE the window.
    stream.nextSlice("skip0\r\n" ++
        "row1\r\n" ++
        "\r\n" ++
        "\u{4E2D}e\u{0301}\r\n" ++
        "skip4\r\n");
    // Anchor the viewport at absolute row 0 — otherwise the trailing
    // `\r\n` after "skip4" scrolls row 0 ("skip0") into scrollback and
    // shifts every viewport row index down by one.
    t.scrollViewport(.top);

    const screen = t.screens.active;
    const top_row: u32 = 1;
    const row_count: u32 = 3;
    const top_left = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = top_row } }).?;
    const bottom_right = screen.pages.pin(.{ .viewport = .{ .x = 9, .y = top_row + row_count - 1 } }).?;
    const text = try screen.selectionString(alloc, .{
        .sel = terminal.Selection.init(top_left, bottom_right, false),
        .trim = false,
        .unwrap = false,
    });
    defer alloc.free(text);

    // Exactly `row_count` physical rows, one newline per row boundary
    // (not unwrapped/joined) — the host's downstream split step
    // (`splitPhysicalViewportRows`) depends on this exact shape.
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_count: usize = 0;
    var saw_row1 = false;
    var saw_blank = false;
    var saw_wide_combining = false;
    while (lines.next()) |line| {
        line_count += 1;
        if (std.mem.indexOf(u8, line, "row1") != null) saw_row1 = true;
        if (std.mem.trim(u8, line, " ").len == 0) saw_blank = true;
        if (std.mem.indexOf(u8, line, "\u{4E2D}") != null and
            std.mem.indexOf(u8, line, "\u{0301}") != null) saw_wide_combining = true;
    }
    try testing.expectEqual(@as(usize, row_count), line_count);
    try testing.expect(saw_row1);
    try testing.expect(saw_blank);
    try testing.expect(saw_wide_combining);
    try testing.expect(std.mem.indexOf(u8, text, "skip0") == null);
    try testing.expect(std.mem.indexOf(u8, text, "skip4") == null);
}

test "ExternalHover.replaceCells re-validates ranges against current grid bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var hover: ExternalHover = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    // Set while the grid was still 10x10.
    try testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical, 0, .{ .x = 0, .y = 2 }, 0, 10, &.{
        .{ .row = 2, .start_column = 0, .end_column = 5 },
        .{ .row = 9, .start_column = 0, .end_column = 5 }, // will be out of bounds after "resize"
    }, 0));

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);

    // A resize down to 5 rows makes the second range stale; replaceCells
    // must silently drop it rather than reading past the grid.
    try hover.replaceCells(alloc, &result, 5, 10);
    try testing.expect(result.contains(.{ .x = 0, .y = 2 }));
    try testing.expect(!result.contains(.{ .x = 0, .y = 9 }));
}

// impl-flicker-fix — review-flicker-fix-confirm.md §5's required tests
// (items 1-11 for Ghostty pure/core; items 3-4 landed as
// `Mouse.updateExternalHoverPointerCell` tests in `renderer/State.zig`,
// since they need `pointer_cell` state a bare `ExternalHover` doesn't
// carry on its own).

// 2. A 2-row candidate: the pointer moving from the upper row's range to
// the lower row's range (still the SAME resolved link, same physical/
// context) must stay valid — this is exactly what makes a hard-wrapped
// path's underline+indicator stable while the pointer travels its full
// length.
test "ExternalHover.validateOrInvalidate stays valid moving from a 2-row candidate's upper range to its lower range" {
    var hover: ExternalHover = .{};
    var diag: ExternalHoverDiagRing = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 2, 3, 4 } };
    const upper: point.Coordinate = .{ .x = 5, .y = 0 };
    const lower: point.Coordinate = .{ .x = 2, .y = 1 };

    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical, 7, upper, 0, 2, &.{
        .{ .row = 0, .start_column = 0, .end_column = 10 },
        .{ .row = 1, .start_column = 0, .end_column = 5 },
    }, 0));

    try std.testing.expectEqual(ExternalHoverDiagVerdict.valid, hover.validateOrInvalidate(lower, physical, 7, true, &diag));
    try std.testing.expect(hover.active());
}

// 5. Setter-time containment: `set` itself rejects when the pointer is
// outside the ranges being claimed, independent of every other guard
// (shape, count, cell bound) already covered above.
test "ExternalHover.set rejects when the current pointer is outside the ranges being claimed" {
    var hover: ExternalHover = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };

    // Pointer at (9, 9) — nowhere near the range being claimed.
    try std.testing.expectEqual(ExternalHoverDiagReason.pointerNotInRanges, hover.set(token, physical, 0, .{ .x = 9, .y = 9 }, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));
    try std.testing.expect(!hover.active());

    // No pointer at all (viewport exit at the exact moment of the call).
    try std.testing.expectEqual(ExternalHoverDiagReason.pointerMissing, hover.set(token, physical, 0, null, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));
    try std.testing.expect(!hover.active());
}

// 6. mods A->B->A without any render-time validation in between: the
// context epoch bumped by the B transition must not equal the ORIGINAL
// epoch just because mods returned to their original value — the caller
// (`Surface.modsChanged`) bumps monotonically on every real mods change,
// never decrementing back.
test "ExternalHover.validateOrInvalidate rejects a stale context epoch after mods A->B->A" {
    var hover: ExternalHover = .{};
    var diag: ExternalHoverDiagRing = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const cell: point.Coordinate = .{ .x = 0, .y = 0 };

    // Minted at epoch 5 (mods "A").
    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical, 5, cell, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));

    // mods change to "B" bumps the epoch to 6, then back to "A" bumps it
    // AGAIN to 7 (monotonic, never restored to the original 5) — neither
    // intermediate epoch, nor the "back to A" epoch, equals the ORIGINAL
    // epoch 5 this override was minted under.
    try std.testing.expectEqual(ExternalHoverDiagVerdict.contextEpochMismatch, hover.validateOrInvalidate(cell, physical, 7, true, &diag));
    try std.testing.expect(!hover.active());
}

// 7. eligibility true->false->true without any render-time validation in
// between: the old state must not revive just because eligibility
// happened to return to `true` — `validateOrInvalidate` destructively
// invalidates the FIRST time it observes `hover_eligible == false`,
// which review's own final-spec table also requires as an immediate
// render guard, not merely a deferred one.
test "ExternalHover.validateOrInvalidate does not revive old state after eligibility true->false->true" {
    var hover: ExternalHover = .{};
    var diag: ExternalHoverDiagRing = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const cell: point.Coordinate = .{ .x = 0, .y = 0 };

    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical, 0, cell, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));

    // Eligibility drops — destructively invalidates immediately.
    try std.testing.expectEqual(ExternalHoverDiagVerdict.hoverIneligible, hover.validateOrInvalidate(cell, physical, 0, false, &diag));
    try std.testing.expect(!hover.active());

    // Eligibility returns to true, same cell/physical/epoch as before —
    // still must not revive; only a fresh `set` can reactivate.
    try std.testing.expectEqual(ExternalHoverDiagVerdict.none, hover.validateOrInvalidate(cell, physical, 0, true, &diag));
    try std.testing.expect(!hover.active());
}

// 8. Scope content change (a physical mismatch) still invalidates, same
// as before this fix — `validateOrInvalidate` independently checks
// physical identity as one of its four conditions. (Screen switch,
// resize-bounds failure, and OSC8 priority are exercised by
// `generic.zig`'s own unchanged destructive-invalidate call sites, not
// re-tested here — they were never part of this fix's diff.)
test "ExternalHover.validateOrInvalidate invalidates on a physical (scope/content) mismatch" {
    var hover: ExternalHover = .{};
    var diag: ExternalHoverDiagRing = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical_a: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical_b: PhysicalSnapshotToken = .{ .bits = .{ 2, 2, 2, 2 } };
    const cell: point.Coordinate = .{ .x = 0, .y = 0 };

    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(token, physical_a, 0, cell, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));
    try std.testing.expectEqual(ExternalHoverDiagVerdict.physicalTokenMismatch, hover.validateOrInvalidate(cell, physical_b, 0, true, &diag));
    try std.testing.expect(!hover.active());
}

// 11. A stale `clearExternalLinkHover(oldToken)` must not clear a NEWER
// active token — `Surface.clearExternalLinkHover`'s existing guard
// (`if (!self.renderer_state.mouse.external_hover.token.eql(token))
// return;`) is unchanged by this fix; this pins that contract directly
// against `ExternalHover.token`, the one field this fix deliberately
// keeps as the host-visible clear identity (see the type's doc).
test "a clear for a token that is no longer the active owner is a no-op (existing contract)" {
    var hover: ExternalHover = .{};
    const old_token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const new_token: HoverActivationToken = .{ .bits = .{ 2, 2, 2, 2 } };
    const physical: PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const cell: point.Coordinate = .{ .x = 0, .y = 0 };

    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(old_token, physical, 0, cell, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));
    // A newer activation replaces it (mirroring a fresh `set` for a
    // different candidate/token, the way the real host clear/set flow
    // would produce a "new owner" between an old clear request being
    // issued and actually processed).
    try std.testing.expectEqual(ExternalHoverDiagReason.none, hover.set(new_token, physical, 0, cell, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }, 0));

    // The exact guard `Surface.clearExternalLinkHover` applies before
    // ever calling `invalidate()`.
    if (hover.active() and hover.token.eql(old_token)) hover.invalidate();

    try std.testing.expect(hover.active());
    try std.testing.expect(hover.token.eql(new_token));
}
