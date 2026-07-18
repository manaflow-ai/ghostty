//! Process-independent semantic terminal scenes.
//!
//! `Projection` is the legacy synchronous borrowed input. `Owned` is the
//! transportable canonical/presentation pair used across process boundaries.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const Model = @import("scene/Model.zig");

pub const Identity = Model.Identity;
pub const TerminalIdentity = Model.TerminalIdentity;
pub const PresentationIdentity = Model.PresentationIdentity;
pub const HyperlinkIdentity = Model.HyperlinkIdentity;
pub const Limits = Model.Limits;
pub const CutoverEligibility = Model.CutoverEligibility;
pub const Capability = Model.Capability;
pub const CapabilityManifest = Model.CapabilityManifest;
pub const SnapshotKind = Model.SnapshotKind;
pub const SectionKind = Model.SectionKind;
pub const CanonicalSceneRef = Model.CanonicalSceneRef;
pub const PresentationSceneRef = Model.PresentationSceneRef;
pub const TerminalSpaceRef = Model.TerminalSpaceRef;
pub const DecodeExpectation = Model.DecodeExpectation;
pub const EncodeOptions = Model.EncodeOptions;
pub const Bounds = Model.Bounds;
pub const RowAnchor = Model.RowAnchor;
pub const Coordinate = Model.Coordinate;
pub const ViewportCoordinate = Model.ViewportCoordinate;
pub const RGB = Model.RGB;
pub const StyleColor = Model.StyleColor;
pub const Underline = Model.Underline;
pub const Style = Model.Style;
pub const WideRole = Model.WideRole;
pub const SemanticContent = Model.SemanticContent;
pub const CellContent = Model.CellContent;
pub const Cell = Model.Cell;
pub const SemanticPrompt = Model.SemanticPrompt;
pub const Row = Model.Row;
pub const Screen = Model.Screen;
pub const Colors = Model.Colors;
pub const CursorStyle = Model.CursorStyle;
pub const CursorViewport = Model.CursorViewport;
pub const CursorCellContent = Model.CursorCellContent;
pub const CursorCell = Model.CursorCell;
pub const Cursor = Model.Cursor;
pub const Content = Model.Content;
pub const ColumnRange = Model.ColumnRange;
pub const HighlightKind = Model.HighlightKind;
pub const Highlight = Model.Highlight;
pub const Scrollbar = Model.Scrollbar;
pub const PreeditCodepoint = Model.PreeditCodepoint;
pub const OverlayFeature = Model.OverlayFeature;
pub const Presentation = Model.Presentation;
pub const CanonicalSceneEnvelope = Model.CanonicalSceneEnvelope;
pub const PresentationEnvelope = Model.PresentationEnvelope;
pub const Owned = Model.Owned;
pub const OwnedCanonicalSection = Model.OwnedCanonicalSection;
pub const OwnedPresentationSection = Model.OwnedPresentationSection;
pub const AllocationBudget = Model.AllocationBudget;
pub const CanonicalCache = Model.CanonicalCache;
pub const PresentationCache = Model.PresentationCache;
pub const CachedView = Model.CachedView;
pub const CanonicalUpdate = Model.CanonicalUpdate;
pub const PresentationUpdate = Model.PresentationUpdate;
pub const Update = Model.Update;
pub const identityIsZero = Model.identityIsZero;
pub const nextSequence = Model.nextSequence;

/// Borrowed inputs used by the in-process renderer. Identity and sequencing
/// are deliberately absent: only the daemon may assign canonical identities.
pub const Projection = struct {
    terminal_state: *terminal.RenderState,
    preedit: ?Preedit,
    link_cells: *const terminal.RenderState.CellSet,
    scrollbar: terminal.Scrollbar,
    overlay_features: []const OverlayFeature = &.{},
    hover: ?terminal.point.Coordinate = null,
    focused: bool = false,
    cursor_blink_visible: bool = false,
};

pub const Mouse = struct {
    point: ?terminal.point.Coordinate = null,
    mods: input.Mods = .{},
};

