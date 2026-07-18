//! Capture a self-contained semantic scene from a completed RenderState.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");

pub fn Capture(comptime Scene: type) type {
    return struct {
        const Limits = Scene.Limits;
        const Owned = Scene.Owned;
        const Row = Scene.Row;
        const Cell = Scene.Cell;
        const CellContent = Scene.CellContent;
        const Style = Scene.Style;
        const StyleColor = Scene.StyleColor;
        const RGB = Scene.RGB;
        const ColumnRange = Scene.ColumnRange;
        const Highlight = Scene.Highlight;
        const Coordinate = Scene.Coordinate;
        const RowAnchor = Scene.RowAnchor;
        const CursorViewport = Scene.CursorViewport;
        const Capability = Scene.Capability;
        const CapabilityManifest = Scene.CapabilityManifest;
        const OverlayFeature = Scene.OverlayFeature;

        pub const Options = struct {
            canonical_ref: Scene.CanonicalSceneRef,
            canonical_base_content_sequence: ?u64,
            /// Optional production backing snapshot. When present this owns
            /// canonical rows independently of the presentation viewport in
            /// `state`. It is normally created with RenderState.captureRows.
            canonical_state: ?*const terminal.RenderState = null,
            /// Absolute row represented by canonical_state.row_data[0]. This is
            /// explicit so canonical backing capture is never inferred from
            /// presentation scroll state.
            canonical_row_start: u64,
            presentation_ref: Scene.PresentationSceneRef,
            presentation_base_sequence: ?u64,
            required_capabilities: CapabilityManifest,
            /// Sparse terminal-authored color state. Config-derived defaults
            /// are presentation-local and must never enter canonical bytes.
            colors: Scene.Colors = .empty,
            preedit: ?Scene.Preedit,
            link_cells: ?*const terminal.RenderState.CellSet,
            scrollbar: terminal.Scrollbar,
            overlay_features: []const OverlayFeature,
            hover: ?terminal.point.Coordinate,
            focused: bool,
            cursor_blink_visible: bool,
            image_count: u32,
            custom_shader_count: u32,
        };

        pub const Error = Allocator.Error || error{
            InvalidDimensions,
            InvalidRenderState,
            InvalidCoordinate,
            InvalidRange,
            InvalidCodepoint,
            InvalidIdentity,
            InvalidSequence,
            InvalidCapabilityManifest,
            UnsupportedSnapshotKind,
            UnsupportedCapability,
            LimitExceeded,
        };

        const Preflight = struct {
            selection_count: usize,
            highlight_count: usize,
            active_link_count: usize,
            total_grapheme_codepoints: usize,
            allocation_bytes: usize,
        };

        pub fn capture(
            alloc: Allocator,
            state: *const terminal.RenderState,
            options: Options,
            limits: Limits,
        ) Error!Owned {
            try validateIdentity(options);

            const rows: u32 = state.rows;
            const columns: u32 = state.cols;
            const canonical_state = options.canonical_state orelse state;
            const canonical_rows: u32 = canonical_state.rows;
            if (rows == 0 or columns == 0) return error.InvalidDimensions;
            if (canonical_rows == 0 or canonical_state.cols != columns)
                return error.InvalidDimensions;
            if (canonical_rows > limits.max_rows or columns > limits.max_columns)
                return error.LimitExceeded;
            const cell_count = std.math.mul(usize, canonical_rows, columns) catch
                return error.LimitExceeded;
            if (cell_count > limits.max_cells) return error.LimitExceeded;
            if (state.row_data.len != rows) return error.InvalidRenderState;
            if (canonical_state.row_data.len != canonical_rows)
                return error.InvalidRenderState;
            if (options.overlay_features.len > limits.max_overlay_features or
                (options.preedit != null and
                    options.preedit.?.codepoints.len > limits.max_preedit_codepoints))
                return error.LimitExceeded;

            const scrollbar = try captureScrollbar(options.scrollbar, rows);
            if (scrollbar.row_space_revision != options.canonical_ref.row_space_revision)
                return error.InvalidIdentity;
            const canonical_end = std.math.add(
                u64,
                options.canonical_row_start,
                canonical_rows,
            ) catch return error.InvalidRange;
            const viewport_end = std.math.add(
                u64,
                scrollbar.offset,
                scrollbar.len,
            ) catch return error.InvalidRange;
            if (scrollbar.offset < options.canonical_row_start or
                viewport_end > canonical_end)
                return error.InvalidRange;

            const canonical_data = canonical_state.row_data.slice();
            const raw_rows = canonical_data.items(.raw);
            const render_cells = canonical_data.items(.cells);
            const row_hyperlinks = canonical_data.items(.hyperlinks);
            const presentation_data = state.row_data.slice();
            const row_selections = presentation_data.items(.selection);
            const row_highlights = presentation_data.items(.highlights);
            const preflight_result = try preflight(
                render_cells,
                row_selections,
                row_highlights,
                row_hyperlinks,
                options,
                canonical_rows,
                rows,
                columns,
                limits,
            );
            const allocation_budget = try Scene.AllocationBudget.create(
                alloc,
                limits.max_allocation_bytes,
            );
            errdefer allocation_budget.release();
            allocation_budget.retain();
            var canonical_arena = std.heap.ArenaAllocator.init(
                allocation_budget.allocator(),
            );
            errdefer canonical_arena.deinit();
            const canonical_alloc = canonical_arena.allocator();
            errdefer allocation_budget.release();
            allocation_budget.retain();
            var presentation_arena = std.heap.ArenaAllocator.init(
                allocation_budget.allocator(),
            );
            errdefer presentation_arena.deinit();
            errdefer allocation_budget.release();
            const presentation_alloc = presentation_arena.allocator();

            const bounds: Scene.Bounds = .{ .rows = rows, .columns = columns };
            const owned_rows = try canonical_alloc.alloc(Row, canonical_rows);
            var captured_graphemes: usize = 0;
            var observed_images = options.image_count;
            for (owned_rows, 0..) |*dst_row, row_index| {
                const raw_row = raw_rows[row_index];
                if (raw_row.kitty_virtual_placeholder)
                    observed_images = @max(observed_images, 1);

                const dst_cells = try canonical_alloc.alloc(Cell, columns);
                const cells = render_cells[row_index].slice();
                var hyperlink_index: usize = 0;
                for (dst_cells, 0..) |*dst_cell, column| {
                    const hyperlink: ?[16]u8 = link: {
                        if (hyperlink_index >= row_hyperlinks[row_index].len)
                            break :link null;
                        const entry = row_hyperlinks[row_index][hyperlink_index];
                        if (entry.column != column) break :link null;
                        hyperlink_index += 1;
                        break :link entry.semantic_identity;
                    };
                    dst_cell.* = try captureCell(
                        canonical_alloc,
                        cells.get(column),
                        hyperlink,
                        @intCast(column),
                        options.canonical_ref,
                        limits,
                        &captured_graphemes,
                    );
                }

                dst_row.* = .{
                    .anchor = try rowAnchor(
                        options.canonical_ref.row_space_revision,
                        options.canonical_row_start,
                        @intCast(row_index),
                    ),
                    .backing_index = @intCast(row_index),
                    .column_start = 0,
                    .column_count = columns,
                    .wrap = raw_row.wrap,
                    .wrap_continuation = raw_row.wrap_continuation,
                    .semantic_prompt = switch (raw_row.semantic_prompt) {
                        .none => .none,
                        .prompt => .prompt,
                        .prompt_continuation => .prompt_continuation,
                    },
                    .kitty_virtual_placeholder = raw_row.kitty_virtual_placeholder,
                    .cells = dst_cells,
                };
            }
            std.debug.assert(
                captured_graphemes == preflight_result.total_grapheme_codepoints,
            );

            const selections = try presentation_alloc.alloc(
                ColumnRange,
                preflight_result.selection_count,
            );
            const highlights = try presentation_alloc.alloc(
                Highlight,
                preflight_result.highlight_count,
            );
            var selection_index: usize = 0;
            var highlight_index: usize = 0;
            for (0..rows) |row_index| {
                const anchor = try rowAnchor(
                    options.canonical_ref.row_space_revision,
                    scrollbar.offset,
                    @intCast(row_index),
                );
                if (row_selections[row_index]) |range| {
                    if (range[0] > range[1] or range[1] >= columns)
                        return error.InvalidRange;
                    selections[selection_index] = .{
                        .row = anchor,
                        .start = range[0],
                        .end = range[1],
                    };
                    selection_index += 1;
                }

                for (row_highlights[row_index].items) |highlight| {
                    if (highlight.range[0] > highlight.range[1] or
                        highlight.range[1] >= columns)
                        return error.InvalidRange;
                    highlights[highlight_index] = .{
                        .row = anchor,
                        .start = highlight.range[0],
                        .end = highlight.range[1],
                        .kind = std.meta.intToEnum(
                            Scene.HighlightKind,
                            highlight.tag,
                        ) catch return error.InvalidRenderState,
                    };
                    highlight_index += 1;
                }
            }

            const active_links = try presentation_alloc.alloc(
                Coordinate,
                preflight_result.active_link_count,
            );
            var active_link_index: usize = 0;
            if (options.link_cells) |links| {
                for (0..rows) |row_index| {
                    for (0..columns) |column| {
                        if (!links.contains(.{
                            .x = @intCast(column),
                            .y = @intCast(row_index),
                        })) continue;
                        active_links[active_link_index] = .{
                            .row = try rowAnchor(
                                options.canonical_ref.row_space_revision,
                                scrollbar.offset,
                                @intCast(row_index),
                            ),
                            .column = @intCast(column),
                        };
                        active_link_index += 1;
                    }
                }
            }

            const preedit = if (options.preedit) |value|
                try presentation_alloc.dupe(Scene.PreeditCodepoint, value.codepoints)
            else
                try presentation_alloc.alloc(Scene.PreeditCodepoint, 0);
            for (preedit) |codepoint| try validateCodepoint(codepoint.codepoint);

            const overlay_features = try presentation_alloc.dupe(
                OverlayFeature,
                options.overlay_features,
            );
            sortOverlayFeatures(overlay_features) catch
                return error.InvalidRenderState;

            const hover: ?Coordinate = if (options.hover) |point| hover: {
                if (point.y >= rows or point.x >= columns)
                    return error.InvalidCoordinate;
                break :hover .{
                    .row = try rowAnchor(
                        options.canonical_ref.row_space_revision,
                        scrollbar.offset,
                        point.y,
                    ),
                    .column = point.x,
                };
            } else null;

            const active: Scene.ViewportCoordinate = .{
                .row = state.cursor.active.y,
                .column = state.cursor.active.x,
            };
            try validateViewportCoordinate(active, bounds);
            const viewport: ?CursorViewport = if (state.cursor.viewport) |value| viewport: {
                const coordinate: Scene.ViewportCoordinate = .{
                    .row = value.y,
                    .column = value.x,
                };
                try validateViewportCoordinate(coordinate, bounds);
                break :viewport .{
                    .coordinate = coordinate,
                    .wide_tail = value.wide_tail,
                };
            } else null;

            if (observed_images > 0 and
                (!options.required_capabilities.contains(.images) or
                    !options.required_capabilities.contains(.kitty_static_resources_v1)))
                return error.InvalidCapabilityManifest;
            if (options.custom_shader_count > 0 and
                !options.required_capabilities.contains(.custom_shaders))
                return error.InvalidCapabilityManifest;

            // Transfer the two retained references into Owned.
            allocation_budget.release();
            return .{
                .canonical_arena = canonical_arena,
                .presentation_arena = presentation_arena,
                .canonical_budget = allocation_budget,
                .presentation_budget = allocation_budget,
                .canonical = .{
                    .ref = options.canonical_ref,
                    .snapshot_kind = .full,
                    .base_content_sequence = options.canonical_base_content_sequence,
                    .required_capabilities = options.required_capabilities,
                    .content = .{
                        .bounds = bounds,
                        .row_start = options.canonical_row_start,
                        .row_total = scrollbar.total,
                        .screen = switch (state.screen) {
                            .primary => .primary,
                            .alternate => .alternate,
                        },
                        .colors = options.colors,
                        .cursor = .{
                            .active = active,
                            .cell = captureCursorCell(state.cursor.cell),
                            .style = captureStyle(state.cursor.style),
                            .visual_style = switch (state.cursor.visual_style) {
                                .bar => .bar,
                                .block => .block,
                                .underline => .underline,
                                .block_hollow => .block_hollow,
                            },
                            .password_input = state.cursor.password_input,
                            .visible = state.cursor.visible,
                            .blinking = state.cursor.blinking,
                        },
                        .rows = owned_rows,
                        .image_count = observed_images,
                    },
                },
                .presentation = .{
                    .ref = options.presentation_ref,
                    .snapshot_kind = .full,
                    .base_sequence = options.presentation_base_sequence,
                    .terminal_space = .{
                        .terminal_id = options.canonical_ref.terminal_id,
                        .terminal_epoch = options.canonical_ref.terminal_epoch,
                        .row_space_revision = options.canonical_ref.row_space_revision,
                    },
                    .content = .{
                        .selections = selections,
                        .highlights = highlights,
                        .active_links = active_links,
                        .preedit = preedit,
                        .overlay_features = overlay_features,
                        .hover = hover,
                        .cursor_viewport = viewport,
                        .focused = options.focused,
                        .cursor_blink_visible = options.cursor_blink_visible,
                        .scrollbar = .{
                            .offset = scrollbar.offset,
                            .len = scrollbar.len,
                            .row_space_revision = scrollbar.row_space_revision,
                        },
                        .custom_shader_count = options.custom_shader_count,
                    },
                },
            };
        }

        fn validateIdentity(options: Options) Error!void {
            if (Scene.identityIsZero(options.canonical_ref.terminal_id) or
                Scene.identityIsZero(options.presentation_ref.presentation_id))
                return error.InvalidIdentity;
            if (options.canonical_ref.terminal_epoch == 0 or
                options.canonical_ref.content_sequence == 0 or
                options.presentation_ref.generation == 0 or
                options.presentation_ref.sequence == 0)
                return error.InvalidSequence;
            if (options.canonical_base_content_sequence != null or
                options.presentation_base_sequence != null)
                return error.UnsupportedSnapshotKind;
            if (!options.required_capabilities.validRequired())
                return error.InvalidCapabilityManifest;
        }

        /// Static Kitty resources are now transportable. The capture boundary
        /// remains eligible unless a future unsupported renderer-only feature
        /// is added explicitly.
        pub fn cutoverEligibility(
            canonical_state: *const terminal.RenderState,
            image_count: u32,
        ) Scene.CutoverEligibility {
            _ = canonical_state;
            _ = image_count;
            return .eligible;
        }

        fn preflight(
            render_cells: []const std.MultiArrayList(terminal.RenderState.Cell),
            row_selections: []const ?[2]terminal.size.CellCountInt,
            row_highlights: []const std.ArrayList(terminal.RenderState.Highlight),
            row_hyperlinks: []const []const terminal.RenderState.HyperlinkCell,
            options: Options,
            canonical_rows: u32,
            presentation_rows: u32,
            columns: u32,
            limits: Limits,
        ) Error!Preflight {
            var selection_count: usize = 0;
            var highlight_count: usize = 0;
            var active_link_count: usize = 0;
            var grapheme_count: usize = 0;
            for (0..canonical_rows) |row_index| {
                if (render_cells[row_index].len != columns)
                    return error.InvalidRenderState;

                const cells = render_cells[row_index].slice();
                var hyperlink_index: usize = 0;
                for (0..columns) |column| {
                    const cell = cells.get(column);
                    if (cell.raw.content_tag == .codepoint_grapheme) {
                        const count = std.math.add(usize, cell.grapheme.len, 1) catch
                            return error.LimitExceeded;
                        if (count > limits.max_grapheme_codepoints_per_cell)
                            return error.LimitExceeded;
                        grapheme_count = std.math.add(
                            usize,
                            grapheme_count,
                            count,
                        ) catch return error.LimitExceeded;
                        if (grapheme_count > limits.max_total_grapheme_codepoints)
                            return error.LimitExceeded;
                    }
                    const has_copied_hyperlink = if (hyperlink_index < row_hyperlinks[row_index].len and
                        row_hyperlinks[row_index][hyperlink_index].column == column)
                    copied: {
                        hyperlink_index += 1;
                        break :copied true;
                    } else false;
                    if (cell.raw.hyperlink != has_copied_hyperlink)
                        return error.InvalidRenderState;
                    if (options.link_cells) |links| {
                        const presentation_row = std.math.sub(
                            u64,
                            options.scrollbar.offset,
                            options.canonical_row_start,
                        ) catch return error.InvalidRange;
                        if (row_index >= presentation_row and
                            row_index - presentation_row < presentation_rows and
                            links.contains(.{
                                .x = @intCast(column),
                                .y = @intCast(row_index - presentation_row),
                            })) active_link_count = std.math.add(
                            usize,
                            active_link_count,
                            1,
                        ) catch return error.LimitExceeded;
                    }
                }
                if (hyperlink_index != row_hyperlinks[row_index].len)
                    return error.InvalidRenderState;
            }

            for (0..presentation_rows) |row_index| {
                if (row_selections[row_index] != null) selection_count += 1;
                highlight_count = std.math.add(
                    usize,
                    highlight_count,
                    row_highlights[row_index].items.len,
                ) catch return error.LimitExceeded;
                if (highlight_count > limits.max_highlights)
                    return error.LimitExceeded;
            }

            var bytes: usize = 0;
            try addAllocation(&bytes, canonical_rows, @sizeOf(Row), limits);
            const cell_count = std.math.mul(usize, canonical_rows, columns) catch
                return error.LimitExceeded;
            try addAllocation(&bytes, cell_count, @sizeOf(Cell), limits);
            try addAllocation(&bytes, grapheme_count, @sizeOf(u21), limits);
            try addAllocation(&bytes, selection_count, @sizeOf(ColumnRange), limits);
            try addAllocation(&bytes, highlight_count, @sizeOf(Highlight), limits);
            try addAllocation(&bytes, active_link_count, @sizeOf(Coordinate), limits);
            try addAllocation(
                &bytes,
                if (options.preedit) |value| value.codepoints.len else 0,
                @sizeOf(Scene.PreeditCodepoint),
                limits,
            );
            try addAllocation(
                &bytes,
                options.overlay_features.len,
                @sizeOf(OverlayFeature),
                limits,
            );
            return .{
                .selection_count = selection_count,
                .highlight_count = highlight_count,
                .active_link_count = active_link_count,
                .total_grapheme_codepoints = grapheme_count,
                .allocation_bytes = bytes,
            };
        }

        fn addAllocation(
            total: *usize,
            count: usize,
            element_size: usize,
            limits: Limits,
        ) Error!void {
            const bytes = std.math.mul(usize, count, element_size) catch
                return error.LimitExceeded;
            total.* = std.math.add(usize, total.*, bytes) catch
                return error.LimitExceeded;
            if (total.* > limits.max_allocation_bytes)
                return error.LimitExceeded;
        }

        fn captureCell(
            alloc: Allocator,
            source: terminal.RenderState.Cell,
            hyperlink: ?[16]u8,
            column: u32,
            canonical_ref: Scene.CanonicalSceneRef,
            limits: Limits,
            captured_graphemes: *usize,
        ) Error!Cell {
            const raw = source.raw;
            const content: CellContent = switch (raw.content_tag) {
                .codepoint => codepoint: {
                    try validateCodepoint(raw.content.codepoint);
                    break :codepoint .{ .codepoint = raw.content.codepoint };
                },
                .codepoint_grapheme => grapheme: {
                    const count = std.math.add(usize, source.grapheme.len, 1) catch
                        return error.LimitExceeded;
                    if (count > limits.max_grapheme_codepoints_per_cell)
                        return error.LimitExceeded;
                    captured_graphemes.* = std.math.add(
                        usize,
                        captured_graphemes.*,
                        count,
                    ) catch return error.LimitExceeded;
                    const codepoints = try alloc.alloc(u21, count);
                    codepoints[0] = raw.content.codepoint;
                    @memcpy(codepoints[1..], source.grapheme);
                    for (codepoints) |codepoint| try validateCodepoint(codepoint);
                    break :grapheme .{ .grapheme = codepoints };
                },
                .bg_color_palette => .{
                    .background_palette = raw.content.color_palette,
                },
                .bg_color_rgb => .{ .background_rgb = .{
                    .r = raw.content.color_rgb.r,
                    .g = raw.content.color_rgb.g,
                    .b = raw.content.color_rgb.b,
                } },
            };

            return .{
                .column = column,
                .content = content,
                .wide_role = switch (raw.wide) {
                    .narrow => .narrow,
                    .wide => .wide,
                    .spacer_tail => .spacer_tail,
                    .spacer_head => .spacer_head,
                },
                .protected = raw.protected,
                .hyperlink = if (hyperlink) |link|
                    stableHyperlinkIdentity(canonical_ref, link)
                else
                    null,
                .semantic_content = switch (raw.semantic_content) {
                    .output => .output,
                    .input => .input,
                    .prompt => .prompt,
                },
                .style = if (raw.hasStyling()) captureStyle(source.style) else .{},
            };
        }

        fn stableHyperlinkIdentity(
            canonical_ref: Scene.CanonicalSceneRef,
            semantic_identity: [16]u8,
        ) Scene.HyperlinkIdentity {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hashField(&hasher, "ghostty.scene.hyperlink.v1");
            hashField(&hasher, &canonical_ref.terminal_id);
            var epoch: [8]u8 = undefined;
            std.mem.writeInt(u64, &epoch, canonical_ref.terminal_epoch, .little);
            hashField(&hasher, &epoch);
            hashField(&hasher, &semantic_identity);
            var digest: [32]u8 = undefined;
            hasher.final(&digest);
            return digest[0..16].*;
        }

        fn hashField(hasher: anytype, value: []const u8) void {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(value.len), .little);
            hasher.update(&length);
            hasher.update(value);
        }

        fn captureCursorCell(source: terminal.page.Cell) Scene.CursorCell {
            return .{
                .content = switch (source.content_tag) {
                    .codepoint, .codepoint_grapheme => .text,
                    .bg_color_palette => .{
                        .background_palette = source.content.color_palette,
                    },
                    .bg_color_rgb => .{ .background_rgb = .{
                        .r = source.content.color_rgb.r,
                        .g = source.content.color_rgb.g,
                        .b = source.content.color_rgb.b,
                    } },
                },
                .wide_role = switch (source.wide) {
                    .narrow => .narrow,
                    .wide => .wide,
                    .spacer_tail => .spacer_tail,
                    .spacer_head => .spacer_head,
                },
            };
        }

        fn rowAnchor(revision: u64, offset: u64, row: u32) Error!RowAnchor {
            return .{
                .row_space_revision = revision,
                .absolute_row = std.math.add(u64, offset, row) catch
                    return error.InvalidRange,
            };
        }

        const CapturedScrollbar = struct {
            total: u64,
            offset: u64,
            len: u64,
            row_space_revision: u64,
        };

        fn captureScrollbar(value: terminal.Scrollbar, rows: u32) Error!CapturedScrollbar {
            const total = std.math.cast(u64, value.total) orelse
                return error.LimitExceeded;
            const offset = std.math.cast(u64, value.offset) orelse
                return error.LimitExceeded;
            const len = std.math.cast(u64, value.len) orelse
                return error.LimitExceeded;
            const end = std.math.add(u64, offset, len) catch
                return error.InvalidRange;
            if (len != rows or offset > total or end > total)
                return error.InvalidRange;
            return .{
                .total = total,
                .offset = offset,
                .len = len,
                .row_space_revision = value.row_space_revision,
            };
        }

        fn captureStyle(source: terminal.Style) Style {
            return .{
                .foreground = captureStyleColor(source.fg_color),
                .background = captureStyleColor(source.bg_color),
                .underline_color = captureStyleColor(source.underline_color),
                .bold = source.flags.bold,
                .italic = source.flags.italic,
                .faint = source.flags.faint,
                .blink = source.flags.blink,
                .inverse = source.flags.inverse,
                .invisible = source.flags.invisible,
                .strikethrough = source.flags.strikethrough,
                .overline = source.flags.overline,
                .underline = switch (source.flags.underline) {
                    .none => .none,
                    .single => .single,
                    .double => .double,
                    .curly => .curly,
                    .dotted => .dotted,
                    .dashed => .dashed,
                },
            };
        }

        fn captureStyleColor(source: terminal.Style.Color) StyleColor {
            return switch (source) {
                .none => .none,
                .palette => |value| .{ .palette = value },
                .rgb => |value| .{ .rgb = captureRGB(value) },
            };
        }

        fn captureRGB(source: terminal.color.RGB) RGB {
            return .{ .r = source.r, .g = source.g, .b = source.b };
        }

        fn validateViewportCoordinate(
            coordinate: Scene.ViewportCoordinate,
            bounds: Scene.Bounds,
        ) Error!void {
            if (coordinate.row >= bounds.rows or coordinate.column >= bounds.columns)
                return error.InvalidCoordinate;
        }

        fn validateCodepoint(codepoint: u21) Error!void {
            if (codepoint > 0x10FFFF or
                (codepoint >= 0xD800 and codepoint <= 0xDFFF))
                return error.InvalidCodepoint;
        }

        fn sortOverlayFeatures(values: []OverlayFeature) error{InvalidRenderState}!void {
            if (values.len < 2) return;
            for (1..values.len) |index| {
                var current = index;
                while (current > 0 and
                    @intFromEnum(values[current]) < @intFromEnum(values[current - 1]))
                {
                    std.mem.swap(
                        OverlayFeature,
                        &values[current],
                        &values[current - 1],
                    );
                    current -= 1;
                }
            }
            for (values[1..], values[0 .. values.len - 1]) |value, prior| {
                if (value == prior) return error.InvalidRenderState;
            }
        }
    };
}
