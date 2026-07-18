const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const terminal = @import("../main.zig");
const terminal_c = @import("terminal.zig");
const Scene = @import("../../renderer/Scene.zig");
const unicode = @import("../../unicode/main.zig");

const EncoderWrapper = struct {
    alloc: Allocator,
    canonical: ?CachedCanonical = null,

    fn clearCanonical(self: *EncoderWrapper) void {
        if (self.canonical) |*cached| cached.deinit();
        self.canonical = null;
    }
};

const CachedCanonical = struct {
    value: Scene.CanonicalCache,
    allocation_budget: *Scene.AllocationBudget,

    fn deinit(self: *CachedCanonical) void {
        self.value.deinit();
        self.allocation_budget.release();
        self.* = undefined;
    }
};

const BufferWrapper = struct {
    bytes: []u8,
    allocation_budget: *Scene.AllocationBudget,
};

/// C: GhosttyRenderSceneEncoder
pub const Encoder = ?*EncoderWrapper;

/// C: GhosttyRenderSceneBuffer
pub const Buffer = ?*BufferWrapper;

/// C: GhosttyRenderSceneSectionKind
pub const SectionKind = enum(c_int) {
    unchanged = 0,
    full = 1,
    delta = 2,
};

/// C: GhosttyRenderSceneStatus
pub const Status = enum(c_int) {
    success = 0,
    invalid_value = 1,
    out_of_memory = 2,
    limit_exceeded = 3,
    unsupported_kitty_images = 4,
    unsupported_custom_shaders = 5,
    requires_full_snapshot = 6,
    internal_error = 7,
};

/// C: GhosttyRenderSceneLimits
pub const Limits = extern struct {
    size: usize = @sizeOf(Limits),
    max_encoded_bytes: usize = 64 * 1024 * 1024,
    max_allocation_bytes: usize = 128 * 1024 * 1024,
    max_rows: u32 = 4096,
    max_columns: u32 = 4096,
    max_cells: usize = 4 * 1024 * 1024,
    max_grapheme_codepoints_per_cell: usize = 64,
    max_total_grapheme_codepoints: usize = 4 * 1024 * 1024,
    max_preedit_codepoints: usize = 4096,
    max_highlights: usize = 1024 * 1024,
    max_overlay_features: usize = 16,
    max_kitty_resources: usize = 4096,
    max_kitty_placements: usize = 64 * 1024,
    max_kitty_resource_bytes: usize = 64 * 1024 * 1024,

    fn scene(self: Limits) Scene.Limits {
        return .{
            .max_encoded_bytes = self.max_encoded_bytes,
            .max_allocation_bytes = self.max_allocation_bytes,
            .max_rows = self.max_rows,
            .max_columns = self.max_columns,
            .max_cells = self.max_cells,
            .max_grapheme_codepoints_per_cell = self.max_grapheme_codepoints_per_cell,
            .max_total_grapheme_codepoints = self.max_total_grapheme_codepoints,
            .max_preedit_codepoints = self.max_preedit_codepoints,
            .max_highlights = self.max_highlights,
            .max_overlay_features = self.max_overlay_features,
            .max_kitty_resources = self.max_kitty_resources,
            .max_kitty_placements = self.max_kitty_placements,
            .max_kitty_resource_bytes = self.max_kitty_resource_bytes,
        };
    }

    fn valid(self: Limits) bool {
        return self.size >= @sizeOf(Limits);
    }
};

/// C: GhosttyRenderSceneOptions
pub const Options = extern struct {
    size: usize = @sizeOf(Options),
    terminal_id: [16]u8,
    terminal_epoch: u64,
    content_sequence: u64,
    presentation_id: [16]u8,
    presentation_generation: u64,
    presentation_sequence: u64,
    canonical_kind: SectionKind,
    focused: bool,
    cursor_blink_visible: bool,
    custom_shader_count: u32,
    limits: Limits = .{},
    /// Optional presentation-local IME marked text, borrowed for `encode`.
    preedit_utf8: ?[*]const u8 = null,
    preedit_utf8_len: usize = 0,
};

// The fields above `preedit_utf8` are the first published ABI. A caller with
// that exact older size remains valid and is interpreted as having no preedit.
const minimum_options_size = @offsetOf(Options, "preedit_utf8");

pub fn encoder_new(
    alloc_: ?*const CAllocator,
    out_: ?*Encoder,
) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_value;
    out.* = null;
    const alloc = lib.alloc.default(alloc_);
    const encoder = alloc.create(EncoderWrapper) catch return .out_of_memory;
    encoder.* = .{ .alloc = alloc };
    out.* = encoder;
    return .success;
}

pub fn encoder_free(encoder_: Encoder) callconv(lib.calling_conv) void {
    const encoder = encoder_ orelse return;
    const alloc = encoder.alloc;
    encoder.clearCanonical();
    alloc.destroy(encoder);
}

pub fn encoder_reset(encoder_: Encoder) callconv(lib.calling_conv) void {
    const encoder = encoder_ orelse return;
    encoder.clearCanonical();
}