pub const Preedit = struct {
    codepoints: []const Codepoint = &.{},
    pub const Codepoint = PreeditCodepoint;

    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{ .codepoints = try alloc.dupe(Codepoint, self.codepoints) };
    }
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| result += if (cp.wide) 2 else 1;
        return result;
    }
    pub fn range(
        self: *const Preedit,
        start: terminal.size.CellCountInt,
        max: terminal.size.CellCountInt,
    ) struct {
        start: terminal.size.CellCountInt,
        end: terminal.size.CellCountInt,
        cp_offset: usize,
    } {
        const width_, const cp_offset = width: {
            const max_width = max - start + 1;
            var value: terminal.size.CellCountInt = 0;
            for (0..self.codepoints.len) |index| {
                const reverse = self.codepoints.len - index - 1;
                value += if (self.codepoints[reverse].wide) 2 else 1;
                if (value > max_width) break :width .{ value, reverse };
            }
            break :width .{ value, 0 };
        };
        const end = if (width_ > 0) start + (width_ - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const CaptureImpl = @import("scene/Capture.zig").Capture(@This());
pub const CaptureOptions = CaptureImpl.Options;
pub const CaptureError = CaptureImpl.Error;
pub const captureAlloc = CaptureImpl.capture;
pub const cutoverEligibility = CaptureImpl.cutoverEligibility;

const ValidationImpl = @import("scene/Validation.zig").Validation(@This());
pub const ValidationError = ValidationImpl.Error;
pub const validateOwned = ValidationImpl.validateOwned;
pub const validatePair = ValidationImpl.validatePair;

const WireCodec = @import("scene/Codec.zig").Codec(@This());
pub const wire_magic = WireCodec.wire_magic;
pub const wire_version = WireCodec.wire_version;
pub const wire_header_size = WireCodec.wire_header_size;
pub const CodecError = WireCodec.CodecError;
pub const encodeAlloc = WireCodec.encodeAlloc;
pub const decodeAlloc = WireCodec.decodeAlloc;

pub const Materialized = @import("scene/Materialize.zig").Materialized(@This());
pub const Receiver = @import("scene/Receiver.zig").Receiver(@This());
pub const Export = @import("scene/Export.zig");
pub const LeasePool = @import("scene/LeasePool.zig").LeasePool;

/// Production adapter shared by every renderer implementation. Tests can
/// supply a recorder with the same `projectScene` entrypoint, so the owned
/// decode/materialize path is exercised without a platform GPU dependency.
pub fn projectOwned(
    alloc: Allocator,
    scene: *const Owned,
    supported: CapabilityManifest,
    limits: Limits,
    projector: anytype,
) !void {
    var materialized = try Materialized.init(
        alloc,
        scene,
        supported,
        limits,
    );
    defer materialized.deinit(alloc);
    try projector.projectScene(materialized.projection());
}

/// Project a validated focus/cursor-blink-only presentation revision through
/// an already materialized canonical cache. No canonical rows are allocated,
/// copied, or marked dirty by this path.
pub fn projectPresentationMetadata(
    materialized: *Materialized,
    canonical: *const CanonicalSceneEnvelope,
    previous: *const PresentationEnvelope,
    next: *const PresentationEnvelope,
    limits: Limits,
    projector: anytype,
) !void {
    try materialized.updatePresentationMetadata(
        canonical,
        previous,
        next,
        limits,
    );
    try projector.projectPresentationScene(materialized.projection());
}

pub const ApplyUpdateError = ValidationError || error{
    MissingInitialState,
    NoChanges,
};

/// Move a combined compatibility value into independently owned cache
/// sections. Any number of PresentationCache values can subsequently borrow
/// one CanonicalCache through `cachedView`.
pub const SplitCache = struct {
    canonical: CanonicalCache,
    presentation: PresentationCache,
};

pub fn splitOwned(scene: *Owned) SplitCache {
    const result: SplitCache = .{
        .canonical = CanonicalCache{ .section = .{
            .arena = scene.canonical_arena,
            .budget = scene.canonical_budget,
            .value = scene.canonical,
        } },
        .presentation = PresentationCache{ .section = .{
            .arena = scene.presentation_arena,
            .budget = scene.presentation_budget,
            .value = scene.presentation,
        } },
    };
    scene.* = undefined;
    return result;
}

pub fn cachedView(
    canonical: *const CanonicalCache,
    presentation: *const PresentationCache,
) CachedView {
    return .{
        .canonical = &canonical.section.value,
        .presentation = &presentation.section.value,
    };
}

/// Move an initial full/full update into a renderable independently cached
/// state. The moved update remains safely deinitializable.
pub fn ownedFromInitialUpdate(
    update: *Update,
    supported: CapabilityManifest,
    limits: Limits,
) ApplyUpdateError!Owned {
    const canonical = switch (update.canonical) {
        .unchanged => return error.MissingInitialState,
        .full => |section| section,
    };
    const presentation = switch (update.presentation) {
        .unchanged => return error.MissingInitialState,
        .full => |section| section,
    };
    if (update.required_capabilities.bits !=
        canonical.value.required_capabilities.bits)
        return error.InvalidCapabilityManifest;
    try validatePair(&canonical.value, &presentation.value, supported, limits);

    const canonical_ref = canonical.value.ref;
    const presentation_ref = presentation.value.ref;
    const result: Owned = .{
        .canonical_arena = canonical.arena,
        .presentation_arena = presentation.arena,
        .canonical_budget = canonical.budget,
        .presentation_budget = presentation.budget,
        .canonical = canonical.value,
        .presentation = presentation.value,
    };
    update.canonical = .{ .unchanged = canonical_ref };
    update.presentation = .{ .unchanged = presentation_ref };
    return result;
}

/// Atomically validate and move changed sections into an existing state.
/// Unchanged sections must name the exact cached reference. Applying one
/// section never increments or reallocates the other section.
pub fn applyUpdate(
    scene: *Owned,
    update: *Update,
    supported: CapabilityManifest,
    limits: Limits,
) ApplyUpdateError!void {
    var canonical_changed = false;
    const canonical = switch (update.canonical) {
        .unchanged => |ref| unchanged: {
            if (!ValidationImpl.canonicalRefEqual(ref, scene.canonical.ref))
                return error.InvalidIdentity;
            break :unchanged &scene.canonical;
        },
        .full => |section| changed: {
            canonical_changed = true;
            break :changed &section.value;
        },
    };
    var presentation_changed = false;
    const presentation = switch (update.presentation) {
        .unchanged => |ref| unchanged: {
            if (!ValidationImpl.presentationRefEqual(ref, scene.presentation.ref))
                return error.InvalidIdentity;
            break :unchanged &scene.presentation;
        },
        .full => |section| changed: {
            presentation_changed = true;
            break :changed &section.value;
        },
    };
    if (!canonical_changed and !presentation_changed) return error.NoChanges;
    if (update.required_capabilities.bits != canonical.required_capabilities.bits)
        return error.InvalidCapabilityManifest;
    try validatePair(canonical, presentation, supported, limits);

    if (canonical_changed) {
        const section = &update.canonical.full;
        const ref = section.value.ref;
        scene.canonical_arena.deinit();
        if (scene.canonical_budget) |budget| budget.release();
        scene.canonical_arena = section.arena;
        scene.canonical_budget = section.budget;
        scene.canonical = section.value;
        update.canonical = .{ .unchanged = ref };
    }
    if (presentation_changed) {
        const section = &update.presentation.full;
        const ref = section.value.ref;
        scene.presentation_arena.deinit();
        if (scene.presentation_budget) |budget| budget.release();
        scene.presentation_arena = section.arena;
        scene.presentation_budget = section.budget;
        scene.presentation = section.value;
        update.presentation = .{ .unchanged = ref };
    }
}

const test_terminal_id: TerminalIdentity = .{
    0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0x4C, 0xDE,
    0x80, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE,
};
const test_presentation_id: PresentationIdentity = .{
    0x20, 0x42, 0x64, 0x86, 0xA8, 0xCA, 0x4E, 0xF0,
    0x90, 0x22, 0x44, 0x66, 0x88, 0xAA, 0xCC, 0xEE,
};
const test_canonical_ref: CanonicalSceneRef = .{
    .terminal_id = test_terminal_id,
    .terminal_epoch = 3,
    .content_sequence = 42,
    .row_space_revision = 9,
};
const test_presentation_ref: PresentationSceneRef = .{
    .presentation_id = test_presentation_id,
    .generation = 2,
    .sequence = 17,
};
const test_decode_expectation: DecodeExpectation = .{
    .terminal_id = test_terminal_id,
    .terminal_epoch = 3,
    .canonical_ref = null,
    .presentation_id = test_presentation_id,
    .presentation_generation = 2,
    .presentation_ref = null,
    .supported_capabilities = .baseline,
};
const test_encode_options: EncodeOptions = .{
    .supported_capabilities = .baseline,
};

fn captureTestScene(alloc: Allocator) !Owned {
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    {
        var term = try terminal.Terminal.init(alloc, .{ .cols = 4, .rows = 1 });
        defer term.deinit(alloc);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice("\x1b]8;id=docs;https://example.com\x1b\\AB\x1b]8;;\x1b\\");
        try state.update(alloc, &term);
    }

    state.row_data.items(.selection)[0] = .{ 0, 1 };
    var row_arena = state.row_data.items(.arena)[0].promote(alloc);
    defer state.row_data.items(.arena)[0] = row_arena.state;
    try state.row_data.items(.highlights)[0].append(row_arena.allocator(), .{
        .tag = @intFromEnum(HighlightKind.search_match_selected),
        .range = .{ 1, 1 },
    });

    var links: terminal.RenderState.CellSet = .empty;
    defer links.deinit(alloc);
    try links.put(alloc, .{ .x = 0, .y = 0 }, {});
    return captureAlloc(alloc, &state, .{
        .canonical_ref = test_canonical_ref,
        .canonical_base_content_sequence = null,
        .canonical_row_start = 0,
        .presentation_ref = test_presentation_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = .{ .codepoints = &.{.{ .codepoint = 0xAC00, .wide = true }} },
        .link_cells = &links,
        .scrollbar = .{
            .total = 1,
            .offset = 0,
            .len = 1,
            .row_space_revision = 9,
        },
        .overlay_features = &.{.semantic_prompts},
        .hover = .{ .x = 0, .y = 0 },
        .focused = true,
        .cursor_blink_visible = true,
        .image_count = 0,
        .custom_shader_count = 0,
    }, .{});
}

fn expandTestBacking(
    scene: *Owned,
    backing_rows: usize,
    viewport_rows: u32,
) !void {
    const alloc = scene.canonical_arena.allocator();
    const source = scene.canonical.content.rows[0];
    const rows = try alloc.alloc(Row, backing_rows);
    const cell_count = try std.math.mul(
        usize,
        backing_rows,
        source.cells.len,
    );
    const cells = try alloc.alloc(Cell, cell_count);
    for (rows, 0..) |*row, row_index| {
        const row_cells = cells[row_index * source.cells.len ..][0..source.cells.len];
        @memcpy(row_cells, source.cells);
        if (row_cells.len > 0) switch (row_cells[0].content) {
            .codepoint => row_cells[0].content = .{
                .codepoint = @intCast('A' + row_index % 26),
            },
            else => {},
        };
        row.* = source;
        row.anchor.absolute_row = scene.canonical.content.row_start + row_index;
        row.backing_index = @intCast(row_index);
        row.wrap = false;
        row.wrap_continuation = false;
        row.cells = row_cells;
    }
    scene.canonical.content.bounds.rows = viewport_rows;
    scene.canonical.content.rows = rows;
    scene.canonical.content.row_total = backing_rows;
    scene.presentation.content.scrollbar.offset = scene.canonical.content.row_start;
    scene.presentation.content.scrollbar.len = viewport_rows;
}

const ProjectionRecorder = struct {
    rows: terminal.size.CellCountInt = 0,
    columns: terminal.size.CellCountInt = 0,
    first_codepoint: u21 = 0,
    cursor_cell: terminal.page.Cell.Backing = 0,
    selection: ?[2]terminal.size.CellCountInt = null,
    first_highlight_tag: ?u8 = null,
    active_link: bool = false,
    preedit_codepoint: ?u21 = null,
    scrollbar: terminal.Scrollbar = .zero,
    overlay: ?OverlayFeature = null,
    hover: ?terminal.point.Coordinate = null,
    focused: bool = false,
    cursor_blink_visible: bool = false,
    canonical_rows_read: usize = 0,

    pub fn projectScene(self: *ProjectionRecorder, projection: Projection) !void {
        const state = projection.terminal_state;
        self.canonical_rows_read += state.row_data.len;
        self.rows = state.rows;
        self.columns = state.cols;
        self.first_codepoint = state.row_data.items(.cells)[0].get(0).raw.codepoint();
        self.cursor_cell = @bitCast(state.cursor.cell);
        self.selection = state.row_data.items(.selection)[0];
        const highlights = state.row_data.items(.highlights)[0].items;
        self.first_highlight_tag = if (highlights.len > 0) highlights[0].tag else null;
        self.active_link = projection.link_cells.contains(.{ .x = 0, .y = 0 });
        self.preedit_codepoint = if (projection.preedit) |preedit|
            preedit.codepoints[0].codepoint
        else
            null;
        self.scrollbar = projection.scrollbar;
        self.overlay = if (projection.overlay_features.len > 0)
            projection.overlay_features[0]
        else
            null;
        self.hover = projection.hover;
        self.focused = projection.focused;
        self.cursor_blink_visible = projection.cursor_blink_visible;
    }

    pub fn projectPresentationScene(
        self: *ProjectionRecorder,
        projection: Projection,
    ) !void {
        self.focused = projection.focused;
        self.cursor_blink_visible = projection.cursor_blink_visible;
    }
};

test "preedit range preserves legacy behavior" {
    const preedit: Preedit = .{
        .codepoints = &.{.{ .codepoint = 0xAC00, .wide = true }},
    };
    const range = preedit.range(9, 9);
    try std.testing.expectEqual(@as(terminal.size.CellCountInt, 8), range.start);
    try std.testing.expectEqual(@as(terminal.size.CellCountInt, 9), range.end);
}

test "capture owns canonical and presentation data with stable anchors" {
    var scene = try captureTestScene(std.testing.allocator);
    defer scene.deinit();
    try std.testing.expectEqual(@as(u64, 42), scene.canonical.ref.content_sequence);
    try std.testing.expectEqual(@as(u64, 17), scene.presentation.ref.sequence);
    try std.testing.expectEqual(@as(u64, 9), scene.canonical.content.rows[0].anchor.row_space_revision);
    try std.testing.expectEqual(@as(u64, 0), scene.canonical.content.rows[0].anchor.absolute_row);
    try std.testing.expect(scene.canonical.content.rows[0].cells[0].hyperlink != null);
    try std.testing.expectEqual(
        scene.canonical.content.rows[0].cells[0].hyperlink.?,
        scene.canonical.content.rows[0].cells[1].hyperlink.?,
    );
    try std.testing.expectEqual(HighlightKind.search_match_selected, scene.presentation.content.highlights[0].kind);
}

test "codec round trip is deterministic and replay fenced" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const first = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(first);
    var update = try decodeAlloc(alloc, first, test_decode_expectation, .{});
    defer update.deinit();
    var decoded = try ownedFromInitialUpdate(&update, .baseline, .{});
    defer decoded.deinit();
    const second = try encodeAlloc(alloc, &decoded, test_encode_options, .{});
    defer alloc.free(second);
    try std.testing.expectEqualSlices(u8, first, second);

    var replay = test_decode_expectation;
    replay.canonical_ref = test_canonical_ref;
    try std.testing.expectError(
        error.ReplayRejected,
        decodeAlloc(alloc, first, replay, .{}),
    );
    replay = test_decode_expectation;
    replay.presentation_ref = test_presentation_ref;
    try std.testing.expectError(
        error.ReplayRejected,
        decodeAlloc(alloc, first, replay, .{}),
    );
}

test "wire v1 golden digest is immutable" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const encoded = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(encoded);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &digest, .{});
    const expected = [_]u8{
        0xea, 0xb8, 0x07, 0x3a, 0x8f, 0xf6, 0xc1, 0xd7,
        0x06, 0x7b, 0x86, 0xc0, 0x43, 0x8c, 0xbf, 0x19,
        0xff, 0x24, 0x9e, 0x22, 0xd5, 0x48, 0x5c, 0x1b,
        0x8a, 0xb2, 0x93, 0x79, 0x02, 0x53, 0x0f, 0xfa,
    };
    try std.testing.expectEqual(expected, digest);
}

