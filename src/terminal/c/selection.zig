const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const formatterpkg = @import("../formatter.zig");
const grid_ref = @import("grid_ref.zig");
const point = @import("../point.zig");
const selection_codepoints = @import("../selection_codepoints.zig");
const Selection = @import("../Selection.zig");
const ScreenSearch = @import("../search.zig").Screen;
const Result = @import("result.zig").Result;
const terminal_c = @import("terminal.zig");

const log = std.log.scoped(.selection_c);

pub const Adjustment = Selection.Adjustment;
pub const Order = Selection.Order;
pub const Format = formatterpkg.Format;

/// C: GhosttySelection
pub const CSelection = extern struct {
    size: usize = @sizeOf(CSelection),
    start: grid_ref.CGridRef,
    end: grid_ref.CGridRef,
    rectangle: bool = false,

    pub fn toZig(self: CSelection) ?Selection {
        const start_pin = self.start.toPin() orelse return null;
        const end_pin = self.end.toPin() orelse return null;
        return Selection.init(start_pin, end_pin, self.rectangle);
    }

    pub fn fromZig(sel: Selection) CSelection {
        return .{
            .start = .fromPin(sel.start()),
            .end = .fromPin(sel.end()),
            .rectangle = sel.rectangle,
        };
    }
};

/// C: GhosttyTerminalSelectWordOptions
pub const SelectWordOptions = extern struct {
    size: usize = @sizeOf(SelectWordOptions),
    ref: grid_ref.CGridRef,
    boundary_codepoints: ?[*]const u32 = null,
    boundary_codepoints_len: usize = 0,
};

/// C: GhosttyTerminalSelectWordBetweenOptions
pub const SelectWordBetweenOptions = extern struct {
    size: usize = @sizeOf(SelectWordBetweenOptions),
    start: grid_ref.CGridRef,
    end: grid_ref.CGridRef,
    boundary_codepoints: ?[*]const u32 = null,
    boundary_codepoints_len: usize = 0,
};

/// C: GhosttyTerminalSelectLineOptions
pub const SelectLineOptions = extern struct {
    size: usize = @sizeOf(SelectLineOptions),
    ref: grid_ref.CGridRef,
    whitespace: ?[*]const u32 = null,
    whitespace_len: usize = 0,
    semantic_prompt_boundary: bool = false,
};

/// C: GhosttyTerminalSelectionFormatOptions
pub const FormatOptions = extern struct {
    size: usize = @sizeOf(FormatOptions),
    emit: Format,
    unwrap: bool,
    trim: bool,
    selection: ?*const CSelection = null,
};

/// C: GhosttyTerminalSearchSelectOptions
pub const SearchSelectOptions = extern struct {
    size: usize = @sizeOf(SearchSelectOptions),
    needle: ?[*]const u8 = null,
    needle_len: usize = 0,
    match_index: usize = 0,
    center_selected_viewport: bool = false,
};

pub fn word(
    terminal: terminal_c.Terminal,
    options: ?*const SelectWordOptions,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (opts.size < @sizeOf(SelectWordOptions)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const boundary_codepoints = codepointSlice(
        opts.boundary_codepoints,
        opts.boundary_codepoints_len,
    ) catch return .invalid_value;

    const screen = t.screens.active;
    const pin = opts.ref.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectWord(
        pin,
        boundary_codepoints orelse &selection_codepoints.default_word_boundaries,
    ) orelse
        return .no_value);
    return .success;
}

pub fn word_between(
    terminal: terminal_c.Terminal,
    options: ?*const SelectWordBetweenOptions,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (opts.size < @sizeOf(SelectWordBetweenOptions)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const boundary_codepoints = codepointSlice(
        opts.boundary_codepoints,
        opts.boundary_codepoints_len,
    ) catch return .invalid_value;

    const screen = t.screens.active;
    const start = opts.start.toPin() orelse return .invalid_value;
    const end = opts.end.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectWordBetween(
        start,
        end,
        boundary_codepoints orelse &selection_codepoints.default_word_boundaries,
    ) orelse
        return .no_value);
    return .success;
}