pub fn encode(
    encoder_: Encoder,
    terminal_: terminal_c.Terminal,
    options_: ?*const Options,
    out_: ?*Buffer,
) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_value;
    out.* = null;
    const encoder = encoder_ orelse return .invalid_value;
    const t = terminal_c.zigTerminal(terminal_) orelse return .invalid_value;
    const options = options_ orelse return .invalid_value;
    if (!validOptions(options)) return .invalid_value;
    const image_count = kittyImageCount(t);
    const capabilities = sceneCapabilities(
        @intCast(image_count),
        options.custom_shader_count,
    );

    const canonical_kind = sceneSectionKind(options.canonical_kind) orelse
        return .invalid_value;
    const cached = if (encoder.canonical) |*value| value else null;
    switch (canonical_kind) {
        .unchanged => {
            const base = cached orelse return .requires_full_snapshot;
            if (!canonicalRefMatchesOptions(&base.value.section.value.ref, options))
                return .requires_full_snapshot;
            if (base.value.section.value.required_capabilities.bits !=
                capabilities.bits)
                return .requires_full_snapshot;
        },
        .delta => {
            const base = cached orelse return .requires_full_snapshot;
            const ref = base.value.section.value.ref;
            if (!sameTerminal(ref, options) or
                options.content_sequence <= ref.content_sequence)
                return .requires_full_snapshot;
        },
        .full => {},
    }

    const scrollbar = t.screens.active.pages.scrollbar();
    const scene_limits = options.limits.scene();
    const preedit_input = optionsPreedit(options);
    const max_preedit_bytes = std.math.mul(
        usize,
        scene_limits.max_preedit_codepoints,
        4,
    ) catch return .limit_exceeded;
    if (preedit_input.len > max_preedit_bytes) return .limit_exceeded;
    const preedit_bytes: []const u8 = if (preedit_input.len == 0)
        &.{}
    else
        preedit_input.ptr.?[0..preedit_input.len];
    if (canonical_kind == .unchanged and
        !cachedCanonicalCoversTerminal(
            &cached.?.value.section.value,
            t,
            scrollbar,
        ))
        return .requires_full_snapshot;
    const canonical_window = canonicalWindow(scrollbar, t.screens.active.pages.cols, scene_limits) orelse
        return .limit_exceeded;
    const allocation_budget = Scene.AllocationBudget.create(
        encoder.alloc,
        scene_limits.max_allocation_bytes,
    ) catch return .out_of_memory;
    var budget_owned = true;
    defer if (budget_owned) allocation_budget.release();
    const call_alloc = allocation_budget.allocator();

    var viewport_state: terminal.RenderState = .empty;
    defer viewport_state.deinit(call_alloc);
    viewport_state.update(call_alloc, t) catch |err|
        return mapError(err, allocation_budget, canonical_kind);

    var canonical_state = terminal.RenderState.captureRows(
        call_alloc,
        t,
        canonical_window.start,
        canonical_window.count,
    ) catch |err| return mapError(err, allocation_budget, canonical_kind);
    defer canonical_state.deinit(call_alloc);

    const preedit = buildPreedit(
        call_alloc,
        preedit_bytes,
        scene_limits.max_preedit_codepoints,
    ) catch |err| return mapError(err, allocation_budget, canonical_kind);
    defer if (preedit) |value| call_alloc.free(value.codepoints);

    var scene = Scene.captureAlloc(call_alloc, &viewport_state, .{
        .canonical_ref = .{
            .terminal_id = options.terminal_id,
            .terminal_epoch = options.terminal_epoch,
            .content_sequence = options.content_sequence,
            .row_space_revision = scrollbar.row_space_revision,
        },
        .canonical_base_content_sequence = null,
        .canonical_state = &canonical_state,
        .canonical_row_start = canonical_window.start,
        .presentation_ref = .{
            .presentation_id = options.presentation_id,
            .generation = options.presentation_generation,
            .sequence = options.presentation_sequence,
        },
        .presentation_base_sequence = null,
        .required_capabilities = capabilities,
        .colors = sceneColors(t),
        .preedit = preedit,
        .link_cells = null,
        .scrollbar = scrollbar,
        .overlay_features = &.{},
        .hover = null,
        .focused = options.focused,
        .cursor_blink_visible = options.cursor_blink_visible,
        .image_count = @intCast(image_count),
        .custom_shader_count = options.custom_shader_count,
    }, scene_limits) catch |err|
        return mapError(err, allocation_budget, canonical_kind);
    var scene_owned = true;
    defer if (scene_owned) scene.deinit();
    if (comptime build_options.kitty_graphics) {
        const canonical_changed = canonical_kind != .unchanged;
        const kitty = Scene.captureKitty(
            scene.canonical_arena.allocator(),
            t,
            scene_limits,
            canonical_changed,
        ) catch |err| return mapError(err, allocation_budget, canonical_kind);
        if (canonical_changed) {
            scene.canonical.content.kitty_generation = kitty.generation;
            scene.canonical.content.kitty_resources = kitty.resources;
            scene.canonical.content.kitty_images = kitty.images;
        } else {
            const prior = cached.?.value.section.value.content;
            scene.canonical.content.kitty_generation = prior.kitty_generation;
            scene.canonical.content.kitty_resources = prior.kitty_resources;
            scene.canonical.content.kitty_images = prior.kitty_images;
        }
        scene.presentation.content.kitty_placements = kitty.placements;
    }

    if (canonical_kind == .delta) {
        const base = &cached.?.value.section.value;
        if (base.content.rows.len != scene.canonical.content.rows.len)
            return .requires_full_snapshot;
    }

    const bytes = Scene.encodeAlloc(call_alloc, &scene, .{
        .supported_capabilities = capabilities,
        .canonical_kind = canonical_kind,
        .presentation_kind = .full,
        .canonical_base = if (canonical_kind == .delta)
            &cached.?.value.section.value
        else
            null,
    }, scene_limits) catch |err|
        return mapError(err, allocation_budget, canonical_kind);
    errdefer call_alloc.free(bytes);

    const buffer = std.heap.page_allocator.create(BufferWrapper) catch
        return .out_of_memory;
    errdefer std.heap.page_allocator.destroy(buffer);
    buffer.* = .{
        .bytes = bytes,
        .allocation_budget = allocation_budget,
    };

    if (canonical_kind != .unchanged) {
        var split = Scene.splitOwned(&scene);
        scene_owned = false;
        split.presentation.deinit();

        // The immutable output owns the original budget reference. The new
        // canonical cache owns this retained reference independently.
        allocation_budget.retain();
        const replacement: CachedCanonical = .{
            .value = split.canonical,
            .allocation_budget = allocation_budget,
        };
        if (encoder.canonical) |*prior| prior.deinit();
        encoder.canonical = replacement;
    }

    budget_owned = false;
    out.* = buffer;
    return .success;
}