test "canonical and presentation sections advance independently" {
    const alloc = std.testing.allocator;
    var initial = try captureTestScene(alloc);
    defer initial.deinit();
    const initial_bytes = try encodeAlloc(alloc, &initial, test_encode_options, .{});
    defer alloc.free(initial_bytes);
    var initial_update = try decodeAlloc(
        alloc,
        initial_bytes,
        test_decode_expectation,
        .{},
    );
    defer initial_update.deinit();
    var receiver = try ownedFromInitialUpdate(&initial_update, .baseline, .{});
    defer receiver.deinit();

    var presentation_source = try captureTestScene(alloc);
    defer presentation_source.deinit();
    presentation_source.presentation.ref.sequence = 18;
    const presentation_bytes = try encodeAlloc(alloc, &presentation_source, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .unchanged,
        .presentation_kind = .full,
    }, .{});
    defer alloc.free(presentation_bytes);
    var expectation = test_decode_expectation;
    expectation.canonical_ref = receiver.canonical.ref;
    expectation.presentation_ref = receiver.presentation.ref;
    var presentation_update = try decodeAlloc(
        alloc,
        presentation_bytes,
        expectation,
        .{},
    );
    defer presentation_update.deinit();
    try std.testing.expect(presentation_update.canonical == .unchanged);
    try applyUpdate(&receiver, &presentation_update, .baseline, .{});
    try std.testing.expectEqual(@as(u64, 42), receiver.canonical.ref.content_sequence);
    try std.testing.expectEqual(@as(u64, 18), receiver.presentation.ref.sequence);

    var canonical_source = try captureTestScene(alloc);
    defer canonical_source.deinit();
    canonical_source.canonical.ref.content_sequence = 43;
    canonical_source.presentation.ref.sequence = 18;
    const canonical_bytes = try encodeAlloc(alloc, &canonical_source, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .full,
        .presentation_kind = .unchanged,
    }, .{});
    defer alloc.free(canonical_bytes);
    expectation.canonical_ref = receiver.canonical.ref;
    expectation.presentation_ref = receiver.presentation.ref;
    var canonical_update = try decodeAlloc(
        alloc,
        canonical_bytes,
        expectation,
        .{},
    );
    defer canonical_update.deinit();
    try std.testing.expect(canonical_update.presentation == .unchanged);
    try applyUpdate(&receiver, &canonical_update, .baseline, .{});
    try std.testing.expectEqual(@as(u64, 43), receiver.canonical.ref.content_sequence);
    try std.testing.expectEqual(@as(u64, 18), receiver.presentation.ref.sequence);
}