pub fn line(
    terminal: terminal_c.Terminal,
    options: ?*const SelectLineOptions,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (opts.size < @sizeOf(SelectLineOptions)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const whitespace = codepointSlice(
        opts.whitespace,
        opts.whitespace_len,
    ) catch return .invalid_value;

    const screen = t.screens.active;
    const pin = opts.ref.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectLine(.{
        .pin = pin,
        .whitespace = whitespace orelse &selection_codepoints.default_line_whitespace,
        .semantic_prompt_boundary = opts.semantic_prompt_boundary,
    }) orelse return .no_value);
    return .success;
}

pub fn all(
    terminal: terminal_c.Terminal,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    out.* = .fromZig(t.screens.active.selectAll() orelse return .no_value);
    return .success;
}

pub fn search_select(
    terminal: terminal_c.Terminal,
    options: ?*const SearchSelectOptions,
    out_selection: ?*CSelection,
    out_total_matches: ?*usize,
    out_viewport_matches_: ?[*]CSelection,
    viewport_matches_capacity: usize,
    out_viewport_matches_count: ?*usize,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (opts.size < @sizeOf(SearchSelectOptions)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;
    const out_total = out_total_matches orelse return .invalid_value;
    const out_viewport_count = out_viewport_matches_count orelse return .invalid_value;
    if (viewport_matches_capacity == 0) return .invalid_value;
    const out_viewport_matches =
        (out_viewport_matches_ orelse return .invalid_value)[0..viewport_matches_capacity];
    out_total.* = 0;
    out_viewport_count.* = 0;

    if (opts.needle_len == 0) return .invalid_value;
    const needle_ptr = opts.needle orelse return .invalid_value;
    const needle = needle_ptr[0..opts.needle_len];
    if (!std.unicode.utf8ValidateSlice(needle)) return .invalid_value;

    const alloc = t.gpa();
    var search = ScreenSearch.init(alloc, t.screens.active, needle) catch
        return .out_of_memory;
    defer search.deinit();
    search.searchAll() catch return .out_of_memory;

    const total = search.matchesLen();
    out_total.* = total;
    if (opts.match_index >= total) return .no_value;

    const matches = search.matches(alloc) catch return .out_of_memory;
    defer alloc.free(matches);
    const match = matches[opts.match_index].untracked();
    out.* = .fromZig(Selection.init(match.start, match.end, false));

    const pages = &t.screens.active.pages;
    const scrollbar = pages.scrollbar();
    const viewport_start = if (opts.center_selected_viewport) selected: {
        // The caller may scroll the selected match to the same centered row
        // after this call. Filter against that future viewport so the first
        // scene after navigation already contains every visible candidate.
        const selected_start = pages.pointFromPin(.screen, match.start) orelse
            return .invalid_value;
        break :selected @min(
            @as(usize, selected_start.screen.y) -| (scrollbar.len / 2),
            scrollbar.total -| scrollbar.len,
        );
    } else scrollbar.offset;
    const viewport_end = viewport_start +| scrollbar.len;
    var viewport_count: usize = 0;
    for (matches) |candidate| {
        const untracked = candidate.untracked();
        const start = pages.pointFromPin(.screen, untracked.start) orelse continue;
        const end = pages.pointFromPin(.screen, untracked.end) orelse continue;
        if (@as(usize, end.screen.y) < viewport_start or
            @as(usize, start.screen.y) >= viewport_end) continue;
        if (viewport_count >= out_viewport_matches.len) return .out_of_space;
        out_viewport_matches[viewport_count] = .fromZig(Selection.init(
            untracked.start,
            untracked.end,
            false,
        ));
        viewport_count += 1;
    }
    out_viewport_count.* = viewport_count;
    return .success;
}

pub fn output(
    terminal: terminal_c.Terminal,
    ref: grid_ref.CGridRef,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const screen = t.screens.active;
    const pin = ref.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectOutput(pin) orelse return .no_value);
    return .success;
}