pub fn buffer_data(buffer_: Buffer) callconv(lib.calling_conv) ?[*]const u8 {
    const buffer = buffer_ orelse return null;
    return buffer.bytes.ptr;
}

pub fn buffer_size(buffer_: Buffer) callconv(lib.calling_conv) usize {
    const buffer = buffer_ orelse return 0;
    return buffer.bytes.len;
}

pub fn buffer_free(buffer_: Buffer) callconv(lib.calling_conv) void {
    const buffer = buffer_ orelse return;
    const budget = buffer.allocation_budget;
    budget.allocator().free(buffer.bytes);
    budget.release();
    std.heap.page_allocator.destroy(buffer);
}

const CanonicalWindow = struct {
    start: usize,
    count: usize,
};

fn sceneColors(t: *const terminal.Terminal) Scene.Colors {
    var result: Scene.Colors = .empty;
    if (t.colors.background.override) |value|
        result.background_override = sceneRGB(value);
    if (t.colors.foreground.override) |value|
        result.foreground_override = sceneRGB(value);
    if (t.colors.cursor.override) |value|
        result.cursor_override = sceneRGB(value);
    result.reverse = t.modes.get(.reverse_colors);

    var iterator = t.colors.palette.mask.iterator(.{});
    while (iterator.next()) |index| {
        const palette_index: u8 = @intCast(index);
        result.setPalette(
            palette_index,
            sceneRGB(t.colors.palette.current[palette_index]),
        );
    }
    return result;
}

fn sceneCapabilities(
    image_count: u32,
    custom_shader_count: u32,
) Scene.CapabilityManifest {
    var result = Scene.CapabilityManifest.baseline;
    if (image_count > 0) {
        result = result.including(.images);
        result = result.including(.kitty_static_resources_v1);
    }
    if (custom_shader_count > 0)
        result = result.including(.custom_shaders);
    return result;
}

fn sceneRGB(value: terminal.color.RGB) Scene.RGB {
    return .{ .r = value.r, .g = value.g, .b = value.b };
}

fn canonicalWindow(
    scrollbar: terminal.Scrollbar,
    columns: terminal.size.CellCountInt,
    limits: Scene.Limits,
) ?CanonicalWindow {
    const max_rows: usize = limits.max_rows;
    if (scrollbar.total == 0 or scrollbar.len == 0 or
        scrollbar.len > max_rows or columns == 0 or
        columns > limits.max_columns)
        return null;
    const count = @min(scrollbar.total, max_rows);
    const start = @min(scrollbar.offset, scrollbar.total - count);
    const end = std.math.add(usize, start, count) catch return null;
    const viewport_end = std.math.add(
        usize,
        scrollbar.offset,
        scrollbar.len,
    ) catch return null;
    if (viewport_end > end) return null;
    const cells = std.math.mul(usize, count, columns) catch return null;
    if (cells > limits.max_cells) return null;
    return .{ .start = start, .count = count };
}