test "scene receiver preserves provenance and uses metadata fast path" {
    const alloc = std.testing.allocator;
    var receiver = try Receiver.init(alloc, .{
        .terminal_id = test_terminal_id,
        .terminal_epoch = test_canonical_ref.terminal_epoch,
        .presentation_id = test_presentation_id,
        .presentation_generation = test_presentation_ref.generation,
    });
    defer receiver.deinit();

    var initial = try captureTestScene(alloc);
    defer initial.deinit();
    const initial_bytes = try encodeAlloc(
        alloc,
        &initial,
        test_encode_options,
        .{},
    );
    defer alloc.free(initial_bytes);
    try std.testing.expectEqual(
        Receiver.ApplyKind.initial,
        try receiver.apply(initial_bytes),
    );

    var metadata = try captureTestScene(alloc);
    defer metadata.deinit();
    metadata.presentation.ref.sequence += 1;
    metadata.presentation.content.focused = false;
    metadata.presentation.content.cursor_blink_visible = false;
    const metadata_bytes = try encodeAlloc(alloc, &metadata, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .unchanged,
        .presentation_kind = .full,
    }, .{});
    defer alloc.free(metadata_bytes);
    try std.testing.expectEqual(
        Receiver.ApplyKind.presentation_metadata,
        try receiver.apply(metadata_bytes),
    );
    const projection = try receiver.projection();
    try std.testing.expect(!projection.focused);
    try std.testing.expect(!projection.cursor_blink_visible);
    try std.testing.expectEqual(
        @as(u64, 42),
        (try receiver.current()).canonical.ref.content_sequence,
    );
    try std.testing.expectEqual(
        @as(u64, 18),
        (try receiver.current()).presentation.ref.sequence,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        receiver.stats.presentation_metadata_fast_paths,
    );

    var canonical = try captureTestScene(alloc);
    defer canonical.deinit();
    canonical.canonical.ref.content_sequence += 1;
    canonical.presentation.ref.sequence += 1;
    canonical.presentation.content.focused = false;
    canonical.presentation.content.cursor_blink_visible = false;
    canonical.canonical.content.rows[0].cells[0].content = .{ .codepoint = 'Z' };
    const canonical_bytes = try encodeAlloc(alloc, &canonical, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .full,
        .presentation_kind = .unchanged,
    }, .{});
    defer alloc.free(canonical_bytes);
    try std.testing.expectEqual(
        Receiver.ApplyKind.rematerialized,
        try receiver.apply(canonical_bytes),
    );
    try std.testing.expectEqual(
        @as(u21, 'Z'),
        (try receiver.projection()).terminal_state.row_data.items(.cells)[0]
            .get(0).raw.codepoint(),
    );
    try std.testing.expectEqual(@as(u64, 2), receiver.stats.rematerializations);
}

test "scene receiver decodes and applies canonical row deltas" {
    const alloc = std.testing.allocator;
    var receiver = try Receiver.init(alloc, .{
        .terminal_id = test_terminal_id,
        .terminal_epoch = test_canonical_ref.terminal_epoch,
        .presentation_id = test_presentation_id,
        .presentation_generation = test_presentation_ref.generation,
    });
    defer receiver.deinit();
    var initial = try captureTestScene(alloc);
    defer initial.deinit();
    const full = try encodeAlloc(alloc, &initial, test_encode_options, .{});
    defer alloc.free(full);
    _ = try receiver.apply(full);

    var changed = try captureTestScene(alloc);
    defer changed.deinit();
    changed.canonical.ref.content_sequence += 1;
    changed.presentation.ref.sequence += 1;
    changed.canonical.content.rows[0].cells[1].content = .{ .codepoint = 'Q' };
    const delta = try encodeAlloc(alloc, &changed, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .delta,
        .presentation_kind = .full,
        .canonical_base = &initial.canonical,
    }, .{});
    defer alloc.free(delta);
    try std.testing.expectEqual(
        Receiver.ApplyKind.rematerialized,
        try receiver.apply(delta),
    );
    try std.testing.expectEqual(
        @as(u21, 'Q'),
        (try receiver.projection()).terminal_state.row_data.items(.cells)[0]
            .get(1).raw.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u64, test_canonical_ref.content_sequence + 1),
        (try receiver.current()).canonical.ref.content_sequence,
    );
}

