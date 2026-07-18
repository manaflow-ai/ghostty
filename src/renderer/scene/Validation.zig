//! Structural and semantic validation shared by codecs and projectors.

const std = @import("std");

pub fn Validation(comptime Scene: type) type {
    return struct {
        pub const Error = error{
            InvalidDimensions,
            InvalidScene,
            InvalidIdentity,
            InvalidSequence,
            InvalidCoordinate,
            InvalidRange,
            InvalidCodepoint,
            InvalidCapabilityManifest,
            UnsupportedCapability,
            UnsupportedSnapshotKind,
            LimitExceeded,
        };

        pub fn validateOwned(
            scene: *const Scene.Owned,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
        ) Error!void {
            try validatePair(
                &scene.canonical,
                &scene.presentation,
                supported,
                limits,
            );
        }

        /// Validate independently cached canonical and presentation sections
        /// as one renderable state. Neither section's sequence is required to
        /// advance merely because the other section changed.
        pub fn validatePair(
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
            supported: Scene.CapabilityManifest,
            limits: Scene.Limits,
        ) Error!void {
            if (Scene.identityIsZero(canonical.ref.terminal_id) or
                Scene.identityIsZero(presentation.ref.presentation_id))
                return error.InvalidIdentity;
            if (canonical.ref.terminal_epoch == 0 or
                canonical.ref.content_sequence == 0 or
                presentation.ref.generation == 0 or
                presentation.ref.sequence == 0)
                return error.InvalidSequence;
            try validateSnapshot(
                canonical.snapshot_kind,
                canonical.base_content_sequence,
                canonical.ref.content_sequence,
            );
            try validateSnapshot(
                presentation.snapshot_kind,
                presentation.base_sequence,
                presentation.ref.sequence,
            );
            if (!canonical.required_capabilities.validRequired())
                return error.InvalidCapabilityManifest;
            if (!supported.validRequired() or
                !supported.containsAll(canonical.required_capabilities))
                return error.UnsupportedCapability;
            if (!terminalSpaceMatchesCanonical(
                presentation.terminal_space,
                canonical.ref,
            )) return error.InvalidIdentity;

            const content = canonical.content;
            const bounds = content.bounds;
            if (bounds.rows == 0 or bounds.columns == 0 or content.rows.len == 0)
                return error.InvalidDimensions;
            if (bounds.rows > limits.max_rows or
                bounds.columns > limits.max_columns or
                content.rows.len > limits.max_rows)
                return error.LimitExceeded;
            const cell_count = std.math.mul(
                usize,
                content.rows.len,
                bounds.columns,
            ) catch return error.LimitExceeded;
            if (cell_count > limits.max_cells) return error.LimitExceeded;

            const backing_end = std.math.add(
                u64,
                content.row_start,
                content.rows.len,
            ) catch return error.InvalidRange;
            if (backing_end > content.row_total) return error.InvalidRange;
            const scrollbar = presentation.content.scrollbar;
            if (std.math.cast(usize, content.row_total) == null or
                std.math.cast(usize, scrollbar.offset) == null or
                std.math.cast(usize, scrollbar.len) == null)
                return error.LimitExceeded;
            if (scrollbar.row_space_revision != canonical.ref.row_space_revision or
                scrollbar.len != bounds.rows or
                scrollbar.offset > content.row_total)
                return error.InvalidRange;
            const viewport_end = std.math.add(
                u64,
                scrollbar.offset,
                scrollbar.len,
            ) catch return error.InvalidRange;
            if (viewport_end > content.row_total or
                scrollbar.offset < content.row_start or
                viewport_end > backing_end)
                return error.InvalidRange;

            var grapheme_count: usize = 0;
            for (content.rows, 0..) |row, row_index| {
                if (row.backing_index != row_index or
                    row.column_start != 0 or
                    row.column_count != bounds.columns or
                    row.cells.len != row.column_count)
                    return error.InvalidIdentity;
                const expected_absolute = std.math.add(
                    u64,
                    content.row_start,
                    row_index,
                ) catch return error.InvalidRange;
                if (row.anchor.row_space_revision != canonical.ref.row_space_revision or
                    row.anchor.absolute_row != expected_absolute)
                    return error.InvalidIdentity;
                // Interior wrap edges must agree. The first and last backing
                // rows may be a clipped portion of a longer wrap chain.
                if (row_index > 0 and
                    row.wrap_continuation != content.rows[row_index - 1].wrap)
                    return error.InvalidScene;
                if (row.kitty_virtual_placeholder and
                    !canonical.required_capabilities.contains(.images))
                    return error.InvalidCapabilityManifest;
                for (row.cells, 0..) |cell, column| {
                    if (cell.column != column) return error.InvalidIdentity;
                    switch (cell.content) {
                        .codepoint => |value| try validateCodepoint(value),
                        .grapheme => |values| {
                            if (values.len == 0 or
                                values.len > limits.max_grapheme_codepoints_per_cell)
                                return error.LimitExceeded;
                            grapheme_count = std.math.add(
                                usize,
                                grapheme_count,
                                values.len,
                            ) catch return error.LimitExceeded;
                            if (grapheme_count > limits.max_total_grapheme_codepoints)
                                return error.LimitExceeded;
                            for (values) |value| try validateCodepoint(value);
                        },
                        .background_palette, .background_rgb => {},
                    }
                    if (cell.hyperlink) |identity| {
                        if (Scene.identityIsZero(identity)) return error.InvalidIdentity;
                        if (!canonical.required_capabilities.contains(.stable_hyperlinks))
                            return error.InvalidCapabilityManifest;
                    }
                }
                try validateWideRoles(content.rows, row_index);
            }

            try validateViewportCoordinate(content.cursor.active, bounds);
            if (presentation.content.cursor_viewport) |viewport| {
                try validateViewportCoordinate(viewport.coordinate, bounds);
                const live_start = content.row_total - scrollbar.len;
                const active_absolute = std.math.add(
                    u64,
                    live_start,
                    content.cursor.active.row,
                ) catch return error.InvalidCoordinate;
                if (active_absolute < scrollbar.offset or
                    active_absolute - scrollbar.offset != viewport.coordinate.row or
                    viewport.coordinate.column != content.cursor.active.column or
                    viewport.wide_tail !=
                        (content.cursor.cell.wide_role == .spacer_tail))
                    return error.InvalidCoordinate;
            }

            const local = presentation.content;
            if (local.selections.len > bounds.rows or
                local.highlights.len > limits.max_highlights or
                local.active_links.len > limits.max_cells or
                local.preedit.len > limits.max_preedit_codepoints or
                local.overlay_features.len > limits.max_overlay_features)
                return error.LimitExceeded;

            var prior_selection_row: ?Scene.RowAnchor = null;
            for (local.selections) |selection| {
                try validateRange(selection.row, selection.start, selection.end, canonical, presentation);
                if (prior_selection_row) |prior| {
                    if (!rowAnchorLess(prior, selection.row))
                        return error.InvalidIdentity;
                }
                prior_selection_row = selection.row;
            }
            var prior_highlight_row: ?Scene.RowAnchor = null;
            for (local.highlights) |highlight| {
                try validateRange(highlight.row, highlight.start, highlight.end, canonical, presentation);
                // Preserve producer order within each row because renderer
                // precedence is first-match. Only row grouping is required.
                if (prior_highlight_row) |prior| {
                    if (rowAnchorLess(highlight.row, prior))
                        return error.InvalidIdentity;
                }
                prior_highlight_row = highlight.row;
            }
            var prior_link: ?Scene.Coordinate = null;
            for (local.active_links) |coordinate| {
                try validateCoordinate(coordinate, canonical, presentation);
                if (prior_link) |prior| {
                    if (!coordinateLess(prior, coordinate))
                        return error.InvalidIdentity;
                }
                prior_link = coordinate;
            }
            for (local.preedit) |codepoint| try validateCodepoint(codepoint.codepoint);
            var prior_overlay: ?Scene.OverlayFeature = null;
            for (local.overlay_features) |feature| {
                if (prior_overlay) |prior| {
                    if (@intFromEnum(feature) <= @intFromEnum(prior))
                        return error.InvalidIdentity;
                }
                prior_overlay = feature;
            }
            if (local.hover) |hover|
                try validateCoordinate(hover, canonical, presentation);

            if (content.image_count > 0) {
                if (!canonical.required_capabilities.contains(.images))
                    return error.InvalidCapabilityManifest;
                return error.UnsupportedCapability;
            }
            if (local.custom_shader_count > 0) {
                if (!canonical.required_capabilities.contains(.custom_shaders))
                    return error.InvalidCapabilityManifest;
                return error.UnsupportedCapability;
            }
        }

        /// Validate a new presentation against canonical storage that was
        /// already validated when admitted to the cache. This deliberately
        /// performs no canonical row or cell traversal, enabling focus and
        /// cursor-blink updates to remain independent of terminal size.
        pub fn validatePresentationAgainstCachedCanonical(
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
            limits: Scene.Limits,
        ) Error!void {
            if (Scene.identityIsZero(presentation.ref.presentation_id))
                return error.InvalidIdentity;
            if (presentation.ref.generation == 0 or presentation.ref.sequence == 0)
                return error.InvalidSequence;
            try validateSnapshot(
                presentation.snapshot_kind,
                presentation.base_sequence,
                presentation.ref.sequence,
            );
            if (!terminalSpaceMatchesCanonical(
                presentation.terminal_space,
                canonical.ref,
            )) return error.InvalidIdentity;

            const bounds = canonical.content.bounds;
            const local = presentation.content;
            const scrollbar = local.scrollbar;
            if (scrollbar.row_space_revision != canonical.ref.row_space_revision or
                scrollbar.len != bounds.rows)
                return error.InvalidRange;
            const viewport_end = std.math.add(
                u64,
                scrollbar.offset,
                scrollbar.len,
            ) catch return error.InvalidRange;
            const backing_end = std.math.add(
                u64,
                canonical.content.row_start,
                canonical.content.rows.len,
            ) catch return error.InvalidRange;
            if (viewport_end > canonical.content.row_total or
                scrollbar.offset < canonical.content.row_start or
                viewport_end > backing_end)
                return error.InvalidRange;

            if (local.cursor_viewport) |viewport| {
                try validateViewportCoordinate(viewport.coordinate, bounds);
                const live_start = canonical.content.row_total - scrollbar.len;
                const active_absolute = std.math.add(
                    u64,
                    live_start,
                    canonical.content.cursor.active.row,
                ) catch return error.InvalidCoordinate;
                if (active_absolute < scrollbar.offset or
                    active_absolute - scrollbar.offset != viewport.coordinate.row or
                    viewport.coordinate.column != canonical.content.cursor.active.column or
                    viewport.wide_tail !=
                        (canonical.content.cursor.cell.wide_role == .spacer_tail))
                    return error.InvalidCoordinate;
            }

            if (local.selections.len > bounds.rows or
                local.highlights.len > limits.max_highlights or
                local.active_links.len > limits.max_cells or
                local.preedit.len > limits.max_preedit_codepoints or
                local.overlay_features.len > limits.max_overlay_features)
                return error.LimitExceeded;
            var prior_selection_row: ?Scene.RowAnchor = null;
            for (local.selections) |selection| {
                try validateRange(
                    selection.row,
                    selection.start,
                    selection.end,
                    canonical,
                    presentation,
                );
                if (prior_selection_row) |prior| {
                    if (!rowAnchorLess(prior, selection.row))
                        return error.InvalidIdentity;
                }
                prior_selection_row = selection.row;
            }
            var prior_highlight_row: ?Scene.RowAnchor = null;
            for (local.highlights) |highlight| {
                try validateRange(
                    highlight.row,
                    highlight.start,
                    highlight.end,
                    canonical,
                    presentation,
                );
                if (prior_highlight_row) |prior| {
                    if (rowAnchorLess(highlight.row, prior))
                        return error.InvalidIdentity;
                }
                prior_highlight_row = highlight.row;
            }
            var prior_link: ?Scene.Coordinate = null;
            for (local.active_links) |coordinate| {
                try validateCoordinate(coordinate, canonical, presentation);
                if (prior_link) |prior| {
                    if (!coordinateLess(prior, coordinate))
                        return error.InvalidIdentity;
                }
                prior_link = coordinate;
            }
            for (local.preedit) |codepoint| try validateCodepoint(codepoint.codepoint);
            var prior_overlay: ?Scene.OverlayFeature = null;
            for (local.overlay_features) |feature| {
                if (prior_overlay) |prior| {
                    if (@intFromEnum(feature) <= @intFromEnum(prior))
                        return error.InvalidIdentity;
                }
                prior_overlay = feature;
            }
            if (local.hover) |hover|
                try validateCoordinate(hover, canonical, presentation);
            if (local.custom_shader_count > 0)
                return error.UnsupportedCapability;
        }

        /// A changed section advances strictly. maxInt is a valid final
        /// sequence, but a cached maxInt cannot accept another update.
        pub fn validateChangedSequence(value: u64, cached: ?u64) error{ReplayRejected}!void {
            if (value == 0) return error.ReplayRejected;
            if (cached) |fence| {
                if (fence == std.math.maxInt(u64) or value <= fence)
                    return error.ReplayRejected;
            }
        }

        fn validateSnapshot(
            kind: Scene.SnapshotKind,
            base: ?u64,
            sequence: u64,
        ) Error!void {
            switch (kind) {
                .full => if (base != null) return error.InvalidSequence,
                .delta => {
                    const base_sequence = base orelse return error.InvalidSequence;
                    if (base_sequence == 0 or base_sequence >= sequence)
                        return error.InvalidSequence;
                    return error.UnsupportedSnapshotKind;
                },
            }
        }

        fn validateRange(
            row: Scene.RowAnchor,
            start: u32,
            end: u32,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
        ) Error!void {
            try validateRowAnchor(row, canonical, presentation);
            if (start > end or end >= canonical.content.bounds.columns)
                return error.InvalidRange;
        }

        fn validateCoordinate(
            coordinate: Scene.Coordinate,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
        ) Error!void {
            try validateRowAnchor(coordinate.row, canonical, presentation);
            if (coordinate.column >= canonical.content.bounds.columns)
                return error.InvalidCoordinate;
        }

        fn validateRowAnchor(
            anchor: Scene.RowAnchor,
            canonical: *const Scene.CanonicalSceneEnvelope,
            presentation: *const Scene.PresentationEnvelope,
        ) Error!void {
            if (anchor.row_space_revision != canonical.ref.row_space_revision)
                return error.InvalidCoordinate;
            const start = presentation.content.scrollbar.offset;
            const end = std.math.add(
                u64,
                start,
                presentation.content.scrollbar.len,
            ) catch return error.InvalidCoordinate;
            if (anchor.absolute_row < start or anchor.absolute_row >= end)
                return error.InvalidCoordinate;
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

        fn validateWideRoles(rows: []const Scene.Row, row_index: usize) Error!void {
            const row = rows[row_index];
            for (row.cells, 0..) |cell, column| switch (cell.wide_role) {
                .narrow => {},
                .wide => {
                    if (column + 1 >= row.cells.len or
                        row.cells[column + 1].wide_role != .spacer_tail)
                        return error.InvalidScene;
                },
                .spacer_tail => {
                    if (column == 0 or row.cells[column - 1].wide_role != .wide)
                        return error.InvalidScene;
                },
                .spacer_head => {
                    if (column + 1 != row.cells.len or !row.wrap)
                        return error.InvalidScene;
                    if (row_index + 1 < rows.len) {
                        const next = rows[row_index + 1];
                        if (!next.wrap_continuation or next.cells.len < 2 or
                            next.cells[0].wide_role != .wide or
                            next.cells[1].wide_role != .spacer_tail)
                            return error.InvalidScene;
                    }
                },
            };
        }

        pub fn canonicalRefEqual(
            left: Scene.CanonicalSceneRef,
            right: Scene.CanonicalSceneRef,
        ) bool {
            return std.mem.eql(u8, &left.terminal_id, &right.terminal_id) and
                left.terminal_epoch == right.terminal_epoch and
                left.content_sequence == right.content_sequence and
                left.row_space_revision == right.row_space_revision;
        }

        pub fn presentationRefEqual(
            left: Scene.PresentationSceneRef,
            right: Scene.PresentationSceneRef,
        ) bool {
            return std.mem.eql(u8, &left.presentation_id, &right.presentation_id) and
                left.generation == right.generation and
                left.sequence == right.sequence;
        }

        fn terminalSpaceMatchesCanonical(
            space: Scene.TerminalSpaceRef,
            canonical: Scene.CanonicalSceneRef,
        ) bool {
            return std.mem.eql(u8, &space.terminal_id, &canonical.terminal_id) and
                space.terminal_epoch == canonical.terminal_epoch and
                space.row_space_revision == canonical.row_space_revision;
        }

        fn rowAnchorEqual(left: Scene.RowAnchor, right: Scene.RowAnchor) bool {
            return left.row_space_revision == right.row_space_revision and
                left.absolute_row == right.absolute_row;
        }

        fn rowAnchorLess(left: Scene.RowAnchor, right: Scene.RowAnchor) bool {
            return left.row_space_revision < right.row_space_revision or
                (left.row_space_revision == right.row_space_revision and
                    left.absolute_row < right.absolute_row);
        }

        fn coordinateLess(left: Scene.Coordinate, right: Scene.Coordinate) bool {
            return rowAnchorLess(left.row, right.row) or
                (rowAnchorEqual(left.row, right.row) and
                    left.column < right.column);
        }
    };
}