fn validOptions(options: *const Options) bool {
    return options.size >= minimum_options_size and
        options.limits.valid() and
        (options.size < @sizeOf(Options) or
            options.preedit_utf8_len == 0 or
            options.preedit_utf8 != null) and
        !identityIsZero(options.terminal_id) and
        options.terminal_epoch != 0 and
        options.content_sequence != 0 and
        !identityIsZero(options.presentation_id) and
        options.presentation_generation != 0 and
        options.presentation_sequence != 0;
}

const PreeditInput = struct {
    ptr: ?[*]const u8,
    len: usize,
};

fn optionsPreedit(options: *const Options) PreeditInput {
    if (options.size < @sizeOf(Options) or options.preedit_utf8_len == 0)
        return .{ .ptr = null, .len = 0 };
    return .{
        .ptr = options.preedit_utf8,
        .len = options.preedit_utf8_len,
    };
}

fn buildPreedit(
    alloc: Allocator,
    bytes: []const u8,
    max_codepoints: usize,
) !?Scene.Preedit {
    if (bytes.len == 0) return null;
    const view = std.unicode.Utf8View.init(bytes) catch
        return error.InvalidCodepoint;

    var count: usize = 0;
    var count_it = view.iterator();
    while (count_it.nextCodepoint()) |codepoint| {
        const width = unicode.table.get(codepoint).width;
        // Match Surface.preeditCallback: Ghostty currently cannot render a
        // zero-width preedit codepoint independently, so it is ignored.
        if (width == 0) continue;
        count = std.math.add(usize, count, 1) catch return error.LimitExceeded;
        if (count > max_codepoints) return error.LimitExceeded;
    }
    if (count == 0) return null;

    const codepoints = try alloc.alloc(Scene.PreeditCodepoint, count);
    errdefer alloc.free(codepoints);
    var index: usize = 0;
    var fill_it = view.iterator();
    while (fill_it.nextCodepoint()) |codepoint| {
        const width = unicode.table.get(codepoint).width;
        if (width == 0) continue;
        codepoints[index] = .{
            .codepoint = codepoint,
            .wide = width >= 2,
        };
        index += 1;
    }
    std.debug.assert(index == codepoints.len);
    return .{ .codepoints = codepoints };
}

fn identityIsZero(identity: [16]u8) bool {
    for (identity) |byte| if (byte != 0) return false;
    return true;
}

fn sceneSectionKind(kind: SectionKind) ?Scene.SectionKind {
    const checked = std.meta.intToEnum(
        SectionKind,
        @intFromEnum(kind),
    ) catch return null;
    return switch (checked) {
        .unchanged => .unchanged,
        .full => .full,
        .delta => .delta,
    };
}

fn canonicalRefMatchesOptions(
    ref: *const Scene.CanonicalSceneRef,
    options: *const Options,
) bool {
    return sameTerminal(ref.*, options) and
        ref.content_sequence == options.content_sequence;
}

fn sameTerminal(
    ref: Scene.CanonicalSceneRef,
    options: *const Options,
) bool {
    return std.mem.eql(u8, &ref.terminal_id, &options.terminal_id) and
        ref.terminal_epoch == options.terminal_epoch;
}

fn cachedCanonicalCoversTerminal(
    canonical: *const Scene.CanonicalSceneEnvelope,
    t: *terminal.Terminal,
    scrollbar: terminal.Scrollbar,
) bool {
    const live_image_count = std.math.cast(u32, kittyImageCount(t)) orelse
        return false;
    if (canonical.ref.row_space_revision != scrollbar.row_space_revision or
        canonical.content.row_total != scrollbar.total or
        canonical.content.bounds.rows != scrollbar.len or
        canonical.content.bounds.columns != t.screens.active.pages.cols or
        canonical.content.image_count != live_image_count or
        canonical.content.kitty_generation != kittyGeneration(t) or
        !std.meta.eql(canonical.content.colors, sceneColors(t)) or
        canonical.content.screen != switch (t.screens.active_key) {
            .primary => Scene.Screen.primary,
            .alternate => Scene.Screen.alternate,
        })
        return false;
    const backing_end = std.math.add(
        u64,
        canonical.content.row_start,
        canonical.content.rows.len,
    ) catch return false;
    const viewport_end = std.math.add(
        u64,
        scrollbar.offset,
        scrollbar.len,
    ) catch return false;
    return scrollbar.offset >= canonical.content.row_start and
        viewport_end <= backing_end;
}

fn kittyImageCount(t: *terminal.Terminal) usize {
    if (comptime build_options.kitty_graphics)
        return t.screens.active.kitty_images.images.count();
    return 0;
}

fn kittyGeneration(t: *terminal.Terminal) u64 {
    if (comptime build_options.kitty_graphics)
        return t.screens.active.kitty_images.generation;
    return 0;
}