test "canonical row delta is bounded smaller and replay fenced" {
    const alloc = std.testing.allocator;
    var base = try captureTestScene(alloc);
    defer base.deinit();
    try expandTestBacking(&base, 32, 1);
    base.presentation.content.selections = &.{};
    base.presentation.content.highlights = &.{};
    base.presentation.content.active_links = &.{};
    base.presentation.content.hover = null;
    base.presentation.content.cursor_viewport = null;

    var current = try captureTestScene(alloc);
    defer current.deinit();
    try expandTestBacking(&current, 32, 1);
    current.presentation.content.selections = &.{};
    current.presentation.content.highlights = &.{};
    current.presentation.content.active_links = &.{};
    current.presentation.content.hover = null;
    current.presentation.content.cursor_viewport = null;
    current.canonical.ref.content_sequence += 1;
    current.canonical.content.rows[17].cells[0].content = .{ .codepoint = 'Z' };

    const full = try encodeAlloc(alloc, &current, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .full,
        .presentation_kind = .unchanged,
    }, .{});
    defer alloc.free(full);
    const delta = try encodeAlloc(alloc, &current, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .delta,
        .presentation_kind = .unchanged,
        .canonical_base = &base.canonical,
    }, .{});
    defer alloc.free(delta);
    try std.testing.expect(delta.len < full.len / 2);

    var expectation = test_decode_expectation;
    expectation.canonical_ref = base.canonical.ref;
    expectation.canonical_cache = &base.canonical;
    expectation.presentation_ref = base.presentation.ref;
    var update = try decodeAlloc(alloc, delta, expectation, .{});
    defer update.deinit();
    try std.testing.expect(update.canonical == .full);
    try std.testing.expectEqual(
        'Z',
        update.canonical.full.value.content.rows[17].cells[0].content.codepoint,
    );
    try validatePair(
        &update.canonical.full.value,
        &base.presentation,
        .baseline,
        .{},
    );

    var wrong_base = try alloc.dupe(u8, delta);
    defer alloc.free(wrong_base);
    std.mem.writeInt(u64, wrong_base[wire_header_size..][0..8], 1, .little);
    try std.testing.expectError(
        error.ReplayRejected,
        decodeAlloc(alloc, wrong_base, expectation, .{}),
    );
}

test "presentation metadata update performs zero canonical work" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    var materialized = try Materialized.init(alloc, &scene, .baseline, .{});
    defer materialized.deinit(alloc);
    materialized.state.dirty = .false;
    @memset(materialized.state.row_data.items(.dirty), false);

    const previous = scene.presentation;
    var next = previous;
    next.ref.sequence += 1;
    next.content.focused = !previous.content.focused;
    next.content.cursor_blink_visible = !previous.content.cursor_blink_visible;
    var recorder: ProjectionRecorder = .{};
    try projectPresentationMetadata(
        &materialized,
        &scene.canonical,
        &previous,
        &next,
        .{},
        &recorder,
    );
    try std.testing.expectEqual(@as(usize, 0), recorder.canonical_rows_read);
    try std.testing.expectEqual(next.content.focused, recorder.focused);
    try std.testing.expectEqual(
        next.content.cursor_blink_visible,
        recorder.cursor_blink_visible,
    );
    try std.testing.expect(materialized.state.dirty == .false);
    for (materialized.state.row_data.items(.dirty)) |dirty|
        try std.testing.expect(!dirty);
}

test "unchanged canonical section decodes without allocating" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    scene.presentation.ref.sequence = 18;
    scene.presentation.content.selections = &.{};
    scene.presentation.content.highlights = &.{};
    scene.presentation.content.active_links = &.{};
    scene.presentation.content.preedit = &.{};
    scene.presentation.content.overlay_features = &.{};
    scene.presentation.content.hover = null;
    const encoded = try encodeAlloc(alloc, &scene, .{
        .supported_capabilities = .baseline,
        .canonical_kind = .unchanged,
        .presentation_kind = .full,
    }, .{});
    defer alloc.free(encoded);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    var expectation = test_decode_expectation;
    expectation.canonical_ref = test_canonical_ref;
    expectation.presentation_ref = test_presentation_ref;
    var wrong_ref = try alloc.dupe(u8, encoded);
    defer alloc.free(wrong_ref);
    std.mem.writeInt(u64, wrong_ref[48..56], 43, .little);
    try std.testing.expectError(
        error.ReplayRejected,
        decodeAlloc(failing.allocator(), wrong_ref, expectation, .{}),
    );
    try std.testing.expect(!failing.has_induced_failure);
    var update = try decodeAlloc(
        failing.allocator(),
        encoded,
        expectation,
        .{},
    );
    defer update.deinit();
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(update.canonical == .unchanged);
}

test "codec rejects wrong presentation and missing capability negotiation" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const encoded = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(encoded);

    var wrong = test_decode_expectation;
    wrong.presentation_id[0] ^= 0xFF;
    try std.testing.expectError(
        error.WrongPresentation,
        decodeAlloc(alloc, encoded, wrong, .{}),
    );
    wrong = test_decode_expectation;
    wrong.supported_capabilities = .{ .bits = 0 };
    try std.testing.expectError(
        error.UnsupportedCapability,
        decodeAlloc(alloc, encoded, wrong, .{}),
    );

    var malformed = try alloc.dupe(u8, encoded);
    defer alloc.free(malformed);
    std.mem.writeInt(u64, malformed[8..16], 0, .little);
    try std.testing.expectError(
        error.InvalidCapabilityManifest,
        decodeAlloc(alloc, malformed, test_decode_expectation, .{}),
    );
}

test "codec enforces allocation budget before arena growth" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const encoded = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(encoded);
    var limits: Limits = .{};
    limits.max_allocation_bytes = 1;
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.LimitExceeded,
        decodeAlloc(
            failing.allocator(),
            encoded,
            test_decode_expectation,
            limits,
        ),
    );
    try std.testing.expect(!failing.has_induced_failure);
}

