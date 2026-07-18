//! Adapt an owned semantic scene to the renderer's established projection path.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");

pub fn Materialized(comptime Scene: type) type {
    return struct {
        const Self = @This();
        const Validation = @import("Validation.zig").Validation(Scene);

        state: terminal.RenderState = .empty,
        links: terminal.RenderState.CellSet = .empty,
        preedit_storage: []Scene.PreeditCodepoint = &.{},
        overlay_storage: []Scene.OverlayFeature = &.{},
        preedit: ?Scene.Preedit = null,
        scrollbar: terminal.Scrollbar = .zero,
        hover: ?terminal.point.Coordinate = null,
        focused: bool = false,
        cursor_blink_visible: bool = false,
        kitty_resources: []const Scene.KittyResource = &.{},
        kitty_images: []const Scene.KittyImage = &.{},
        kitty_frames: []const Scene.KittyAnimationFrame = &.{},
        kitty_placements: []const Scene.KittyPlacement = &.{},

        pub const Stats = struct {
            rows_visited: usize = 0,
            selection_steps: usize = 0,
            highlight_steps: usize = 0,
        };

        pub const Error = Allocator.Error || Validation.Error || error{
            LimitExceeded,
        };

        pub const PresentationUpdateError = Validation.Error || error{
            RequiresRematerialization,
            ReplayRejected,
        };

        pub fn init(
            alloc: Allocator,
            owned: *const Scene.Owned,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
        ) Error!Self {
            return initSeeded(
                alloc,
                owned,
                supported,
                limits,
                terminal.RenderState.empty.colors,
            );
        }

        pub fn initSeeded(
            alloc: Allocator,
            owned: *const Scene.Owned,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
            color_defaults: terminal.RenderState.Colors,
        ) Error!Self {
            return initPairSeeded(
                alloc,
                &owned.canonical,
                &owned.presentation,
                supported,
                limits,
                color_defaults,
            );
        }

        pub fn initCached(
            alloc: Allocator,
            view: Scene.CachedView,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
        ) Error!Self {
            return initCachedSeeded(
                alloc,
                view,
                supported,
                limits,
                terminal.RenderState.empty.colors,
            );
        }

        pub fn initCachedSeeded(
            alloc: Allocator,
            view: Scene.CachedView,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
            color_defaults: terminal.RenderState.Colors,
        ) Error!Self {
            return initPairSeeded(
                alloc,
                view.canonical,
                view.presentation,
                supported,
                limits,
                color_defaults,
            );
        }

        pub fn initPair(
            alloc: Allocator,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
        ) Error!Self {
            return initPairSeeded(
                alloc,
                canonical,
                presentation,
                supported,
                limits,
                terminal.RenderState.empty.colors,
            );
        }

        pub fn initPairSeeded(
            alloc: Allocator,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
            color_defaults: terminal.RenderState.Colors,
        ) Error!Self {
            return initPairInstrumented(
                alloc,
                canonical,
                presentation,
                supported,
                limits,
                color_defaults,
                null,
            );
        }

        pub fn initWithStats(
            alloc: Allocator,
            owned: *const Scene.Owned,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
            stats: *Stats,
        ) Error!Self {
            stats.* = .{};
            return initPairInstrumented(
                alloc,
                &owned.canonical,
                &owned.presentation,
                supported,
                limits,
                terminal.RenderState.empty.colors,
                stats,
            );
        }

        fn initPairInstrumented(
            alloc: Allocator,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
            color_defaults: terminal.RenderState.Colors,
            stats: ?*Stats,
        ) Error!Self {
            try Validation.validatePair(
                canonical,
                presentation,
                supported,
                limits,
            );
            var budgeted: BudgetedAllocator = .{
                .child = alloc,
                .remaining = limits.max_allocation_bytes,
            };
            return build(
                budgeted.allocator(),
                alloc,
                canonical,
                presentation,
                color_defaults,
                stats,
            ) catch if (budgeted.limit_exceeded)
                error.LimitExceeded
            else
                error.OutOfMemory;
        }

        fn build(
            storage_alloc: Allocator,
            deinit_alloc: Allocator,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation_envelope: *const Scene.PresentationEnvelope,
            color_defaults: terminal.RenderState.Colors,
            stats: ?*Stats,
        ) Allocator.Error!Self {
            var result: Self = .{};
            errdefer result.deinit(deinit_alloc);
            const content = canonical.content;
            const presentation = presentation_envelope.content;
            const viewport_start: usize = @intCast(
                presentation.scrollbar.offset - content.row_start,
            );
            const viewport_len: usize = @intCast(presentation.scrollbar.len);
            const visible_rows = content.rows[viewport_start..][0..viewport_len];

            result.state.rows = @intCast(content.bounds.rows);
            result.state.cols = @intCast(content.bounds.columns);
            result.state.colors = color_defaults;
            if (content.colors.background_override) |value|
                result.state.colors.background = terminalRGB(value);
            if (content.colors.foreground_override) |value|
                result.state.colors.foreground = terminalRGB(value);
            if (content.colors.cursor_override) |value|
                result.state.colors.cursor = terminalRGB(value);
            for (0..content.colors.palette.len) |index| {
                if (!content.colors.paletteIsSet(@intCast(index))) continue;
                result.state.colors.palette[index] = terminalRGB(
                    content.colors.palette[index],
                );
            }
            if (content.colors.reverse) std.mem.swap(
                terminal.color.RGB,
                &result.state.colors.background,
                &result.state.colors.foreground,
            );
            result.state.cursor = .{
                .active = .{
                    .y = @intCast(content.cursor.active.row),
                    .x = @intCast(content.cursor.active.column),
                },
                .viewport = if (presentation.cursor_viewport) |viewport| .{
                    .y = @intCast(viewport.coordinate.row),
                    .x = @intCast(viewport.coordinate.column),
                    .wide_tail = viewport.wide_tail,
                } else null,
                .cell = terminalCursorCell(content.cursor.cell),
                .style = terminalStyle(content.cursor.style),
                .visual_style = switch (content.cursor.visual_style) {
                    .bar => .bar,
                    .block => .block,
                    .underline => .underline,
                    .block_hollow => .block_hollow,
                },
                .password_input = content.cursor.password_input,
                .visible = content.cursor.visible,
                .blinking = content.cursor.blinking,
            };
            result.state.screen = switch (content.screen) {
                .primary => .primary,
                .alternate => .alternate,
            };
            result.state.dirty = .full;

            try result.state.row_data.resize(storage_alloc, visible_rows.len);
            var row_data = result.state.row_data.slice();
            // resize leaves every element undefined. Initialize the complete
            // deinit-visible range before the next fallible operation.
            for (0..visible_rows.len) |row_index| {
                row_data.set(row_index, .{
                    .arena = .{},
                    .pin = undefined,
                    .raw = @bitCast(@as(u64, 0)),
                    .cells = .empty,
                    .dirty = true,
                    .selection = null,
                    .highlights = .empty,
                    .hyperlinks = &.{},
                });
            }

            var selection_index: usize = 0;
            var highlight_index: usize = 0;
            for (visible_rows, 0..) |row, row_index| {
                if (stats) |value| value.rows_visited += 1;
                var raw_row: terminal.page.Row = @bitCast(@as(u64, 0));
                raw_row.wrap = row.wrap;
                raw_row.wrap_continuation = row.wrap_continuation;
                raw_row.semantic_prompt = switch (row.semantic_prompt) {
                    .none => .none,
                    .prompt => .prompt,
                    .prompt_continuation => .prompt_continuation,
                };
                raw_row.kitty_virtual_placeholder = row.kitty_virtual_placeholder;
                raw_row.dirty = true;
                row_data.items(.raw)[row_index] = raw_row;

                var row_arena = row_data.items(.arena)[row_index].promote(storage_alloc);
                defer row_data.items(.arena)[row_index] = row_arena.state;
                const row_alloc = row_arena.allocator();
                const cells = &row_data.items(.cells)[row_index];
                try cells.resize(storage_alloc, row.cells.len);
                var cell_data = cells.slice();
                var hyperlink_count: usize = 0;
                for (row.cells) |cell|
                    hyperlink_count += @intFromBool(cell.hyperlink != null);
                const hyperlinks = try row_alloc.alloc(
                    terminal.RenderState.HyperlinkCell,
                    hyperlink_count,
                );
                var hyperlink_index: usize = 0;
                for (row.cells, 0..) |cell, column| {
                    var raw: terminal.page.Cell = .{};
                    const grapheme: []const u21 = switch (cell.content) {
                        .codepoint => |value| codepoint: {
                            raw.content_tag = .codepoint;
                            raw.content = .{ .codepoint = value };
                            break :codepoint &.{};
                        },
                        .grapheme => |values| grapheme: {
                            raw.content_tag = .codepoint_grapheme;
                            raw.content = .{ .codepoint = values[0] };
                            row_data.items(.raw)[row_index].grapheme = true;
                            break :grapheme if (values.len > 1)
                                try row_alloc.dupe(u21, values[1..])
                            else
                                &.{};
                        },
                        .background_palette => |value| background: {
                            raw.content_tag = .bg_color_palette;
                            raw.content = .{ .color_palette = value };
                            break :background &.{};
                        },
                        .background_rgb => |value| background: {
                            raw.content_tag = .bg_color_rgb;
                            raw.content = .{ .color_rgb = .{
                                .r = value.r,
                                .g = value.g,
                                .b = value.b,
                            } };
                            break :background &.{};
                        },
                    };
                    raw.wide = terminalWide(cell.wide_role);
                    raw.protected = cell.protected;
                    raw.hyperlink = cell.hyperlink != null;
                    raw.semantic_content = switch (cell.semantic_content) {
                        .output => .output,
                        .input => .input,
                        .prompt => .prompt,
                    };
                    const style = terminalStyle(cell.style);
                    if (!style.default()) {
                        raw.style_id = 1;
                        row_data.items(.raw)[row_index].styled = true;
                    }
                    if (raw.hyperlink)
                        row_data.items(.raw)[row_index].hyperlink = true;
                    if (cell.hyperlink) |identity| {
                        hyperlinks[hyperlink_index] = .{
                            .column = @intCast(column),
                            .semantic_identity = identity,
                        };
                        hyperlink_index += 1;
                    }
                    cell_data.set(column, .{
                        .raw = raw,
                        .grapheme = grapheme,
                        .style = style,
                    });
                }
                row_data.items(.hyperlinks)[row_index] = hyperlinks;

                if (selection_index < presentation.selections.len) {
                    if (stats) |value| value.selection_steps += 1;
                    const selection = presentation.selections[selection_index];
                    if (selection.row.absolute_row == row.anchor.absolute_row) {
                        row_data.items(.selection)[row_index] = .{
                            @intCast(selection.start),
                            @intCast(selection.end),
                        };
                        selection_index += 1;
                    }
                }
                while (highlight_index < presentation.highlights.len) {
                    if (stats) |value| value.highlight_steps += 1;
                    if (presentation.highlights[highlight_index].row.absolute_row !=
                        row.anchor.absolute_row) break;
                    const highlight = presentation.highlights[highlight_index];
                    try row_data.items(.highlights)[row_index].append(row_alloc, .{
                        .tag = @intFromEnum(highlight.kind),
                        .range = .{
                            @intCast(highlight.start),
                            @intCast(highlight.end),
                        },
                    });
                    highlight_index += 1;
                }
            }
            std.debug.assert(selection_index == presentation.selections.len);
            std.debug.assert(highlight_index == presentation.highlights.len);

            for (presentation.active_links) |coordinate| {
                const viewport_row = coordinate.row.absolute_row -
                    presentation.scrollbar.offset;
                try result.links.put(storage_alloc, .{
                    .y = @intCast(viewport_row),
                    .x = @intCast(coordinate.column),
                }, {});
            }

            if (presentation.preedit.len > 0) {
                result.preedit_storage = try storage_alloc.dupe(
                    Scene.PreeditCodepoint,
                    presentation.preedit,
                );
                result.preedit = .{
                    .codepoints = result.preedit_storage,
                    .selection_start_utf16 = presentation.preedit_selection_start_utf16,
                    .selection_length_utf16 = presentation.preedit_selection_length_utf16,
                    .caret_utf16 = presentation.preedit_caret_utf16,
                };
            }
            if (presentation.overlay_features.len > 0)
                result.overlay_storage = try storage_alloc.dupe(
                    Scene.OverlayFeature,
                    presentation.overlay_features,
                );
            result.scrollbar = .{
                .total = @intCast(content.row_total),
                .offset = @intCast(presentation.scrollbar.offset),
                .len = @intCast(presentation.scrollbar.len),
                .row_space_revision = presentation.scrollbar.row_space_revision,
            };
            result.hover = if (presentation.hover) |hover| .{
                .y = @intCast(hover.row.absolute_row - presentation.scrollbar.offset),
                .x = @intCast(hover.column),
            } else null;
            result.focused = presentation.focused;
            result.cursor_blink_visible = presentation.cursor_blink_visible;
            result.kitty_resources = content.kitty_resources;
            result.kitty_images = content.kitty_images;
            result.kitty_frames = content.kitty_frames;
            result.kitty_placements = presentation.kitty_placements;
            return result;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (self.overlay_storage.len > 0) alloc.free(self.overlay_storage);
            if (self.preedit_storage.len > 0) alloc.free(self.preedit_storage);
            self.links.deinit(alloc);
            self.state.deinit(alloc);
            self.* = undefined;
        }

        pub fn projection(self: *Self) Scene.Projection {
            return .{
                .terminal_state = &self.state,
                .preedit = self.preedit,
                .link_cells = &self.links,
                .scrollbar = self.scrollbar,
                .overlay_features = self.overlay_storage,
                .hover = self.hover,
                .focused = self.focused,
                .cursor_blink_visible = self.cursor_blink_visible,
                .kitty_resources = self.kitty_resources,
                .kitty_images = self.kitty_images,
                .kitty_frames = self.kitty_frames,
                .kitty_placements = self.kitty_placements,
            };
        }

        /// Apply a presentation update whose render-affecting collections and
        /// viewport are unchanged. This validates only presentation data and
        /// performs zero allocation and zero canonical row traversal.
        pub fn updatePresentationMetadata(
            self: *Self,
            canonical: *const Scene.CanonicalSceneEnvelope,
            previous: *const Scene.PresentationEnvelope,
            next: *const Scene.PresentationEnvelope,
            limits: Scene.Limits,
        ) PresentationUpdateError!void {
            try Validation.validatePresentationAgainstCachedCanonical(
                canonical,
                next,
                limits,
            );
            if (!std.mem.eql(
                u8,
                &previous.ref.presentation_id,
                &next.ref.presentation_id,
            ) or previous.ref.generation != next.ref.generation or
                next.ref.sequence <= previous.ref.sequence)
                return error.ReplayRejected;
            if (!std.meta.eql(previous.terminal_space, next.terminal_space) or
                !sliceEqual(Scene.ColumnRange, previous.content.selections, next.content.selections) or
                !sliceEqual(Scene.Highlight, previous.content.highlights, next.content.highlights) or
                !sliceEqual(Scene.Coordinate, previous.content.active_links, next.content.active_links) or
                !sliceEqual(Scene.PreeditCodepoint, previous.content.preedit, next.content.preedit) or
                previous.content.preedit_selection_start_utf16 != next.content.preedit_selection_start_utf16 or
                previous.content.preedit_selection_length_utf16 != next.content.preedit_selection_length_utf16 or
                previous.content.preedit_caret_utf16 != next.content.preedit_caret_utf16 or
                !sliceEqual(Scene.OverlayFeature, previous.content.overlay_features, next.content.overlay_features) or
                !std.meta.eql(previous.content.hover, next.content.hover) or
                !std.meta.eql(previous.content.cursor_viewport, next.content.cursor_viewport) or
                !std.meta.eql(previous.content.scrollbar, next.content.scrollbar) or
                previous.content.custom_shader_count != next.content.custom_shader_count or
                !sliceEqual(
                    Scene.KittyPlacement,
                    previous.content.kitty_placements,
                    next.content.kitty_placements,
                ))
                return error.RequiresRematerialization;
            self.focused = next.content.focused;
            self.cursor_blink_visible = next.content.cursor_blink_visible;
            self.kitty_placements = next.content.kitty_placements;
        }

        fn sliceEqual(comptime T: type, left: []const T, right: []const T) bool {
            if (left.len != right.len) return false;
            for (left, right) |lhs, rhs| {
                if (!std.meta.eql(lhs, rhs)) return false;
            }
            return true;
        }

        fn terminalCursorCell(value: Scene.CursorCell) terminal.page.Cell {
            var result: terminal.page.Cell = .{};
            switch (value.content) {
                .text => {},
                .background_palette => |index| {
                    result.content_tag = .bg_color_palette;
                    result.content = .{ .color_palette = index };
                },
                .background_rgb => |color| {
                    result.content_tag = .bg_color_rgb;
                    result.content = .{ .color_rgb = .{
                        .r = color.r,
                        .g = color.g,
                        .b = color.b,
                    } };
                },
            }
            result.wide = terminalWide(value.wide_role);
            return result;
        }

        fn terminalWide(value: Scene.WideRole) terminal.page.Cell.Wide {
            return switch (value) {
                .narrow => .narrow,
                .wide => .wide,
                .spacer_tail => .spacer_tail,
                .spacer_head => .spacer_head,
            };
        }

        fn terminalRGB(value: Scene.RGB) terminal.color.RGB {
            return .{ .r = value.r, .g = value.g, .b = value.b };
        }

        fn terminalStyle(value: Scene.Style) terminal.Style {
            var result: terminal.Style = .{
                .fg_color = terminalStyleColor(value.foreground),
                .bg_color = terminalStyleColor(value.background),
                .underline_color = terminalStyleColor(value.underline_color),
            };
            result.flags.bold = value.bold;
            result.flags.italic = value.italic;
            result.flags.faint = value.faint;
            result.flags.blink = value.blink;
            result.flags.inverse = value.inverse;
            result.flags.invisible = value.invisible;
            result.flags.strikethrough = value.strikethrough;
            result.flags.overline = value.overline;
            result.flags.underline = switch (value.underline) {
                .none => .none,
                .single => .single,
                .double => .double,
                .curly => .curly,
                .dotted => .dotted,
                .dashed => .dashed,
            };
            return result;
        }

        fn terminalStyleColor(value: Scene.StyleColor) terminal.Style.Color {
            return switch (value) {
                .none => .none,
                .palette => |index| .{ .palette = index },
                .rgb => |color| .{ .rgb = terminalRGB(color) },
            };
        }

        const BudgetedAllocator = struct {
            child: Allocator,
            remaining: usize,
            limit_exceeded: bool = false,

            fn allocator(self: *BudgetedAllocator) Allocator {
                return .{ .ptr = self, .vtable = &vtable };
            }

            const vtable: Allocator.VTable = .{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            };

            fn alloc(
                ctx: *anyopaque,
                len: usize,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) ?[*]u8 {
                const self: *BudgetedAllocator = @ptrCast(@alignCast(ctx));
                if (len > self.remaining) {
                    self.limit_exceeded = true;
                    return null;
                }
                const result = self.child.rawAlloc(len, alignment, ret_addr) orelse
                    return null;
                self.remaining -= len;
                return result;
            }

            fn resize(
                ctx: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                ret_addr: usize,
            ) bool {
                const self: *BudgetedAllocator = @ptrCast(@alignCast(ctx));
                if (new_len > memory.len and new_len - memory.len > self.remaining) {
                    self.limit_exceeded = true;
                    return false;
                }
                if (!self.child.rawResize(memory, alignment, new_len, ret_addr))
                    return false;
                if (new_len > memory.len)
                    self.remaining -= new_len - memory.len
                else
                    self.remaining += memory.len - new_len;
                return true;
            }

            fn remap(
                ctx: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                ret_addr: usize,
            ) ?[*]u8 {
                const self: *BudgetedAllocator = @ptrCast(@alignCast(ctx));
                if (new_len > memory.len and new_len - memory.len > self.remaining) {
                    self.limit_exceeded = true;
                    return null;
                }
                const result = self.child.rawRemap(
                    memory,
                    alignment,
                    new_len,
                    ret_addr,
                ) orelse return null;
                if (new_len > memory.len)
                    self.remaining -= new_len - memory.len
                else
                    self.remaining += memory.len - new_len;
                return result;
            }

            fn free(
                ctx: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                ret_addr: usize,
            ) void {
                const self: *BudgetedAllocator = @ptrCast(@alignCast(ctx));
                self.child.rawFree(memory, alignment, ret_addr);
                self.remaining += memory.len;
            }
        };
    };
}