fn mapError(
    err: anyerror,
    budget: *Scene.AllocationBudget,
    canonical_kind: Scene.SectionKind,
) Status {
    return switch (err) {
        error.OutOfMemory => if (budget.limit_exceeded)
            .limit_exceeded
        else
            .out_of_memory,
        error.LimitExceeded => .limit_exceeded,
        error.UnsupportedCapability => .unsupported_kitty_images,
        error.InvalidSequence => if (canonical_kind == .delta)
            .requires_full_snapshot
        else
            .invalid_value,
        error.InvalidDimensions,
        error.InvalidRenderState,
        error.InvalidCoordinate,
        error.InvalidRange,
        error.InvalidCodepoint,
        error.InvalidIdentity,
        error.InvalidCapabilityManifest,
        error.InvalidHeader,
        => .invalid_value,
        error.UnsupportedSnapshotKind,
        error.InvalidMagic,
        error.UnsupportedVersion,
        error.WrongTerminal,
        error.WrongPresentation,
        error.ReplayRejected,
        error.Truncated,
        error.TrailingData,
        error.InvalidEnum,
        error.InvalidBoolean,
        => .internal_error,
        else => .internal_error,
    };
}

const testing = std.testing;

fn testOptions() Options {
    return .{
        .terminal_id = .{
            0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0x4c, 0xde,
            0x80, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
        },
        .terminal_epoch = 3,
        .content_sequence = 1,
        .presentation_id = .{
            0x20, 0x42, 0x64, 0x86, 0xa8, 0xca, 0x4e, 0xf0,
            0x90, 0x22, 0x44, 0x66, 0x88, 0xaa, 0xcc, 0xee,
        },
        .presentation_generation = 2,
        .presentation_sequence = 1,
        .canonical_kind = .full,
        .focused = true,
        .cursor_blink_visible = true,
        .custom_shader_count = 0,
    };
}

fn testTerminal(rows: u16) !terminal_c.Terminal {
    var result: terminal_c.Terminal = null;
    const status = terminal_c.new(&lib.alloc.test_allocator, &result, .{
        .cols = 8,
        .rows = rows,
        .max_scrollback = 100,
    });
    try testing.expectEqual(@import("result.zig").Result.success, status);
    return result;
}

fn testColorDefaults(
    background: terminal.color.RGB,
    foreground: terminal.color.RGB,
    palette_one: terminal.color.RGB,
    palette_four: terminal.color.RGB,
) terminal.RenderState.Colors {
    var result = terminal.RenderState.empty.colors;
    result.background = background;
    result.foreground = foreground;
    result.cursor = null;
    result.palette[1] = palette_one;
    result.palette[4] = palette_four;
    return result;
}

test "render scene C ABI captures canonical backing and exact identities" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);
    terminal_c.vt_write(term, "one\r\ntwo\r\nthree".ptr, "one\r\ntwo\r\nthree".len);

    const options = testOptions();
    var buffer: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    defer buffer_free(buffer);

    const bytes = buffer_data(buffer).?[0..buffer_size(buffer)];
    var update = try Scene.decodeAlloc(testing.allocator, bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = null,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = null,
        .supported_capabilities = .baseline,
    }, options.limits.scene());
    defer update.deinit();
    var decoded = try Scene.ownedFromInitialUpdate(
        &update,
        .baseline,
        options.limits.scene(),
    );
    defer decoded.deinit();
    try testing.expectEqual(options.terminal_id, decoded.canonical.ref.terminal_id);
    try testing.expectEqual(options.terminal_epoch, decoded.canonical.ref.terminal_epoch);
    try testing.expectEqual(options.content_sequence, decoded.canonical.ref.content_sequence);
    try testing.expectEqual(options.presentation_id, decoded.presentation.ref.presentation_id);
    try testing.expect(decoded.canonical.content.rows.len > decoded.canonical.content.bounds.rows);
}