test "capture and decode survive every allocation failure" {
    const alloc = std.testing.allocator;
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    var term = try terminal.Terminal.init(alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("AB");
    try state.update(alloc, &term);
    const options: CaptureOptions = .{
        .canonical_ref = test_canonical_ref,
        .canonical_base_content_sequence = null,
        .canonical_row_start = 0,
        .presentation_ref = test_presentation_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = null,
        .link_cells = null,
        .scrollbar = .{ .total = 1, .offset = 0, .len = 1, .row_space_revision = 9 },
        .overlay_features = &.{},
        .hover = null,
        .focused = false,
        .cursor_blink_visible = false,
        .image_count = 0,
        .custom_shader_count = 0,
    };
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        if (captureAlloc(failing.allocator(), &state, options, .{})) |value| {
            var captured = value;
            captured.deinit();
            if (!failing.has_induced_failure) break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }

    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const encoded = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(encoded);
    fail_index = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        if (decodeAlloc(
            failing.allocator(),
            encoded,
            test_decode_expectation,
            .{},
        )) |value| {
            var update = value;
            update.deinit();
            if (!failing.has_induced_failure) break;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "actual allocation budget counts allocator traffic" {
    const alloc = std.testing.allocator;
    const budget = try AllocationBudget.create(alloc, 16);
    defer budget.release();
    const bounded = budget.allocator();
    const first = try bounded.alloc(u8, 16);
    try std.testing.expectError(error.OutOfMemory, bounded.alloc(u8, 1));
    bounded.free(first);
    const second = try bounded.alloc(u8, 16);
    bounded.free(second);
}

test "codec rejects ambiguous bases unknown capabilities and sequence exhaustion" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const encoded = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(encoded);

    var reserved_header = try alloc.dupe(u8, encoded);
    defer alloc.free(reserved_header);
    reserved_header[18] = 1;
    try std.testing.expectError(
        error.InvalidHeader,
        decodeAlloc(alloc, reserved_header, test_decode_expectation, .{}),
    );

    var unknown_capability = try alloc.dupe(u8, encoded);
    defer alloc.free(unknown_capability);
    std.mem.writeInt(
        u64,
        unknown_capability[8..16],
        std.mem.readInt(u64, unknown_capability[8..16], .little) | (@as(u64, 1) << 63),
        .little,
    );
    try std.testing.expectError(
        error.InvalidCapabilityManifest,
        decodeAlloc(alloc, unknown_capability, test_decode_expectation, .{}),
    );

    var exhausted = test_decode_expectation;
    var exhausted_ref = test_canonical_ref;
    exhausted_ref.content_sequence = std.math.maxInt(u64);
    exhausted.canonical_ref = exhausted_ref;
    try std.testing.expectError(
        error.ReplayRejected,
        decodeAlloc(alloc, encoded, exhausted, .{}),
    );
    try std.testing.expectError(
        error.Truncated,
        decodeAlloc(
            alloc,
            encoded[0 .. wire_header_size - 1],
            test_decode_expectation,
            .{},
        ),
    );
}

test "validation binds presentation to terminal row space not content sequence" {
    var scene = try captureTestScene(std.testing.allocator);
    defer scene.deinit();
    scene.canonical.ref.content_sequence += 1;
    try validateOwned(&scene, .baseline, .{});
    scene.presentation.terminal_space.row_space_revision += 1;
    try std.testing.expectError(
        error.InvalidIdentity,
        validateOwned(&scene, .baseline, .{}),
    );
}

test "owned scene materializes the legacy projection inputs" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    var materialized = try Materialized.init(alloc, &scene, .baseline, .{});
    defer materialized.deinit(alloc);
    const projection = materialized.projection();
    try std.testing.expectEqual(@as(terminal.size.CellCountInt, 1), projection.terminal_state.rows);
    try std.testing.expectEqual('A', projection.terminal_state.row_data.items(.cells)[0].get(0).raw.codepoint());
    try std.testing.expectEqual(@as(?[2]terminal.size.CellCountInt, .{ 0, 1 }), projection.terminal_state.row_data.items(.selection)[0]);
    try std.testing.expect(projection.link_cells.contains(.{ .x = 0, .y = 0 }));
    try std.testing.expect(projection.focused);
    try std.testing.expect(projection.cursor_blink_visible);
    try std.testing.expectEqual(@as(usize, 1), projection.preedit.?.codepoints.len);
}

test "production owned projector matches borrowed projection semantics" {
    const alloc = std.testing.allocator;
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    var term = try terminal.Terminal.init(alloc, .{ .cols = 4, .rows = 1 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b]8;id=docs;https://example.com\x1b\\AB\x1b]8;;\x1b\\");
    try state.update(alloc, &term);
    state.row_data.items(.selection)[0] = .{ 0, 1 };
    var row_arena = state.row_data.items(.arena)[0].promote(alloc);
    defer state.row_data.items(.arena)[0] = row_arena.state;
    try state.row_data.items(.highlights)[0].append(row_arena.allocator(), .{
        .tag = @intFromEnum(HighlightKind.search_match_selected),
        .range = .{ 1, 1 },
    });
    var links: terminal.RenderState.CellSet = .empty;
    defer links.deinit(alloc);
    try links.put(alloc, .{ .x = 0, .y = 0 }, {});
    const preedit: Preedit = .{
        .codepoints = &.{.{ .codepoint = 0xAC00, .wide = true }},
    };
    const scrollbar: terminal.Scrollbar = .{
        .total = 1,
        .offset = 0,
        .len = 1,
        .row_space_revision = 9,
    };
    const overlay = [_]OverlayFeature{.semantic_prompts};
    const hover: terminal.point.Coordinate = .{ .x = 0, .y = 0 };
    var expected: ProjectionRecorder = .{};
    try expected.projectScene(.{
        .terminal_state = &state,
        .preedit = preedit,
        .link_cells = &links,
        .scrollbar = scrollbar,
        .overlay_features = &overlay,
        .hover = hover,
        .focused = true,
        .cursor_blink_visible = true,
    });

    var captured = try captureAlloc(alloc, &state, .{
        .canonical_ref = test_canonical_ref,
        .canonical_base_content_sequence = null,
        .canonical_row_start = 0,
        .presentation_ref = test_presentation_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = preedit,
        .link_cells = &links,
        .scrollbar = scrollbar,
        .overlay_features = &overlay,
        .hover = hover,
        .focused = true,
        .cursor_blink_visible = true,
        .image_count = 0,
        .custom_shader_count = 0,
    }, .{});
    defer captured.deinit();
    const encoded = try encodeAlloc(alloc, &captured, test_encode_options, .{});
    defer alloc.free(encoded);
    var update = try decodeAlloc(alloc, encoded, test_decode_expectation, .{});
    defer update.deinit();
    var decoded = try ownedFromInitialUpdate(&update, .baseline, .{});
    defer decoded.deinit();
    var actual: ProjectionRecorder = .{};
    try projectOwned(alloc, &decoded, .baseline, .{}, &actual);
    try std.testing.expectEqualDeep(expected, actual);
}

test "canonical backing supports two independent scroll presentations" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    try expandTestBacking(&scene, 2, 1);
    scene.presentation.content.selections = &.{};
    scene.presentation.content.highlights = &.{};
    scene.presentation.content.active_links = &.{};
    scene.presentation.content.hover = null;
    scene.presentation.content.cursor_viewport = null;

    var first = try Materialized.init(alloc, &scene, .baseline, .{});
    defer first.deinit(alloc);
    try std.testing.expectEqual(
        'A',
        first.state.row_data.items(.cells)[0].get(0).raw.codepoint(),
    );
    const canonical_ref = scene.canonical.ref;

    scene.presentation.ref.presentation_id[0] ^= 0x5A;
    scene.presentation.ref.generation = 1;
    scene.presentation.ref.sequence = 1;
    scene.presentation.content.scrollbar.offset = 1;
    var second = try Materialized.init(alloc, &scene, .baseline, .{});
    defer second.deinit(alloc);
    try std.testing.expectEqual(
        'B',
        second.state.row_data.items(.cells)[0].get(0).raw.codepoint(),
    );
    try std.testing.expectEqual(
        'A',
        first.state.row_data.items(.cells)[0].get(0).raw.codepoint(),
    );
    try std.testing.expect(ValidationImpl.canonicalRefEqual(
        canonical_ref,
        scene.canonical.ref,
    ));
}

test "production capture shares real scrollback across concurrent presentations" {
    const alloc = std.testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 4, .rows = 2 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice("A\r\nB\r\nC\r\nD");

    var active_state: terminal.RenderState = .empty;
    defer active_state.deinit(alloc);
    try active_state.update(alloc, &term);
    const scrollbar = term.screens.active.pages.scrollbar();
    try std.testing.expect(scrollbar.total > scrollbar.len);
    var canonical_ref = test_canonical_ref;
    canonical_ref.row_space_revision = scrollbar.row_space_revision;
    var backing = try terminal.RenderState.captureRows(
        alloc,
        &term,
        0,
        scrollbar.total,
    );
    defer backing.deinit(alloc);

    var active_scene = try captureAlloc(alloc, &active_state, .{
        .canonical_ref = canonical_ref,
        .canonical_base_content_sequence = null,
        .canonical_state = &backing,
        .canonical_row_start = 0,
        .presentation_ref = test_presentation_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = null,
        .link_cells = null,
        .scrollbar = scrollbar,
        .overlay_features = &.{},
        .hover = null,
        .focused = true,
        .cursor_blink_visible = true,
        .image_count = 0,
        .custom_shader_count = 0,
    }, .{});

    term.scrollViewport(.top);
    var top_state: terminal.RenderState = .empty;
    defer top_state.deinit(alloc);
    try top_state.update(alloc, &term);
    var top_ref = test_presentation_ref;
    top_ref.presentation_id[0] ^= 0x7F;
    top_ref.generation = 1;
    top_ref.sequence = 1;
    var top_scene = try captureAlloc(alloc, &top_state, .{
        .canonical_ref = canonical_ref,
        .canonical_base_content_sequence = null,
        .canonical_state = &backing,
        .canonical_row_start = 0,
        .presentation_ref = top_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = null,
        .link_cells = null,
        .scrollbar = term.screens.active.pages.scrollbar(),
        .overlay_features = &.{},
        .hover = null,
        .focused = false,
        .cursor_blink_visible = false,
        .image_count = 0,
        .custom_shader_count = 0,
    }, .{});

    var active_cache = splitOwned(&active_scene);
    defer active_cache.canonical.deinit();
    defer active_cache.presentation.deinit();
    var top_cache = splitOwned(&top_scene);
    defer top_cache.canonical.deinit();
    defer top_cache.presentation.deinit();
    var active_materialized = try Materialized.initCached(
        alloc,
        cachedView(&active_cache.canonical, &active_cache.presentation),
        .baseline,
        .{},
    );
    defer active_materialized.deinit(alloc);
    var top_materialized = try Materialized.initCached(
        alloc,
        cachedView(&active_cache.canonical, &top_cache.presentation),
        .baseline,
        .{},
    );
    defer top_materialized.deinit(alloc);

    try std.testing.expectEqual(
        'A',
        top_materialized.state.row_data.items(.cells)[0].get(0).raw.codepoint(),
    );
    try std.testing.expectEqual(
        'C',
        active_materialized.state.row_data.items(.cells)[0].get(0).raw.codepoint(),
    );
    try std.testing.expect(active_cache.canonical.section.value.content.rows.len >
        active_cache.canonical.section.value.content.bounds.rows);
}

test "materialization preserves cursor cell background and wide roles" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    scene.canonical.content.cursor.cell = .{
        .content = .{ .background_rgb = .{ .r = 7, .g = 8, .b = 9 } },
        .wide_role = .wide,
    };
    var wide = try Materialized.init(alloc, &scene, .baseline, .{});
    defer wide.deinit(alloc);
    try std.testing.expectEqual(terminal.page.Cell.ContentTag.bg_color_rgb, wide.state.cursor.cell.content_tag);
    try std.testing.expectEqual(terminal.page.Cell.Wide.wide, wide.state.cursor.cell.wide);
    try std.testing.expectEqual(@as(u8, 7), wide.state.cursor.cell.content.color_rgb.r);

    scene.canonical.content.cursor.cell.wide_role = .spacer_tail;
    if (scene.presentation.content.cursor_viewport) |*viewport|
        viewport.wide_tail = true;
    var spacer = try Materialized.init(alloc, &scene, .baseline, .{});
    defer spacer.deinit(alloc);
    try std.testing.expectEqual(terminal.page.Cell.Wide.spacer_tail, spacer.state.cursor.cell.wide);
}