pub fn format_buf(
    terminal: terminal_c.Terminal,
    opts: FormatOptions,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;

    if (out_ == null) {
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        formatSelection(t, opts, &discarding.writer) catch |err| return switch (err) {
            error.InvalidValue => .invalid_value,
            error.NoValue => .no_value,
            error.OutOfMemory => .out_of_memory,
            error.WriteFailed => unreachable,
        };
        out_written.* = @intCast(discarding.count);
        return .out_of_space;
    }

    var writer: std.Io.Writer = .fixed(out_.?[0..out_len]);
    formatSelection(t, opts, &writer) catch |err| switch (err) {
        error.InvalidValue => return .invalid_value,
        error.NoValue => return .no_value,
        error.OutOfMemory => return .out_of_memory,
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            formatSelection(t, opts, &discarding.writer) catch |retry_err| return switch (retry_err) {
                error.InvalidValue => .invalid_value,
                error.NoValue => .no_value,
                error.OutOfMemory => .out_of_memory,
                error.WriteFailed => unreachable,
            };
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

pub fn format_alloc(
    terminal: terminal_c.Terminal,
    alloc_: ?*const CAllocator,
    opts: FormatOptions,
    out_ptr: *?[*]u8,
    out_len: *usize,
) callconv(lib.calling_conv) Result {
    out_ptr.* = null;
    out_len.* = 0;

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    formatSelection(t, opts, &aw.writer) catch |err| return switch (err) {
        error.InvalidValue => .invalid_value,
        error.NoValue => .no_value,
        error.OutOfMemory => .out_of_memory,
        error.WriteFailed => .out_of_memory,
    };

    const buf = aw.toOwnedSlice() catch return .out_of_memory;
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return .success;
}

fn formatSelection(
    t: *terminal_c.ZigTerminal,
    opts: FormatOptions,
    writer: *std.Io.Writer,
) error{ InvalidValue, NoValue, OutOfMemory, WriteFailed }!void {
    var formatter = selectionFormatter(t, opts) catch |err| return err;
    try formatter.format(writer);
}

fn selectionFormatter(
    t: *terminal_c.ZigTerminal,
    opts: FormatOptions,
) error{ InvalidValue, NoValue }!formatterpkg.TerminalFormatter {
    if (opts.size < @sizeOf(FormatOptions)) return error.InvalidValue;
    _ = std.meta.intToEnum(Format, @intFromEnum(opts.emit)) catch
        return error.InvalidValue;

    const sel = if (opts.selection) |sel|
        sel.toZig() orelse return error.InvalidValue
    else
        t.screens.active.selection orelse return error.NoValue;

    var formatter: formatterpkg.TerminalFormatter = .init(t, .{
        .emit = opts.emit,
        .unwrap = opts.unwrap,
        .trim = opts.trim,
    });
    formatter.content = .{ .selection = sel };
    return formatter;
}

/// Return the borrowed C array of `uint32_t` codepoints as a `[]const u21`.
///
/// `NULL + len 0` returns null, which callers treat as “use the API default
/// set.” A non-null pointer with `len 0` returns an empty slice, meaning “use an
/// explicitly empty set.” A non-zero length requires a non-null pointer.
///
/// This is intentionally zero-copy. In the C ABI, codepoints are `uint32_t`,
/// but selection internals use Zig's `u21` to represent valid Unicode scalar
/// values. Zig currently stores `u21` in the same size and alignment as `u32`,
/// so we assert that layout relationship and reinterpret the borrowed slice.
/// If Zig ever changes that representation, these comptime assertions fail
/// loudly rather than silently making this cast wrong.
fn codepointSlice(
    ptr: ?[*]const u32,
    len: usize,
) error{InvalidValue}!?[]const u21 {
    comptime {
        std.debug.assert(@sizeOf(u21) == @sizeOf(u32));
        std.debug.assert(@alignOf(u21) == @alignOf(u32));
    }

    if (len == 0) {
        const p = ptr orelse return null;
        _ = p;
        return &.{};
    }

    const p = ptr orelse return error.InvalidValue;
    const cps: [*]const u21 = @ptrCast(p);
    return cps[0..len];
}

pub fn adjust(
    terminal: terminal_c.Terminal,
    selection: ?*CSelection,
    adjustment: Selection.Adjustment,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Selection.Adjustment, @intFromEnum(adjustment)) catch {
            log.warn("terminal_selection_adjust invalid adjustment value={d}", .{@intFromEnum(adjustment)});
            return .invalid_value;
        };
    }

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel_ptr = selection orelse return .invalid_value;
    var sel = sel_ptr.toZig() orelse return .invalid_value;
    sel.adjust(t.screens.active, adjustment);
    sel_ptr.* = .fromZig(sel);
    return .success;
}