test "render scene keeps config colors presentation-local across OSC overrides and resets" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);

    const overrides =
        "\x1b]4;4;rgb:aa/bb/cc\x1b\\" ++
        "\x1b]10;rgb:11/22/33\x1b\\" ++
        "\x1b]11;rgb:44/55/66\x1b\\" ++
        "\x1b]12;rgb:77/88/99\x1b\\" ++
        "\x1b[?5h";
    terminal_c.vt_write(term, overrides.ptr, overrides.len);

    var options = testOptions();
    var buffer: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    defer buffer_free(buffer);
    const bytes = buffer_data(buffer).?[0..buffer_size(buffer)];
    var update = try Scene.decodeAlloc(testing.allocator, bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = null,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = null,
        .supported_capabilities = .baseline,
    }, options.limits.scene());
    defer update.deinit();
    var decoded = try Scene.ownedFromInitialUpdate(
        &update,
        .baseline,
        options.limits.scene(),
    );
    defer decoded.deinit();

    const sparse = decoded.canonical.content.colors;
    try testing.expect(sparse.paletteIsSet(4));
    try testing.expect(!sparse.paletteIsSet(1));
    try testing.expectEqual(
        Scene.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        sparse.palette[4],
    );
    try testing.expectEqual(
        Scene.RGB{ .r = 0x11, .g = 0x22, .b = 0x33 },
        sparse.foreground_override.?,
    );
    try testing.expectEqual(
        Scene.RGB{ .r = 0x44, .g = 0x55, .b = 0x66 },
        sparse.background_override.?,
    );
    try testing.expectEqual(
        Scene.RGB{ .r = 0x77, .g = 0x88, .b = 0x99 },
        sparse.cursor_override.?,
    );
    try testing.expect(sparse.reverse);

    const theme_a = testColorDefaults(
        .{ .r = 0x01, .g = 0x02, .b = 0x03 },
        .{ .r = 0x04, .g = 0x05, .b = 0x06 },
        .{ .r = 0xf9, .g = 0x26, .b = 0x72 },
        .{ .r = 0x10, .g = 0x20, .b = 0x30 },
    );
    const theme_b = testColorDefaults(
        .{ .r = 0x31, .g = 0x32, .b = 0x33 },
        .{ .r = 0x34, .g = 0x35, .b = 0x36 },
        .{ .r = 0x40, .g = 0x50, .b = 0x60 },
        .{ .r = 0x70, .g = 0x80, .b = 0x90 },
    );
    var materialized_a = try Scene.Materialized.initSeeded(
        testing.allocator,
        &decoded,
        .baseline,
        options.limits.scene(),
        theme_a,
    );
    defer materialized_a.deinit(testing.allocator);
    var materialized_b = try Scene.Materialized.initSeeded(
        testing.allocator,
        &decoded,
        .baseline,
        options.limits.scene(),
        theme_b,
    );
    defer materialized_b.deinit(testing.allocator);

    // These two projections came from the exact same canonical byte slice.
    // Untouched slots retain each renderer config while OSC 4 wins in both.
    try testing.expectEqual(theme_a.palette[1], materialized_a.state.colors.palette[1]);
    try testing.expectEqual(theme_b.palette[1], materialized_b.state.colors.palette[1]);
    try testing.expectEqual(
        terminal.color.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        materialized_a.state.colors.palette[4],
    );
    try testing.expectEqual(
        materialized_a.state.colors.palette[4],
        materialized_b.state.colors.palette[4],
    );
    // Reverse mode is applied after the OSC 10/11 overlays.
    try testing.expectEqual(
        terminal.color.RGB{ .r = 0x11, .g = 0x22, .b = 0x33 },
        materialized_a.state.colors.background,
    );
    try testing.expectEqual(
        terminal.color.RGB{ .r = 0x44, .g = 0x55, .b = 0x66 },
        materialized_a.state.colors.foreground,
    );
    try testing.expectEqual(
        terminal.color.RGB{ .r = 0x77, .g = 0x88, .b = 0x99 },
        materialized_a.state.colors.cursor.?,
    );

    const resets =
        "\x1b]104;4\x1b\\" ++
        "\x1b]110\x1b\\" ++
        "\x1b]111\x1b\\" ++
        "\x1b]112\x1b\\" ++
        "\x1b[?5l";
    terminal_c.vt_write(term, resets.ptr, resets.len);
    options.content_sequence += 1;
    options.presentation_sequence += 1;
    var reset_buffer: Buffer = null;
    try testing.expectEqual(
        Status.success,
        encode(encoder, term, &options, &reset_buffer),
    );
    defer buffer_free(reset_buffer);
    const reset_bytes = buffer_data(reset_buffer).?[0..buffer_size(reset_buffer)];
    var reset_update = try Scene.decodeAlloc(testing.allocator, reset_bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = null,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = null,
        .supported_capabilities = .baseline,
    }, options.limits.scene());
    defer reset_update.deinit();
    var reset_scene = try Scene.ownedFromInitialUpdate(
        &reset_update,
        .baseline,
        options.limits.scene(),
    );
    defer reset_scene.deinit();
    const reset_sparse = reset_scene.canonical.content.colors;
    try testing.expect(!reset_sparse.paletteIsSet(4));
    try testing.expectEqual(@as(?Scene.RGB, null), reset_sparse.foreground_override);
    try testing.expectEqual(@as(?Scene.RGB, null), reset_sparse.background_override);
    try testing.expectEqual(@as(?Scene.RGB, null), reset_sparse.cursor_override);
    try testing.expect(!reset_sparse.reverse);

    var reset_materialized = try Scene.Materialized.initSeeded(
        testing.allocator,
        &reset_scene,
        .baseline,
        options.limits.scene(),
        theme_a,
    );
    defer reset_materialized.deinit(testing.allocator);
    try testing.expectEqual(theme_a.palette[4], reset_materialized.state.colors.palette[4]);
    try testing.expectEqual(theme_a.foreground, reset_materialized.state.colors.foreground);
    try testing.expectEqual(theme_a.background, reset_materialized.state.colors.background);
    try testing.expectEqual(@as(?terminal.color.RGB, null), reset_materialized.state.colors.cursor);
}