test "validation rejects malformed wide cell topology" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const cells = scene.canonical.content.rows[0].cells;

    cells[0].wide_role = .wide;
    try std.testing.expectError(
        error.InvalidScene,
        validateOwned(&scene, .baseline, .{}),
    );
    cells[1].wide_role = .spacer_tail;
    try validateOwned(&scene, .baseline, .{});

    cells[0].wide_role = .spacer_tail;
    cells[1].wide_role = .narrow;
    try std.testing.expectError(
        error.InvalidScene,
        validateOwned(&scene, .baseline, .{}),
    );
    cells[0].wide_role = .narrow;
    cells[cells.len - 1].wide_role = .spacer_head;
    scene.canonical.content.rows[0].wrap = false;
    try std.testing.expectError(
        error.InvalidScene,
        validateOwned(&scene, .baseline, .{}),
    );
}

test "highlight materialization preserves producer precedence order" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    scene.presentation.content.selections = &.{};
    const highlights = try scene.presentation_arena.allocator().alloc(Highlight, 2);
    const anchor = scene.canonical.content.rows[0].anchor;
    highlights[0] = .{
        .row = anchor,
        .start = 2,
        .end = 2,
        .kind = .search_match_selected,
    };
    highlights[1] = .{
        .row = anchor,
        .start = 0,
        .end = 3,
        .kind = .search_match,
    };
    scene.presentation.content.highlights = highlights;
    try validateOwned(&scene, .baseline, .{});
    var materialized = try Materialized.init(alloc, &scene, .baseline, .{});
    defer materialized.deinit(alloc);
    const actual = materialized.state.row_data.items(.highlights)[0].items;
    try std.testing.expectEqual(@as(usize, 2), actual.len);
    try std.testing.expectEqual(
        @intFromEnum(HighlightKind.search_match_selected),
        actual[0].tag,
    );
    try std.testing.expectEqual(
        @intFromEnum(HighlightKind.search_match),
        actual[1].tag,
    );
}

test "materialization annotation grouping is linear at configured maxima" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    const row_count = 32;
    const highlight_count = 1024;
    try expandTestBacking(&scene, row_count, row_count);
    const selections = try scene.presentation_arena.allocator().alloc(
        ColumnRange,
        row_count,
    );
    for (selections, 0..) |*selection, row_index| selection.* = .{
        .row = scene.canonical.content.rows[row_index].anchor,
        .start = 0,
        .end = 0,
    };
    scene.presentation.content.selections = selections;
    scene.presentation.content.active_links = &.{};
    scene.presentation.content.hover = null;
    const highlights = try scene.presentation_arena.allocator().alloc(
        Highlight,
        highlight_count,
    );
    for (highlights, 0..) |*highlight, index| {
        const row_index = index / (highlight_count / row_count);
        highlight.* = .{
            .row = scene.canonical.content.rows[row_index].anchor,
            .start = @intCast(index % 4),
            .end = @intCast(index % 4),
            .kind = if (index % 2 == 0)
                .search_match_selected
            else
                .search_match,
        };
    }
    scene.presentation.content.highlights = highlights;
    var limits: Limits = .{};
    limits.max_rows = row_count;
    limits.max_highlights = highlight_count;
    var stats: Materialized.Stats = .{};
    var materialized = try Materialized.initWithStats(
        alloc,
        &scene,
        .baseline,
        limits,
        &stats,
    );
    defer materialized.deinit(alloc);
    try std.testing.expectEqual(@as(usize, row_count), stats.rows_visited);
    try std.testing.expect(stats.highlight_steps >= highlight_count);
    try std.testing.expect(stats.highlight_steps <= highlight_count + row_count);
    try std.testing.expectEqual(@as(usize, row_count), stats.selection_steps);
}

