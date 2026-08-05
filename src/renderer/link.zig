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
pub fn buildPhysicalSnapshotToken(
    surface_id: u64,
    screen_key_byte: u8,
    screen_generation: usize,
    top_row: u32,
    row_count: u32,
    joined_physical_rows_text: []const u8,
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

/// Host-resolved link-hover override. When active, it owns interactive
/// hover rendering in place of Ghostty's own regex/OSC8 hover for the same
/// pointer — see `generic.zig`'s render-loop priority.
///
/// Invalidation is destructive and one-way: once `validateOrInvalidate`
/// observes a token mismatch, the state is discarded immediately, so a
/// later coincidental match of the *same* stale token can never resurrect
/// it (ABA protection). The only way back to `active() == true` is a fresh
/// `set` call with a fresh token.
pub const ExternalHover = struct {
    token: HoverActivationToken = HoverActivationToken.zero,
    /// The physical row scope `token` was minted over. The render loop
    /// re-reads exactly this scope every frame (never re-deriving it from
    /// the current mouse cell) to rebuild a fresh `HoverActivationToken`
    /// for `validateOrInvalidate` — this is what catches an in-place text
    /// rewrite under a stationary pointer, not just pointer/mods movement.
    top_row: u32 = 0,
    row_count: u32 = 0,
    ranges: [max_external_hover_ranges]ExternalHoverCellRange = undefined,
    len: u16 = 0,

    pub fn active(self: *const ExternalHover) bool {
        return self.len > 0;
    }

    /// Returns whether `self` is still valid for `current`. A mismatch
    /// (including "already inactive") clears `self` before returning
    /// false — see the type doc for why this must be destructive.
    pub fn validateOrInvalidate(self: *ExternalHover, current: HoverActivationToken) bool {
        if (self.len == 0) return false;
        if (!self.token.eql(current)) {
            self.invalidate();
            return false;
        }
        return true;
    }

    /// Unconditionally discards state, regardless of token. Used when the
    /// core itself observes a competing signal (an OSC8 link present this
    /// frame) that must never coexist with a possibly-stale override.
    pub fn invalidate(self: *ExternalHover) void {
        self.token = HoverActivationToken.zero;
        self.top_row = 0;
        self.row_count = 0;
        self.len = 0;
    }

    /// Validates and stores `ranges` under `token`/`top_row`/`row_count`.
    /// Rejects (returns `false`, state unchanged) if the range count or
    /// total cell count exceeds the bounds above, or if any range is
    /// empty/inverted. Ranges are assumed ordered and non-overlapping by
    /// the caller; this does not itself check for overlap (the render-time
    /// defensive bounds check in `replaceCells` only needs per-range
    /// validity, not global non-overlap, to stay safe).
    pub fn set(
        self: *ExternalHover,
        token: HoverActivationToken,
        top_row: u32,
        row_count: u32,
        ranges: []const ExternalHoverCellRange,
    ) bool {
        if (ranges.len > max_external_hover_ranges) return false;
        var total: u32 = 0;
        for (ranges) |r| {
            if (r.start_column >= r.end_column) return false;
            const width = @as(u32, r.end_column) - r.start_column;
            if (width > max_external_hover_cells - total) return false;
            total += width;
        }
        self.token = token;
        self.top_row = top_row;
        self.row_count = row_count;
        self.len = @intCast(ranges.len);
        @memcpy(self.ranges[0..ranges.len], ranges);
        return true;
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

test "physical snapshot token differs on content, scope, or screen identity" {
    const testing = std.testing;
    const base = buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abc").?;

    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abd").?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 0, 0, 6, 1, "abc").?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(1, 1, 0, 5, 1, "abc").?));
    try testing.expect(!base.eql(buildPhysicalSnapshotToken(2, 0, 0, 5, 1, "abc").?));
    try testing.expect(base.eql(buildPhysicalSnapshotToken(1, 0, 0, 5, 1, "abc").?));
}

test "physical snapshot token rejects rows or columns past the bound" {
    const oversized_text = [_]u8{'a'} ** (max_snapshot_rows * max_snapshot_row_columns + 1);
    try std.testing.expect(buildPhysicalSnapshotToken(1, 0, 0, 0, 1, &oversized_text) == null);
    try std.testing.expect(buildPhysicalSnapshotToken(1, 0, 0, 0, max_snapshot_rows + 1, "") == null);
    try std.testing.expect(buildPhysicalSnapshotToken(1, 0, 0, 0, 0, "") == null);
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

test "ExternalHover destructively invalidates on mismatch (ABA protection)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var hover: ExternalHover = .{};
    const token_a: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const token_b: HoverActivationToken = .{ .bits = .{ 2, 2, 2, 2 } };

    try testing.expect(hover.set(token_a, 0, 1, &.{.{ .row = 0, .start_column = 0, .end_column = 3 }}));
    try testing.expect(hover.active());
    try testing.expect(hover.validateOrInvalidate(token_a));

    // A mismatch discards state...
    try testing.expect(!hover.validateOrInvalidate(token_b));
    try testing.expect(!hover.active());

    // ...so a later re-observation of the *original* token does not
    // resurrect it: the only way back is a fresh `set`.
    try testing.expect(!hover.validateOrInvalidate(token_a));
    try testing.expect(!hover.active());

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try hover.replaceCells(alloc, &result, 10, 10);
    try testing.expectEqual(@as(usize, 0), result.count());
}

test "ExternalHover.set rejects ranges past the count or cell bound" {
    var hover: ExternalHover = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };

    // Inverted range.
    try std.testing.expect(!hover.set(token, 0, 1, &.{.{ .row = 0, .start_column = 5, .end_column = 5 }}));
    try std.testing.expect(!hover.active());

    // Total cells past the bound.
    try std.testing.expect(!hover.set(token, 0, 1, &.{.{ .row = 0, .start_column = 0, .end_column = max_external_hover_cells + 1 }}));
    try std.testing.expect(!hover.active());

    // Exactly at the bound succeeds.
    try std.testing.expect(hover.set(token, 0, 1, &.{.{ .row = 0, .start_column = 0, .end_column = @intCast(max_external_hover_cells) }}));
    try std.testing.expect(hover.active());
}

test "ExternalHover.replaceCells re-validates ranges against current grid bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var hover: ExternalHover = .{};
    const token: HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    // Set while the grid was still 10x10.
    try testing.expect(hover.set(token, 0, 10, &.{
        .{ .row = 2, .start_column = 0, .end_column = 5 },
        .{ .row = 9, .start_column = 0, .end_column = 5 }, // will be out of bounds after "resize"
    }));

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);

    // A resize down to 5 rows makes the second range stale; replaceCells
    // must silently drop it rather than reading past the grid.
    try hover.replaceCells(alloc, &result, 5, 10);
    try testing.expect(result.contains(.{ .x = 0, .y = 2 }));
    try testing.expect(!result.contains(.{ .x = 0, .y = 9 }));
}