test "render scene C ABI captures presentation-local IME preedit and caret anchor" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);

    // The combining mark is zero-width and is intentionally ignored, matching
    // Surface.preeditCallback. Hangul remains a wide preedit glyph.
    const marked_text = "a\u{0301}\u{AC00}";
    var options = testOptions();
    options.preedit_utf8 = marked_text.ptr;
    options.preedit_utf8_len = marked_text.len;
    var buffer: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    defer buffer_free(buffer);

    const bytes = buffer_data(buffer).?[0..buffer_size(buffer)];
    var update = try Scene.decodeAlloc(testing.allocator, bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = null,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = null,
        .supported_capabilities = .baseline,
    }, options.limits.scene());
    defer update.deinit();
    var decoded = try Scene.ownedFromInitialUpdate(
        &update,
        .baseline,
        options.limits.scene(),
    );
    defer decoded.deinit();

    const presentation = decoded.presentation.content;
    try testing.expectEqual(@as(usize, 2), presentation.preedit.len);
    try testing.expectEqual(@as(u21, 'a'), presentation.preedit[0].codepoint);
    try testing.expect(!presentation.preedit[0].wide);
    try testing.expectEqual(@as(u21, 0xAC00), presentation.preedit[1].codepoint);
    try testing.expect(presentation.preedit[1].wide);
    const caret = presentation.cursor_viewport orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), caret.coordinate.row);
    try testing.expectEqual(@as(u32, 0), caret.coordinate.column);
}

test "render scene options remain compatible before appended preedit fields" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);

    const invalid_utf8 = [_]u8{0xFF};
    var options = testOptions();
    options.size = minimum_options_size;
    // These bytes are outside the caller-declared struct and must not be read.
    options.preedit_utf8 = &invalid_utf8;
    options.preedit_utf8_len = invalid_utf8.len;
    var buffer: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    defer buffer_free(buffer);
}

test "render scene C ABI rejects malformed and over-limit preedit" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);

    var buffer: Buffer = null;
    var options = testOptions();
    options.preedit_utf8_len = 1;
    try testing.expectEqual(Status.invalid_value, encode(encoder, term, &options, &buffer));

    const invalid_utf8 = [_]u8{0xFF};
    options.preedit_utf8 = &invalid_utf8;
    try testing.expectEqual(Status.invalid_value, encode(encoder, term, &options, &buffer));

    const too_many = "ab";
    options.preedit_utf8 = too_many.ptr;
    options.preedit_utf8_len = too_many.len;
    options.limits.max_preedit_codepoints = 1;
    try testing.expectEqual(Status.limit_exceeded, encode(encoder, term, &options, &buffer));
}

test "render scene C ABI emits a canonical delta and requires full after reset" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);

    var options = testOptions();
    var first: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &first));
    defer buffer_free(first);
    const first_bytes = buffer_data(first).?[0..buffer_size(first)];
    var initial_update = try Scene.decodeAlloc(testing.allocator, first_bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = null,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = null,
        .supported_capabilities = .baseline,
    }, options.limits.scene());
    defer initial_update.deinit();
    var receiver = try Scene.ownedFromInitialUpdate(
        &initial_update,
        .baseline,
        options.limits.scene(),
    );
    defer receiver.deinit();

    terminal_c.vt_write(term, "changed".ptr, "changed".len);
    options.content_sequence += 1;
    options.presentation_sequence += 1;
    options.canonical_kind = .delta;
    var delta: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &delta));
    defer buffer_free(delta);
    const bytes = buffer_data(delta).?[0..buffer_size(delta)];
    try testing.expectEqual(@intFromEnum(Scene.SectionKind.delta), bytes[16]);
    var delta_update = try Scene.decodeAlloc(testing.allocator, bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = receiver.canonical.ref,
        .canonical_cache = &receiver.canonical,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = receiver.presentation.ref,
        .supported_capabilities = .baseline,
    }, options.limits.scene());
    defer delta_update.deinit();
    try Scene.applyUpdate(
        &receiver,
        &delta_update,
        .baseline,
        options.limits.scene(),
    );
    try testing.expectEqual(
        options.content_sequence,
        receiver.canonical.ref.content_sequence,
    );

    encoder_reset(encoder);
    options.content_sequence += 1;
    try testing.expectEqual(
        Status.requires_full_snapshot,
        encode(encoder, term, &options, &delta),
    );
}

test "render scene buffer outlives its encoder" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    const term = try testTerminal(2);
    defer terminal_c.free(term);
    const options = testOptions();
    var buffer: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    encoder_free(encoder);
    const bytes = buffer_data(buffer).?[0..buffer_size(buffer)];
    try testing.expectEqualSlices(u8, &Scene.wire_magic, bytes[0..4]);
    buffer_free(buffer);
}