pub fn order(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    out_order: ?*Selection.Order,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_order orelse return .invalid_value;

    out.* = sel.order(t.screens.active);
    return .success;
}

pub fn ordered(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    desired: Selection.Order,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Selection.Order, @intFromEnum(desired)) catch {
            log.warn("terminal_selection_ordered invalid desired value={d}", .{@intFromEnum(desired)});
            return .invalid_value;
        };
    }

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    out.* = .fromZig(sel.ordered(t.screens.active, desired));
    return .success;
}

pub fn contains(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    pt: point.Point.C,
    out_contains: ?*bool,
) callconv(lib.calling_conv) Result {
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_contains orelse return .invalid_value;

    const screen = t.screens.active;
    const pin = screen.pages.pin(.fromC(pt)) orelse return .invalid_value;
    out.* = sel.contains(screen, pin);
    return .success;
}

pub fn equal(
    terminal: terminal_c.Terminal,
    a: ?*const CSelection,
    b: ?*const CSelection,
    out_equal: ?*bool,
) callconv(lib.calling_conv) Result {
    _ = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel_a = (a orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const sel_b = (b orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_equal orelse return .invalid_value;

    out.* = sel_a.eql(sel_b);
    return .success;
}

test "selection_format_alloc uses active selection" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello World", 11);

    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 6, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 10, .y = 0 } },
    }, &end_ref));

    const sel: CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    try testing.expectEqual(Result.success, terminal_c.set(t, .selection, @ptrCast(&sel)));

    const opts: FormatOptions = .{
        .emit = .plain,
        .unwrap = true,
        .trim = true,
    };

    var required: usize = 0;
    try testing.expectEqual(Result.out_of_space, format_buf(
        t,
        opts,
        null,
        0,
        &required,
    ));
    try testing.expectEqual(@as(usize, 5), required);

    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try testing.expectEqual(Result.success, format_alloc(
        t,
        &lib.alloc.test_allocator,
        opts,
        &out_ptr,
        &out_len,
    ));
    const ptr = out_ptr orelse return error.TestExpectedEqual;
    defer lib.alloc.default(&lib.alloc.test_allocator).free(ptr[0..out_len]);

    try testing.expectEqualStrings("World", ptr[0..out_len]);
}

test "selection_format_buf uses provided selection" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello World", 11);

    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 4, .y = 0 } },
    }, &end_ref));

    const sel: CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };
    const opts: FormatOptions = .{
        .emit = .plain,
        .unwrap = true,
        .trim = true,
        .selection = &sel,
    };

    var small: [2]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.out_of_space, format_buf(
        t,
        opts,
        &small,
        small.len,
        &written,
    ));
    try testing.expectEqual(@as(usize, 5), written);

    var buf: [32]u8 = undefined;
    try testing.expectEqual(Result.success, format_buf(
        t,
        opts,
        &buf,
        buf.len,
        &written,
    ));
    try testing.expectEqualStrings("Hello", buf[0..written]);
}

test "selection_format_alloc returns no_value without active selection" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    var out_ptr: ?[*]u8 = @ptrFromInt(1);
    var out_len: usize = 123;
    try testing.expectEqual(Result.no_value, format_alloc(
        t,
        &lib.alloc.test_allocator,
        .{ .emit = .plain, .unwrap = true, .trim = true },
        &out_ptr,
        &out_len,
    ));
    try testing.expect(out_ptr == null);
    try testing.expectEqual(@as(usize, 0), out_len);
}