test "materialized scene owns all data after source deinit" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    const grapheme = try scene.canonical_arena.allocator().dupe(
        u21,
        &.{ 'A', 0x0301 },
    );
    scene.canonical.content.rows[0].cells[0].content = .{ .grapheme = grapheme };
    var materialized = try Materialized.init(alloc, &scene, .baseline, .{});
    defer materialized.deinit(alloc);
    scene.deinit();
    const projection = materialized.projection();
    try std.testing.expectEqual(
        'A',
        projection.terminal_state.row_data.items(.cells)[0].get(0).raw.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, 0x0301),
        projection.terminal_state.row_data.items(.cells)[0].get(0).grapheme[0],
    );
    try std.testing.expectEqual(@as(u21, 0xAC00), projection.preedit.?.codepoints[0].codepoint);
    try std.testing.expectEqual(OverlayFeature.semantic_prompts, projection.overlay_features[0]);
}

test "materializer survives every allocation failure and enforces budget" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            alloc,
            .{ .fail_index = fail_index },
        );
        if (Materialized.init(failing.allocator(), &scene, .baseline, .{})) |value| {
            var materialized = value;
            materialized.deinit(failing.allocator());
            if (!failing.has_induced_failure) break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    var limits: Limits = .{};
    limits.max_allocation_bytes = 1;
    try std.testing.expectError(
        error.LimitExceeded,
        Materialized.init(alloc, &scene, .baseline, limits),
    );
}

test "wrap chains validate every interior edge" {
    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    try expandTestBacking(&scene, 2, 2);
    scene.canonical.content.rows[0].wrap = true;
    scene.canonical.content.rows[1].wrap_continuation = false;
    try std.testing.expectError(
        error.InvalidScene,
        validateOwned(&scene, .baseline, .{}),
    );
    scene.canonical.content.rows[1].wrap_continuation = true;
    try validateOwned(&scene, .baseline, .{});
}

test "scene sequences reach max once and never roll over" {
    try std.testing.expectError(error.InvalidSequence, nextSequence(0));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        try nextSequence(std.math.maxInt(u64) - 1),
    );
    try std.testing.expectError(
        error.SequenceExhausted,
        nextSequence(std.math.maxInt(u64)),
    );

    const alloc = std.testing.allocator;
    var scene = try captureTestScene(alloc);
    defer scene.deinit();
    scene.canonical.ref.content_sequence = std.math.maxInt(u64);
    scene.presentation.ref.sequence = std.math.maxInt(u64);
    const encoded = try encodeAlloc(alloc, &scene, test_encode_options, .{});
    defer alloc.free(encoded);
    var expectation = test_decode_expectation;
    var canonical_ref = test_canonical_ref;
    canonical_ref.content_sequence = std.math.maxInt(u64) - 1;
    var presentation_ref = test_presentation_ref;
    presentation_ref.sequence = std.math.maxInt(u64) - 1;
    expectation.canonical_ref = canonical_ref;
    expectation.presentation_ref = presentation_ref;
    var update = try decodeAlloc(alloc, encoded, expectation, .{});
    update.deinit();

    expectation.canonical_ref.?.content_sequence = std.math.maxInt(u64);
    try std.testing.expectError(
        error.ReplayRejected,
        decodeAlloc(alloc, encoded, expectation, .{}),
    );
}

test "capture rejects sequence wrap and inconsistent scrollbar" {
    const alloc = std.testing.allocator;
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    var term = try terminal.Terminal.init(alloc, .{ .cols = 1, .rows = 1 });
    defer term.deinit(alloc);
    try state.update(alloc, &term);
    var canonical = test_canonical_ref;
    canonical.content_sequence = 0;
    const options: CaptureOptions = .{
        .canonical_ref = canonical,
        .canonical_base_content_sequence = null,
        .canonical_row_start = 0,
        .presentation_ref = test_presentation_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = null,
        .link_cells = null,
        .scrollbar = .{ .total = 1, .offset = 1, .len = 1, .row_space_revision = 9 },
        .overlay_features = &.{},
        .hover = null,
        .focused = false,
        .cursor_blink_visible = false,
        .image_count = 0,
        .custom_shader_count = 0,
    };
    try std.testing.expectError(
        error.InvalidSequence,
        captureAlloc(alloc, &state, options, .{}),
    );
    var valid_sequence = options;
    valid_sequence.canonical_ref.content_sequence = 42;
    try std.testing.expectError(
        error.InvalidRange,
        captureAlloc(alloc, &state, valid_sequence, .{}),
    );

    var presentation_wrap = valid_sequence;
    presentation_wrap.scrollbar = .{
        .total = 1,
        .offset = 0,
        .len = 1,
        .row_space_revision = 9,
    };
    presentation_wrap.presentation_ref.sequence = 0;
    try std.testing.expectError(
        error.InvalidSequence,
        captureAlloc(alloc, &state, presentation_wrap, .{}),
    );
}

test "cutover eligibility fails closed for live GPU-only state" {
    const alloc = std.testing.allocator;
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    var term = try terminal.Terminal.init(alloc, .{ .cols = 1, .rows = 1 });
    defer term.deinit(alloc);
    try state.update(alloc, &term);
    try std.testing.expectEqual(
        CutoverEligibility.eligible,
        cutoverEligibility(&state, 0, 0),
    );
    try std.testing.expectEqual(
        CutoverEligibility.requires_renderer_custom_shader_state,
        cutoverEligibility(&state, 0, 1),
    );
    state.row_data.items(.raw)[0].kitty_virtual_placeholder = true;
    try std.testing.expectEqual(
        CutoverEligibility.requires_live_kitty_image_state,
        cutoverEligibility(&state, 0, 0),
    );

    var options: CaptureOptions = .{
        .canonical_ref = test_canonical_ref,
        .canonical_base_content_sequence = null,
        .canonical_row_start = 0,
        .presentation_ref = test_presentation_ref,
        .presentation_base_sequence = null,
        .required_capabilities = .baseline,
        .preedit = null,
        .link_cells = null,
        .scrollbar = .{ .total = 1, .offset = 0, .len = 1, .row_space_revision = 9 },
        .overlay_features = &.{},
        .hover = null,
        .focused = false,
        .cursor_blink_visible = false,
        .image_count = 0,
        .custom_shader_count = 0,
    };
    try std.testing.expectError(
        error.UnsupportedCapability,
        captureAlloc(alloc, &state, options, .{}),
    );
    state.row_data.items(.raw)[0].kitty_virtual_placeholder = false;
    options.custom_shader_count = 1;
    try std.testing.expectError(
        error.UnsupportedCapability,
        captureAlloc(alloc, &state, options, .{}),
    );
}