test "render scene C ABI negotiates shaders and static Kitty resources" {
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);

    var options = testOptions();
    var buffer: Buffer = null;
    options.limits.max_allocation_bytes = 1;
    try testing.expectEqual(
        Status.limit_exceeded,
        encode(encoder, term, &options, &buffer),
    );

    options = testOptions();
    options.custom_shader_count = 1;
    try testing.expectEqual(
        Status.success,
        encode(encoder, term, &options, &buffer),
    );
    const shader_capabilities =
        Scene.CapabilityManifest.baseline.including(.custom_shaders);
    const shader_bytes = buffer_data(buffer).?[0..buffer_size(buffer)];
    var shader_update = try Scene.decodeAlloc(testing.allocator, shader_bytes, .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .canonical_ref = null,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .presentation_ref = null,
        .supported_capabilities = shader_capabilities,
    }, options.limits.scene());
    defer shader_update.deinit();
    var shader_scene = try Scene.ownedFromInitialUpdate(
        &shader_update,
        shader_capabilities,
        options.limits.scene(),
    );
    defer shader_scene.deinit();
    try testing.expectEqual(
        @as(u32, 1),
        shader_scene.presentation.content.custom_shader_count,
    );
    try testing.expect(
        shader_scene.canonical.required_capabilities.contains(.custom_shaders),
    );
    buffer_free(buffer);
    buffer = null;

    if (comptime build_options.kitty_graphics) {
        try testing.expectEqual(
            @import("result.zig").Result.success,
            terminal_c.resize(term, 8, 2, 10, 20),
        );
        terminal_c.vt_write(
            term,
            "\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1,z=1;/wAA/w==\x1b\\".ptr,
            "\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1,z=1;/wAA/w==\x1b\\".len,
        );
        options = testOptions();
        try testing.expectEqual(
            Status.success,
            encode(encoder, term, &options, &buffer),
        );
        const kitty_capabilities = Scene.CapabilityManifest.baseline
            .including(.images)
            .including(.kitty_static_resources_v1);
        const kitty_bytes = buffer_data(buffer).?[0..buffer_size(buffer)];
        var kitty_update = try Scene.decodeAlloc(
            testing.allocator,
            kitty_bytes,
            .{
                .terminal_id = options.terminal_id,
                .terminal_epoch = options.terminal_epoch,
                .canonical_ref = null,
                .presentation_id = options.presentation_id,
                .presentation_generation = options.presentation_generation,
                .presentation_ref = null,
                .supported_capabilities = kitty_capabilities,
            },
            options.limits.scene(),
        );
        defer kitty_update.deinit();
        var kitty_scene = try Scene.ownedFromInitialUpdate(
            &kitty_update,
            kitty_capabilities,
            options.limits.scene(),
        );
        defer kitty_scene.deinit();
        try testing.expectEqual(@as(u32, 1), kitty_scene.canonical.content.image_count);
        try testing.expectEqual(@as(usize, 1), kitty_scene.canonical.content.kitty_resources.len);
        try testing.expectEqualSlices(
            u8,
            &.{ 0xff, 0x00, 0x00, 0xff },
            kitty_scene.canonical.content.kitty_resources[0].pixels,
        );
        try testing.expectEqual(@as(usize, 1), kitty_scene.canonical.content.kitty_images.len);
        try testing.expectEqual(@as(usize, 1), kitty_scene.presentation.content.kitty_placements.len);
        try testing.expectEqual(
            @as(i32, 1),
            kitty_scene.presentation.content.kitty_placements[0].z,
        );
        buffer_free(buffer);
    }
}

test "render scene canonical cache fences Kitty placement and delete generation" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;
    var encoder: Encoder = null;
    try testing.expectEqual(
        Status.success,
        encoder_new(&lib.alloc.test_allocator, &encoder),
    );
    defer encoder_free(encoder);
    const term = try testTerminal(2);
    defer terminal_c.free(term);
    try testing.expectEqual(
        @import("result.zig").Result.success,
        terminal_c.resize(term, 8, 2, 10, 20),
    );
    terminal_c.vt_write(
        term,
        "\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\".ptr,
        "\x1b_Ga=T,t=d,f=32,i=1,p=1,s=1,v=1,c=1,r=1;/wAA/w==\x1b\\".len,
    );

    var options = testOptions();
    var buffer: Buffer = null;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    buffer_free(buffer);
    buffer = null;

    terminal_c.vt_write(
        term,
        "\x1b_Ga=p,i=1,p=2,c=1,r=1\x1b\\".ptr,
        "\x1b_Ga=p,i=1,p=2,c=1,r=1\x1b\\".len,
    );
    options.canonical_kind = .unchanged;
    options.presentation_sequence = 2;
    try testing.expectEqual(
        Status.requires_full_snapshot,
        encode(encoder, term, &options, &buffer),
    );
    options.canonical_kind = .full;
    options.content_sequence = 2;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    buffer_free(buffer);
    buffer = null;

    terminal_c.vt_write(
        term,
        "\x1b_Ga=d,d=A\x1b\\".ptr,
        "\x1b_Ga=d,d=A\x1b\\".len,
    );
    options.canonical_kind = .unchanged;
    options.presentation_sequence = 3;
    try testing.expectEqual(
        Status.requires_full_snapshot,
        encode(encoder, term, &options, &buffer),
    );
    options.canonical_kind = .full;
    options.content_sequence = 3;
    try testing.expectEqual(Status.success, encode(encoder, term, &options, &buffer));
    try testing.expect(buffer_size(buffer) > Scene.wire_header_size);
    buffer_free(buffer);
}
