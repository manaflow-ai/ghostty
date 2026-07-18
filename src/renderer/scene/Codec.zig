//! Deterministic, bounded wire codec for semantic renderer scene updates.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Codec(comptime Scene: type) type {
    return struct {
        const Validation = @import("Validation.zig").Validation(Scene);

        pub const wire_magic = [4]u8{ 'G', 'S', 'C', 'N' };
        pub const wire_version_static: u16 = 3;
        pub const wire_version_kitty: u16 = 4;
        pub const wire_version: u16 = 5;
        pub const wire_header_size: u16 = 128;

        pub const CodecError = Allocator.Error || Validation.Error || error{
            InvalidMagic,
            UnsupportedVersion,
            InvalidHeader,
            WrongTerminal,
            WrongPresentation,
            ReplayRejected,
            Truncated,
            TrailingData,
            InvalidEnum,
            InvalidBoolean,
        };

        const Header = struct {
            wire_version: u16,
            required: Scene.CapabilityManifest,
            canonical_kind: Scene.SectionKind,
            presentation_kind: Scene.SectionKind,
            canonical_ref: Scene.CanonicalSceneRef,
            bounds: ?Scene.Bounds,
            screen: ?Scene.Screen,
            presentation_ref: Scene.PresentationSceneRef,
        };

        pub fn encodeAlloc(
            alloc: Allocator,
            scene: *const Scene.Owned,
            options: Scene.EncodeOptions,
            limits: Scene.Limits,
        ) CodecError![]u8 {
            if (options.wire_version != wire_version_static and
                options.wire_version != wire_version_kitty and
                options.wire_version != wire_version)
                return error.UnsupportedVersion;
            if (options.wire_version == wire_version_static and
                scene.canonical.required_capabilities.contains(.kitty_animation_frames))
                return error.UnsupportedCapability;
            try Validation.validateOwned(
                scene,
                options.supported_capabilities,
                limits,
            );
            try validateSectionKinds(
                options.canonical_kind,
                options.presentation_kind,
            );
            if (options.canonical_kind == .delta) {
                const base = options.canonical_base orelse
                    return error.UnsupportedSnapshotKind;
                if (!std.mem.eql(
                    u8,
                    &base.ref.terminal_id,
                    &scene.canonical.ref.terminal_id,
                ) or base.ref.terminal_epoch != scene.canonical.ref.terminal_epoch or
                    base.ref.content_sequence >= scene.canonical.ref.content_sequence or
                    base.content.rows.len != scene.canonical.content.rows.len)
                    return error.InvalidSequence;
            } else if (options.canonical_base != null) {
                return error.InvalidHeader;
            }

            var encoder: Encoder = .{
                .alloc = alloc,
                .limit = limits.max_encoded_bytes,
            };
            errdefer encoder.bytes.deinit(alloc);

            const canonical_changed = options.canonical_kind != .unchanged;
            try encoder.writeBytes(&wire_magic);
            try encoder.writeInt(u16, options.wire_version);
            try encoder.writeInt(u16, wire_header_size);
            try encoder.writeInt(u64, scene.canonical.required_capabilities.bits);
            try encoder.writeEnum(options.canonical_kind);
            try encoder.writeEnum(options.presentation_kind);
            try encoder.writeInt(u8, 0);
            try encoder.writeBytes(&.{ 0, 0, 0, 0, 0 });
            try encoder.writeBytes(&scene.canonical.ref.terminal_id);
            try encoder.writeInt(u64, scene.canonical.ref.terminal_epoch);
            try encoder.writeInt(u64, scene.canonical.ref.content_sequence);
            try encoder.writeInt(u64, scene.canonical.ref.row_space_revision);
            try encoder.writeInt(
                u32,
                if (canonical_changed) scene.canonical.content.bounds.rows else 0,
            );
            try encoder.writeInt(
                u32,
                if (canonical_changed) scene.canonical.content.bounds.columns else 0,
            );
            try encoder.writeInt(
                u8,
                if (canonical_changed)
                    @intFromEnum(scene.canonical.content.screen)
                else
                    0,
            );
            try encoder.writeBytes(&.{ 0, 0, 0, 0, 0, 0, 0 });
            try encoder.writeBytes(&scene.presentation.ref.presentation_id);
            try encoder.writeInt(u64, scene.presentation.ref.generation);
            try encoder.writeInt(u64, scene.presentation.ref.sequence);
            try encoder.writeInt(u64, 0);
            try encoder.writeInt(u64, 0);
            std.debug.assert(encoder.bytes.items.len == wire_header_size);

            switch (options.canonical_kind) {
                .unchanged => {},
                .full => try encodeCanonical(
                    &encoder,
                    &scene.canonical,
                    options.wire_version,
                ),
                .delta => try encodeCanonicalDelta(
                    &encoder,
                    options.canonical_base.?,
                    &scene.canonical,
                    options.wire_version,
                ),
            }
            if (options.presentation_kind == .full)
                try encodePresentation(
                    &encoder,
                    &scene.presentation,
                    options.wire_version,
                );

            return try encoder.bytes.toOwnedSlice(alloc);
        }

        /// Decode independently sequenced sections. An unchanged section is
        /// represented only by its exact cached reference and never creates
        /// an arena or calls the allocator. A partial result must be validated
        /// and consumed through Scene.applyUpdate before it is rendered.
        pub fn decodeAlloc(
            alloc: Allocator,
            encoded: []const u8,
            expected: Scene.DecodeExpectation,
            limits: Scene.Limits,
        ) CodecError!Scene.Update {
            if (encoded.len > limits.max_encoded_bytes) return error.LimitExceeded;
            var decoder: Decoder = .{ .bytes = encoded };
            const header = try decodeAndValidateHeader(&decoder, expected, limits);
            var logical_budget: LogicalAllocationBudget = .{
                .remaining = limits.max_allocation_bytes,
            };
            const allocation_budget = try Scene.AllocationBudget.create(
                alloc,
                limits.max_allocation_bytes,
            );
            errdefer allocation_budget.release();

            var canonical: Scene.CanonicalUpdate = switch (header.canonical_kind) {
                .unchanged => .{ .unchanged = header.canonical_ref },
                .full => .{ .full = try decodeCanonical(
                    &decoder,
                    header,
                    limits,
                    &logical_budget,
                    allocation_budget,
                ) },
                .delta => .{ .full = try decodeCanonicalDelta(
                    &decoder,
                    header,
                    expected.canonical_cache orelse
                        return error.ReplayRejected,
                    limits,
                    &logical_budget,
                    allocation_budget,
                ) },
            };
            errdefer switch (canonical) {
                .unchanged => {},
                .full => |*section| section.deinit(),
            };

            var presentation: Scene.PresentationUpdate = switch (header.presentation_kind) {
                .unchanged => .{ .unchanged = header.presentation_ref },
                .full => .{ .full = try decodePresentation(
                    &decoder,
                    header,
                    limits,
                    &logical_budget,
                    allocation_budget,
                ) },
                .delta => unreachable,
            };
            errdefer switch (presentation) {
                .unchanged => {},
                .full => |*section| section.deinit(),
            };

            if (!decoder.done()) return error.TrailingData;
            if (canonical == .full and presentation == .full) {
                try Validation.validatePair(
                    &canonical.full.value,
                    &presentation.full.value,
                    expected.supported_capabilities,
                    limits,
                );
            }

            allocation_budget.release();
            return .{
                .required_capabilities = header.required,
                .canonical = canonical,
                .presentation = presentation,
            };
        }

        fn validateSectionKinds(
            canonical: Scene.SectionKind,
            presentation: Scene.SectionKind,
        ) CodecError!void {
            if (presentation == .delta)
                return error.UnsupportedSnapshotKind;
            if (canonical == .unchanged and presentation == .unchanged)
                return error.InvalidHeader;
        }

        fn decodeAndValidateHeader(
            decoder: *Decoder,
            expected: Scene.DecodeExpectation,
            limits: Scene.Limits,
        ) CodecError!Header {
            if (Scene.identityIsZero(expected.terminal_id) or
                expected.terminal_epoch == 0 or
                Scene.identityIsZero(expected.presentation_id) or
                expected.presentation_generation == 0)
                return error.InvalidIdentity;
            if (expected.canonical_ref) |cached| {
                if (!std.mem.eql(u8, &cached.terminal_id, &expected.terminal_id) or
                    cached.terminal_epoch != expected.terminal_epoch or
                    cached.content_sequence == 0)
                    return error.InvalidHeader;
            }
            if (expected.presentation_ref) |cached| {
                if (!std.mem.eql(
                    u8,
                    &cached.presentation_id,
                    &expected.presentation_id,
                ) or cached.generation != expected.presentation_generation or
                    cached.sequence == 0)
                    return error.InvalidHeader;
            }
            if (!std.mem.eql(u8, try decoder.readBytes(wire_magic.len), &wire_magic))
                return error.InvalidMagic;
            const encoded_version = try decoder.readInt(u16);
            if (encoded_version != wire_version_static and
                encoded_version != wire_version_kitty and
                encoded_version != wire_version)
                return error.UnsupportedVersion;
            if (try decoder.readInt(u16) != wire_header_size)
                return error.InvalidHeader;

            const required: Scene.CapabilityManifest = .{
                .bits = try decoder.readInt(u64),
            };
            if (!required.validRequired()) return error.InvalidCapabilityManifest;
            if (!expected.supported_capabilities.validRequired() or
                !expected.supported_capabilities.containsAll(required))
                return error.UnsupportedCapability;
            const canonical_kind = try decoder.readEnum(Scene.SectionKind);
            const presentation_kind = try decoder.readEnum(Scene.SectionKind);
            try validateSectionKinds(canonical_kind, presentation_kind);
            if (try decoder.readInt(u8) != 0) return error.InvalidHeader;
            if (!std.mem.eql(
                u8,
                try decoder.readBytes(5),
                &.{ 0, 0, 0, 0, 0 },
            )) return error.InvalidHeader;

            var terminal_id: Scene.TerminalIdentity = undefined;
            @memcpy(&terminal_id, try decoder.readBytes(terminal_id.len));
            const terminal_epoch = try decoder.readInt(u64);
            const content_sequence = try decoder.readInt(u64);
            const row_space_revision = try decoder.readInt(u64);
            const rows = try decoder.readInt(u32);
            const columns = try decoder.readInt(u32);
            const screen_raw = try decoder.readInt(u8);
            if (!std.mem.eql(
                u8,
                try decoder.readBytes(7),
                &.{ 0, 0, 0, 0, 0, 0, 0 },
            )) return error.InvalidHeader;
            var presentation_id: Scene.PresentationIdentity = undefined;
            @memcpy(&presentation_id, try decoder.readBytes(presentation_id.len));
            const presentation_generation = try decoder.readInt(u64);
            const presentation_sequence = try decoder.readInt(u64);
            if (try decoder.readInt(u64) != 0 or try decoder.readInt(u64) != 0)
                return error.InvalidHeader;
            if (decoder.index != wire_header_size) return error.InvalidHeader;

            if (Scene.identityIsZero(terminal_id))
                return error.InvalidIdentity;
            if (terminal_epoch == 0 or content_sequence == 0)
                return error.InvalidSequence;
            if (Scene.identityIsZero(presentation_id))
                return error.InvalidIdentity;
            if (presentation_generation == 0 or presentation_sequence == 0)
                return error.InvalidSequence;
            if (!std.mem.eql(u8, &terminal_id, &expected.terminal_id) or
                terminal_epoch != expected.terminal_epoch)
                return error.WrongTerminal;
            if (!std.mem.eql(u8, &presentation_id, &expected.presentation_id) or
                presentation_generation != expected.presentation_generation)
                return error.WrongPresentation;

            const canonical_ref: Scene.CanonicalSceneRef = .{
                .terminal_id = terminal_id,
                .terminal_epoch = terminal_epoch,
                .content_sequence = content_sequence,
                .row_space_revision = row_space_revision,
            };
            switch (canonical_kind) {
                .unchanged => {
                    const cached = expected.canonical_ref orelse
                        return error.ReplayRejected;
                    if (!Validation.canonicalRefEqual(canonical_ref, cached))
                        return error.ReplayRejected;
                    if (rows != 0 or columns != 0 or screen_raw != 0)
                        return error.InvalidHeader;
                },
                .full, .delta => {
                    try Validation.validateChangedSequence(
                        content_sequence,
                        if (expected.canonical_ref) |value|
                            value.content_sequence
                        else
                            null,
                    );
                    if (rows == 0 or columns == 0)
                        return error.InvalidDimensions;
                    if (rows > limits.max_rows or columns > limits.max_columns)
                        return error.LimitExceeded;
                    const minimum_cells = std.math.mul(usize, rows, columns) catch
                        return error.LimitExceeded;
                    if (minimum_cells > limits.max_cells)
                        return error.LimitExceeded;
                    if (canonical_kind == .delta) {
                        const cached = expected.canonical_ref orelse
                            return error.ReplayRejected;
                        const cache = expected.canonical_cache orelse
                            return error.ReplayRejected;
                        if (!Validation.canonicalRefEqual(cache.ref, cached))
                            return error.ReplayRejected;
                    }
                },
            }

            const presentation_ref: Scene.PresentationSceneRef = .{
                .presentation_id = presentation_id,
                .generation = presentation_generation,
                .sequence = presentation_sequence,
            };
            switch (presentation_kind) {
                .unchanged => {
                    const cached = expected.presentation_ref orelse
                        return error.ReplayRejected;
                    if (!Validation.presentationRefEqual(presentation_ref, cached))
                        return error.ReplayRejected;
                },
                .full => try Validation.validateChangedSequence(
                    presentation_sequence,
                    if (expected.presentation_ref) |value| value.sequence else null,
                ),
                .delta => unreachable,
            }

            return .{
                .wire_version = encoded_version,
                .required = required,
                .canonical_kind = canonical_kind,
                .presentation_kind = presentation_kind,
                .canonical_ref = canonical_ref,
                .bounds = if (canonical_kind != .unchanged) .{
                    .rows = rows,
                    .columns = columns,
                } else null,
                .screen = if (canonical_kind != .unchanged)
                    std.meta.intToEnum(Scene.Screen, screen_raw) catch
                        return error.InvalidEnum
                else
                    null,
                .presentation_ref = presentation_ref,
            };
        }

        fn encodeCanonical(
            encoder: *Encoder,
            canonical: *const Scene.CanonicalSceneEnvelope,
            version: u16,
        ) CodecError!void {
            const content = canonical.content;
            try encoder.writeInt(u64, content.row_start);
            try encoder.writeInt(u64, content.row_total);
            try encodeColors(encoder, content.colors);

            try encodeViewportCoordinate(encoder, content.cursor.active);
            try encodeCursorCell(encoder, content.cursor.cell);
            try encodeStyle(encoder, content.cursor.style);
            try encoder.writeEnum(content.cursor.visual_style);
            var cursor_flags: u8 = 0;
            if (content.cursor.password_input) cursor_flags |= 1 << 0;
            if (content.cursor.visible) cursor_flags |= 1 << 1;
            if (content.cursor.blinking) cursor_flags |= 1 << 2;
            try encoder.writeInt(u8, cursor_flags);
            try encoder.writeInt(u32, content.image_count);
            try encoder.writeInt(u64, content.kitty_generation);
            try encodeKittyResources(encoder, content.kitty_resources, null);
            try encodeKittyImages(encoder, content.kitty_images, version);
            if (version >= wire_version_kitty)
                try encodeKittyFrames(encoder, content.kitty_frames);

            try encoder.writeCount(content.rows.len);
            for (content.rows) |row| try encodeRow(encoder, row);
        }

        fn encodeCanonicalDelta(
            encoder: *Encoder,
            base: *const Scene.CanonicalSceneEnvelope,
            current: *const Scene.CanonicalSceneEnvelope,
            version: u16,
        ) CodecError!void {
            try encoder.writeInt(u64, base.ref.content_sequence);
            const content = current.content;
            try encoder.writeInt(u64, content.row_start);
            try encoder.writeInt(u64, content.row_total);
            try encodeColors(encoder, content.colors);
            try encodeViewportCoordinate(encoder, content.cursor.active);
            try encodeCursorCell(encoder, content.cursor.cell);
            try encodeStyle(encoder, content.cursor.style);
            try encoder.writeEnum(content.cursor.visual_style);
            var cursor_flags: u8 = 0;
            if (content.cursor.password_input) cursor_flags |= 1 << 0;
            if (content.cursor.visible) cursor_flags |= 1 << 1;
            if (content.cursor.blinking) cursor_flags |= 1 << 2;
            try encoder.writeInt(u8, cursor_flags);
            try encoder.writeInt(u32, content.image_count);
            try encoder.writeInt(u64, content.kitty_generation);
            try encodeKittyResources(
                encoder,
                content.kitty_resources,
                base.content.kitty_resources,
            );
            try encodeKittyImages(encoder, content.kitty_images, version);
            if (version >= wire_version_kitty)
                try encodeKittyFrames(encoder, content.kitty_frames);
            try encoder.writeCount(content.rows.len);

            var changed: usize = 0;
            for (content.rows, base.content.rows) |row, base_row| {
                if (!rowEqual(row, base_row)) changed += 1;
            }
            try encoder.writeCount(changed);
            for (content.rows, base.content.rows, 0..) |row, base_row, index| {
                if (rowEqual(row, base_row)) continue;
                try encoder.writeInt(u32, @intCast(index));
                try encodeRow(encoder, row);
            }
        }

        fn encodeRow(encoder: *Encoder, row: Scene.Row) CodecError!void {
            try encoder.writeInt(u64, row.anchor.absolute_row);
            try encoder.writeInt(u32, row.backing_index);
            try encoder.writeInt(u32, row.column_start);
            try encoder.writeInt(u32, row.column_count);
            var row_flags: u8 = 0;
            if (row.wrap) row_flags |= 1 << 0;
            if (row.wrap_continuation) row_flags |= 1 << 1;
            if (row.kitty_virtual_placeholder) row_flags |= 1 << 2;
            try encoder.writeInt(u8, row_flags);
            try encoder.writeEnum(row.semantic_prompt);
            try encoder.writeCount(row.cells.len);
            for (row.cells) |cell| try encodeCell(encoder, cell);
        }

        fn rowEqual(left: Scene.Row, right: Scene.Row) bool {
            if (!std.meta.eql(left.anchor, right.anchor) or
                left.backing_index != right.backing_index or
                left.column_start != right.column_start or
                left.column_count != right.column_count or
                left.wrap != right.wrap or
                left.wrap_continuation != right.wrap_continuation or
                left.semantic_prompt != right.semantic_prompt or
                left.kitty_virtual_placeholder != right.kitty_virtual_placeholder or
                left.cells.len != right.cells.len)
                return false;
            for (left.cells, right.cells) |lhs, rhs| {
                if (lhs.column != rhs.column or lhs.wide_role != rhs.wide_role or
                    lhs.protected != rhs.protected or
                    !std.meta.eql(lhs.hyperlink, rhs.hyperlink) or
                    lhs.semantic_content != rhs.semantic_content or
                    !std.meta.eql(lhs.style, rhs.style) or
                    std.meta.activeTag(lhs.content) != std.meta.activeTag(rhs.content))
                    return false;
                switch (lhs.content) {
                    .codepoint => |value| if (value != rhs.content.codepoint) return false,
                    .grapheme => |values| if (!std.mem.eql(
                        u21,
                        values,
                        rhs.content.grapheme,
                    )) return false,
                    .background_palette => |value| if (value != rhs.content.background_palette)
                        return false,
                    .background_rgb => |value| if (!std.meta.eql(
                        value,
                        rhs.content.background_rgb,
                    )) return false,
                }
            }
            return true;
        }

        fn encodePresentation(
            encoder: *Encoder,
            envelope: *const Scene.PresentationEnvelope,
            version: u16,
        ) CodecError!void {
            const presentation = envelope.content;
            try encoder.writeCount(presentation.selections.len);
            for (presentation.selections) |selection| {
                try encodeRowAnchor(encoder, selection.row);
                try encoder.writeInt(u32, selection.start);
                try encoder.writeInt(u32, selection.end);
            }
            try encoder.writeCount(presentation.highlights.len);
            for (presentation.highlights) |highlight| {
                try encodeRowAnchor(encoder, highlight.row);
                try encoder.writeInt(u32, highlight.start);
                try encoder.writeInt(u32, highlight.end);
                try encoder.writeEnum(highlight.kind);
            }
            try encoder.writeCount(presentation.active_links.len);
            for (presentation.active_links) |coordinate|
                try encodeCoordinate(encoder, coordinate);
            try encoder.writeCount(presentation.preedit.len);
            for (presentation.preedit) |codepoint| {
                try encoder.writeInt(u32, codepoint.codepoint);
                try encoder.writeBool(codepoint.wide);
            }
            if (version >= wire_version) {
                try encoder.writeInt(u32, presentation.preedit_selection_start_utf16);
                try encoder.writeInt(u32, presentation.preedit_selection_length_utf16);
                try encoder.writeInt(u32, presentation.preedit_caret_utf16);
            }
            try encoder.writeCount(presentation.overlay_features.len);
            for (presentation.overlay_features) |feature|
                try encoder.writeEnum(feature);
            if (presentation.hover) |hover| {
                try encoder.writeBool(true);
                try encodeCoordinate(encoder, hover);
            } else try encoder.writeBool(false);
            if (presentation.cursor_viewport) |viewport| {
                try encoder.writeBool(true);
                try encodeViewportCoordinate(encoder, viewport.coordinate);
                try encoder.writeBool(viewport.wide_tail);
            } else try encoder.writeBool(false);
            try encoder.writeBool(presentation.focused);
            try encoder.writeBool(presentation.cursor_blink_visible);
            try encoder.writeInt(u64, presentation.scrollbar.offset);
            try encoder.writeInt(u64, presentation.scrollbar.len);
            try encoder.writeInt(u64, presentation.scrollbar.row_space_revision);
            try encoder.writeInt(u32, presentation.custom_shader_count);
            try encoder.writeCount(presentation.kitty_placements.len);
            for (presentation.kitty_placements) |placement|
                try encodeKittyPlacement(encoder, placement);
        }

        fn decodeCanonical(
            decoder: *Decoder,
            header: Header,
            limits: Scene.Limits,
            logical_budget: *LogicalAllocationBudget,
            allocation_budget: *Scene.AllocationBudget,
        ) CodecError!Scene.OwnedCanonicalSection {
            const bounds = header.bounds.?;
            const screen = header.screen.?;
            // Header dimensions and the fixed grid minimum are validated
            // before creating an arena or attempting any allocation.
            try logical_budget.ensure(bounds.rows, @sizeOf(Scene.Row));
            try logical_budget.ensureProduct(bounds.rows, bounds.columns, @sizeOf(Scene.Cell));

            allocation_budget.retain();
            errdefer allocation_budget.release();
            var arena = std.heap.ArenaAllocator.init(allocation_budget.allocator());
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();

            const row_start = try decoder.readInt(u64);
            const row_total = try decoder.readInt(u64);
            const colors = try decodeColors(decoder);
            const active = try decodeViewportCoordinate(decoder, bounds);
            const cursor_cell = try decodeCursorCell(decoder);
            const cursor_style = try decodeStyle(decoder);
            const visual_style = try decoder.readEnum(Scene.CursorStyle);
            const cursor_flags = try decoder.readInt(u8);
            if (cursor_flags & ~@as(u8, 0x07) != 0)
                return error.InvalidBoolean;
            const image_count = try decoder.readInt(u32);
            const kitty_generation = try decoder.readInt(u64);
            const kitty_resources = try decodeKittyResources(
                decoder,
                arena_alloc,
                logical_budget,
                limits,
                null,
            );
            const kitty_images = try decodeKittyImages(
                decoder,
                arena_alloc,
                logical_budget,
                limits,
                header.wire_version,
            );
            const kitty_frames = if (header.wire_version >= wire_version_kitty)
                try decodeKittyFrames(
                    decoder,
                    arena_alloc,
                    logical_budget,
                    limits,
                )
            else
                try arena_alloc.alloc(Scene.KittyAnimationFrame, 0);
            const row_count = try decoder.readCount(limits.max_rows);
            if (row_count < bounds.rows) return error.InvalidDimensions;
            const cell_count = std.math.mul(usize, row_count, bounds.columns) catch
                return error.LimitExceeded;
            if (cell_count > limits.max_cells) return error.LimitExceeded;
            const row_bytes = std.math.mul(
                usize,
                row_count,
                @sizeOf(Scene.Row),
            ) catch return error.LimitExceeded;
            const cell_bytes = std.math.mul(
                usize,
                cell_count,
                @sizeOf(Scene.Cell),
            ) catch return error.LimitExceeded;
            try logical_budget.ensureBytes(std.math.add(
                usize,
                row_bytes,
                cell_bytes,
            ) catch return error.LimitExceeded);

            const rows = try allocSlice(
                Scene.Row,
                arena_alloc,
                row_count,
                22,
                decoder,
                logical_budget,
            );
            var total_graphemes: usize = 0;
            for (rows, 0..) |*row, row_index| {
                const absolute_row = try decoder.readInt(u64);
                const backing_index = try decoder.readInt(u32);
                const column_start = try decoder.readInt(u32);
                const column_count = try decoder.readInt(u32);
                const row_flags = try decoder.readInt(u8);
                if (row_flags & ~@as(u8, 0x07) != 0)
                    return error.InvalidBoolean;
                const semantic_prompt = try decoder.readEnum(Scene.SemanticPrompt);
                const count = try decoder.readCount(limits.max_cells);
                if (count != bounds.columns) return error.InvalidIdentity;
                const cells = try allocSlice(
                    Scene.Cell,
                    arena_alloc,
                    count,
                    10,
                    decoder,
                    logical_budget,
                );
                for (cells, 0..) |*cell, column| {
                    cell.* = try decodeCell(
                        decoder,
                        arena_alloc,
                        logical_budget,
                        @intCast(column),
                        limits,
                        &total_graphemes,
                    );
                }
                row.* = .{
                    .anchor = .{
                        .row_space_revision = header.canonical_ref.row_space_revision,
                        .absolute_row = absolute_row,
                    },
                    .backing_index = backing_index,
                    .column_start = column_start,
                    .column_count = column_count,
                    .wrap = row_flags & (1 << 0) != 0,
                    .wrap_continuation = row_flags & (1 << 1) != 0,
                    .kitty_virtual_placeholder = row_flags & (1 << 2) != 0,
                    .semantic_prompt = semantic_prompt,
                    .cells = cells,
                };
                _ = row_index;
            }

            return .{
                .arena = arena,
                .budget = allocation_budget,
                .value = .{
                    .ref = header.canonical_ref,
                    .snapshot_kind = .full,
                    .base_content_sequence = null,
                    .required_capabilities = header.required,
                    .content = .{
                        .bounds = bounds,
                        .row_start = row_start,
                        .row_total = row_total,
                        .screen = screen,
                        .colors = colors,
                        .cursor = .{
                            .active = active,
                            .cell = cursor_cell,
                            .style = cursor_style,
                            .visual_style = visual_style,
                            .password_input = cursor_flags & (1 << 0) != 0,
                            .visible = cursor_flags & (1 << 1) != 0,
                            .blinking = cursor_flags & (1 << 2) != 0,
                        },
                        .rows = rows,
                        .image_count = image_count,
                        .kitty_generation = kitty_generation,
                        .kitty_resources = kitty_resources,
                        .kitty_images = kitty_images,
                        .kitty_frames = kitty_frames,
                    },
                },
            };
        }

        fn decodeCanonicalDelta(
            decoder: *Decoder,
            header: Header,
            base: *const Scene.CanonicalSceneEnvelope,
            limits: Scene.Limits,
            logical_budget: *LogicalAllocationBudget,
            allocation_budget: *Scene.AllocationBudget,
        ) CodecError!Scene.OwnedCanonicalSection {
            const bounds = header.bounds.?;
            const screen = header.screen.?;
            const base_sequence = try decoder.readInt(u64);
            if (base_sequence != base.ref.content_sequence or
                !std.mem.eql(
                    u8,
                    &base.ref.terminal_id,
                    &header.canonical_ref.terminal_id,
                ) or base.ref.terminal_epoch != header.canonical_ref.terminal_epoch)
                return error.ReplayRejected;

            allocation_budget.retain();
            errdefer allocation_budget.release();
            var arena = std.heap.ArenaAllocator.init(allocation_budget.allocator());
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();

            const row_start = try decoder.readInt(u64);
            const row_total = try decoder.readInt(u64);
            const colors = try decodeColors(decoder);
            const active = try decodeViewportCoordinate(decoder, bounds);
            const cursor_cell = try decodeCursorCell(decoder);
            const cursor_style = try decodeStyle(decoder);
            const visual_style = try decoder.readEnum(Scene.CursorStyle);
            const cursor_flags = try decoder.readInt(u8);
            if (cursor_flags & ~@as(u8, 0x07) != 0)
                return error.InvalidBoolean;
            const image_count = try decoder.readInt(u32);
            const kitty_generation = try decoder.readInt(u64);
            const kitty_resources = try decodeKittyResources(
                decoder,
                arena_alloc,
                logical_budget,
                limits,
                base.content.kitty_resources,
            );
            const kitty_images = try decodeKittyImages(
                decoder,
                arena_alloc,
                logical_budget,
                limits,
                header.wire_version,
            );
            const kitty_frames = if (header.wire_version >= wire_version_kitty)
                try decodeKittyFrames(
                    decoder,
                    arena_alloc,
                    logical_budget,
                    limits,
                )
            else
                try arena_alloc.alloc(Scene.KittyAnimationFrame, 0);
            const row_count = try decoder.readCount(limits.max_rows);
            if (row_count != base.content.rows.len or row_count < bounds.rows)
                return error.InvalidDimensions;
            const cell_count = std.math.mul(usize, row_count, bounds.columns) catch
                return error.LimitExceeded;
            if (cell_count > limits.max_cells) return error.LimitExceeded;
            try logical_budget.claim(row_count, @sizeOf(Scene.Row));
            try logical_budget.claim(cell_count, @sizeOf(Scene.Cell));

            const rows = try arena_alloc.alloc(Scene.Row, row_count);
            var total_graphemes: usize = 0;
            for (rows, base.content.rows) |*row, source| {
                row.* = source;
                const cells = try arena_alloc.alloc(Scene.Cell, source.cells.len);
                row.cells = cells;
                for (cells, source.cells) |*cell, source_cell| {
                    cell.* = source_cell;
                    if (source_cell.content == .grapheme) {
                        const values = source_cell.content.grapheme;
                        total_graphemes = std.math.add(
                            usize,
                            total_graphemes,
                            values.len,
                        ) catch return error.LimitExceeded;
                        if (total_graphemes > limits.max_total_grapheme_codepoints)
                            return error.LimitExceeded;
                        try logical_budget.claim(values.len, @sizeOf(u21));
                        cell.content = .{
                            .grapheme = try arena_alloc.dupe(u21, values),
                        };
                    }
                }
            }

            const patch_count = try decoder.readCount(row_count);
            var prior_patch: ?u32 = null;
            for (0..patch_count) |_| {
                const index = try decoder.readInt(u32);
                if (index >= row_count or
                    (prior_patch != null and index <= prior_patch.?))
                    return error.InvalidIdentity;
                prior_patch = index;
                rows[index] = try decodeRow(
                    decoder,
                    arena_alloc,
                    logical_budget,
                    header.canonical_ref.row_space_revision,
                    bounds.columns,
                    limits,
                    &total_graphemes,
                );
            }

            return .{
                .arena = arena,
                .budget = allocation_budget,
                .value = .{
                    .ref = header.canonical_ref,
                    .snapshot_kind = .full,
                    .base_content_sequence = null,
                    .required_capabilities = header.required,
                    .content = .{
                        .bounds = bounds,
                        .row_start = row_start,
                        .row_total = row_total,
                        .screen = screen,
                        .colors = colors,
                        .cursor = .{
                            .active = active,
                            .cell = cursor_cell,
                            .style = cursor_style,
                            .visual_style = visual_style,
                            .password_input = cursor_flags & (1 << 0) != 0,
                            .visible = cursor_flags & (1 << 1) != 0,
                            .blinking = cursor_flags & (1 << 2) != 0,
                        },
                        .rows = rows,
                        .image_count = image_count,
                        .kitty_generation = kitty_generation,
                        .kitty_resources = kitty_resources,
                        .kitty_images = kitty_images,
                        .kitty_frames = kitty_frames,
                    },
                },
            };
        }

        fn decodeRow(
            decoder: *Decoder,
            alloc: Allocator,
            logical_budget: *LogicalAllocationBudget,
            revision: u64,
            columns: u32,
            limits: Scene.Limits,
            total_graphemes: *usize,
        ) CodecError!Scene.Row {
            const absolute_row = try decoder.readInt(u64);
            const backing_index = try decoder.readInt(u32);
            const column_start = try decoder.readInt(u32);
            const column_count = try decoder.readInt(u32);
            const row_flags = try decoder.readInt(u8);
            if (row_flags & ~@as(u8, 0x07) != 0)
                return error.InvalidBoolean;
            const semantic_prompt = try decoder.readEnum(Scene.SemanticPrompt);
            const count = try decoder.readCount(limits.max_cells);
            if (count != columns) return error.InvalidIdentity;
            const cells = try allocSlice(
                Scene.Cell,
                alloc,
                count,
                10,
                decoder,
                logical_budget,
            );
            for (cells, 0..) |*cell, column| cell.* = try decodeCell(
                decoder,
                alloc,
                logical_budget,
                @intCast(column),
                limits,
                total_graphemes,
            );
            return .{
                .anchor = .{
                    .row_space_revision = revision,
                    .absolute_row = absolute_row,
                },
                .backing_index = backing_index,
                .column_start = column_start,
                .column_count = column_count,
                .wrap = row_flags & (1 << 0) != 0,
                .wrap_continuation = row_flags & (1 << 1) != 0,
                .kitty_virtual_placeholder = row_flags & (1 << 2) != 0,
                .semantic_prompt = semantic_prompt,
                .cells = cells,
            };
        }

        fn decodePresentation(
            decoder: *Decoder,
            header: Header,
            limits: Scene.Limits,
            logical_budget: *LogicalAllocationBudget,
            allocation_budget: *Scene.AllocationBudget,
        ) CodecError!Scene.OwnedPresentationSection {
            allocation_budget.retain();
            errdefer allocation_budget.release();
            var arena = std.heap.ArenaAllocator.init(allocation_budget.allocator());
            errdefer arena.deinit();
            const arena_alloc = arena.allocator();
            const revision = header.canonical_ref.row_space_revision;

            const selection_count = try decoder.readCount(limits.max_rows);
            const selections = try allocSlice(
                Scene.ColumnRange,
                arena_alloc,
                selection_count,
                16,
                decoder,
                logical_budget,
            );
            for (selections) |*selection| selection.* = .{
                .row = try decodeRowAnchor(decoder, revision),
                .start = try decoder.readInt(u32),
                .end = try decoder.readInt(u32),
            };
            const highlight_count = try decoder.readCount(limits.max_highlights);
            const highlights = try allocSlice(
                Scene.Highlight,
                arena_alloc,
                highlight_count,
                17,
                decoder,
                logical_budget,
            );
            for (highlights) |*highlight| highlight.* = .{
                .row = try decodeRowAnchor(decoder, revision),
                .start = try decoder.readInt(u32),
                .end = try decoder.readInt(u32),
                .kind = try decoder.readEnum(Scene.HighlightKind),
            };
            const active_link_count = try decoder.readCount(limits.max_cells);
            const active_links = try allocSlice(
                Scene.Coordinate,
                arena_alloc,
                active_link_count,
                12,
                decoder,
                logical_budget,
            );
            for (active_links) |*coordinate|
                coordinate.* = try decodeCoordinate(decoder, revision);
            const preedit_count = try decoder.readCount(limits.max_preedit_codepoints);
            const preedit = try allocSlice(
                Scene.PreeditCodepoint,
                arena_alloc,
                preedit_count,
                5,
                decoder,
                logical_budget,
            );
            for (preedit) |*codepoint| {
                const raw = try decoder.readInt(u32);
                if (raw > std.math.maxInt(u21)) return error.InvalidCodepoint;
                codepoint.* = .{
                    .codepoint = @intCast(raw),
                    .wide = try decoder.readBool(),
                };
            }
            const preedit_selection_start_utf16 = if (header.wire_version >= wire_version)
                try decoder.readInt(u32)
            else
                0;
            const preedit_selection_length_utf16 = if (header.wire_version >= wire_version)
                try decoder.readInt(u32)
            else
                0;
            const preedit_caret_utf16 = if (header.wire_version >= wire_version)
                try decoder.readInt(u32)
            else
                0;
            const overlay_count = try decoder.readCount(limits.max_overlay_features);
            const overlay_features = try allocSlice(
                Scene.OverlayFeature,
                arena_alloc,
                overlay_count,
                1,
                decoder,
                logical_budget,
            );
            for (overlay_features) |*feature|
                feature.* = try decoder.readEnum(Scene.OverlayFeature);
            const hover: ?Scene.Coordinate = if (try decoder.readBool())
                try decodeCoordinate(decoder, revision)
            else
                null;
            const cursor_viewport: ?Scene.CursorViewport = if (try decoder.readBool()) .{
                .coordinate = try decodeViewportCoordinateUnchecked(decoder),
                .wide_tail = try decoder.readBool(),
            } else null;
            const focused = try decoder.readBool();
            const cursor_blink_visible = try decoder.readBool();
            const scrollbar: Scene.Scrollbar = .{
                .offset = try decoder.readInt(u64),
                .len = try decoder.readInt(u64),
                .row_space_revision = try decoder.readInt(u64),
            };
            const custom_shader_count = try decoder.readInt(u32);
            const kitty_placement_count = try decoder.readCount(
                limits.max_kitty_placements,
            );
            const kitty_placements = try allocSlice(
                Scene.KittyPlacement,
                arena_alloc,
                kitty_placement_count,
                60,
                decoder,
                logical_budget,
            );
            for (kitty_placements) |*placement|
                placement.* = try decodeKittyPlacement(decoder);

            return .{
                .arena = arena,
                .budget = allocation_budget,
                .value = .{
                    .ref = header.presentation_ref,
                    .snapshot_kind = .full,
                    .base_sequence = null,
                    .terminal_space = .{
                        .terminal_id = header.canonical_ref.terminal_id,
                        .terminal_epoch = header.canonical_ref.terminal_epoch,
                        .row_space_revision = revision,
                    },
                    .content = .{
                        .selections = selections,
                        .highlights = highlights,
                        .active_links = active_links,
                        .preedit = preedit,
                        .preedit_selection_start_utf16 = preedit_selection_start_utf16,
                        .preedit_selection_length_utf16 = preedit_selection_length_utf16,
                        .preedit_caret_utf16 = preedit_caret_utf16,
                        .overlay_features = overlay_features,
                        .hover = hover,
                        .cursor_viewport = cursor_viewport,
                        .focused = focused,
                        .cursor_blink_visible = cursor_blink_visible,
                        .scrollbar = scrollbar,
                        .custom_shader_count = custom_shader_count,
                        .kitty_placements = kitty_placements,
                    },
                },
            };
        }

        fn encodeKittyResources(
            encoder: *Encoder,
            resources: []const Scene.KittyResource,
            base: ?[]const Scene.KittyResource,
        ) CodecError!void {
            try encoder.writeCount(resources.len);
            for (resources) |resource| {
                try encoder.writeBytes(&resource.digest);
                try encoder.writeInt(u32, resource.width);
                try encoder.writeInt(u32, resource.height);
                try encoder.writeEnum(resource.format);
                const pixels = if (base != null and
                    findKittyResource(base.?, resource.digest) != null)
                    &.{}
                else
                    resource.pixels;
                try encoder.writeCount(pixels.len);
                try encoder.writeBytes(pixels);
            }
        }

        fn encodeKittyImages(
            encoder: *Encoder,
            images: []const Scene.KittyImage,
            version: u16,
        ) CodecError!void {
            try encoder.writeCount(images.len);
            for (images) |image| {
                try encoder.writeInt(u32, image.image_id);
                try encoder.writeInt(u64, image.generation);
                try encoder.writeBytes(&image.resource_digest);
                if (version >= wire_version_kitty) {
                    try encoder.writeEnum(image.animation_state);
                    try encoder.writeInt(u32, image.current_frame);
                    try encoder.writeInt(u32, image.loop_count);
                    try encoder.writeInt(u32, image.frame_count);
                }
            }
        }

        fn encodeKittyFrames(
            encoder: *Encoder,
            frames: []const Scene.KittyAnimationFrame,
        ) CodecError!void {
            try encoder.writeCount(frames.len);
            for (frames) |frame| {
                try encoder.writeInt(u32, frame.image_id);
                try encoder.writeInt(u32, frame.frame_number);
                try encoder.writeBytes(&frame.resource_digest);
                try encoder.writeInt(i32, frame.gap_ms);
                try encoder.writeEnum(frame.composition);
                try encoder.writeEnum(frame.disposal);
                try encoder.writeInt(u32, frame.source_frame);
                try encoder.writeInt(u8, frame.background.r);
                try encoder.writeInt(u8, frame.background.g);
                try encoder.writeInt(u8, frame.background.b);
                try encoder.writeInt(u8, frame.background.a);
            }
        }

        fn encodeKittyPlacement(
            encoder: *Encoder,
            placement: Scene.KittyPlacement,
        ) CodecError!void {
            try encoder.writeInt(u32, placement.image_id);
            try encoder.writeInt(u64, placement.order);
            try encoder.writeInt(i32, placement.x);
            try encoder.writeInt(i32, placement.y);
            try encoder.writeInt(i32, placement.z);
            try encoder.writeInt(u32, placement.width);
            try encoder.writeInt(u32, placement.height);
            try encoder.writeInt(u32, placement.cell_offset_x);
            try encoder.writeInt(u32, placement.cell_offset_y);
            try encoder.writeInt(u32, placement.source_x);
            try encoder.writeInt(u32, placement.source_y);
            try encoder.writeInt(u32, placement.source_width);
            try encoder.writeInt(u32, placement.source_height);
            try encoder.writeInt(u32, placement.animation_frame);
        }

        fn decodeKittyResources(
            decoder: *Decoder,
            alloc: Allocator,
            logical_budget: *LogicalAllocationBudget,
            limits: Scene.Limits,
            base: ?[]const Scene.KittyResource,
        ) CodecError![]Scene.KittyResource {
            const count = try decoder.readCount(limits.max_kitty_resources);
            const resources = try allocSlice(
                Scene.KittyResource,
                alloc,
                count,
                45,
                decoder,
                logical_budget,
            );
            var total_bytes: usize = 0;
            for (resources) |*resource| {
                @memcpy(&resource.digest, try decoder.readBytes(resource.digest.len));
                resource.width = try decoder.readInt(u32);
                resource.height = try decoder.readInt(u32);
                resource.format = try decoder.readEnum(Scene.KittyPixelFormat);
                const encoded_length = try decoder.readCount(
                    limits.max_kitty_resource_bytes,
                );
                const source = if (encoded_length > 0)
                    try decoder.readBytes(encoded_length)
                else source: {
                    const prior = findKittyResource(
                        base orelse return error.ReplayRejected,
                        resource.digest,
                    ) orelse return error.ReplayRejected;
                    if (prior.width != resource.width or
                        prior.height != resource.height or
                        prior.format != resource.format)
                        return error.InvalidIdentity;
                    break :source prior.pixels;
                };
                total_bytes = std.math.add(
                    usize,
                    total_bytes,
                    source.len,
                ) catch return error.LimitExceeded;
                if (total_bytes > limits.max_kitty_resource_bytes)
                    return error.LimitExceeded;
                try logical_budget.claim(source.len, @sizeOf(u8));
                resource.pixels = try alloc.dupe(u8, source);
            }
            return resources;
        }

        fn decodeKittyImages(
            decoder: *Decoder,
            alloc: Allocator,
            logical_budget: *LogicalAllocationBudget,
            limits: Scene.Limits,
            version: u16,
        ) CodecError![]Scene.KittyImage {
            const count = try decoder.readCount(limits.max_kitty_resources);
            const images = try allocSlice(
                Scene.KittyImage,
                alloc,
                count,
                if (version >= wire_version_kitty) 57 else 44,
                decoder,
                logical_budget,
            );
            for (images) |*image| {
                image.image_id = try decoder.readInt(u32);
                image.generation = try decoder.readInt(u64);
                @memcpy(
                    &image.resource_digest,
                    try decoder.readBytes(image.resource_digest.len),
                );
                if (version >= wire_version_kitty) {
                    image.animation_state = try decoder.readEnum(
                        Scene.KittyAnimationState,
                    );
                    image.current_frame = try decoder.readInt(u32);
                    image.loop_count = try decoder.readInt(u32);
                    image.frame_count = try decoder.readInt(u32);
                } else {
                    image.animation_state = .stopped;
                    image.current_frame = 1;
                    image.loop_count = 1;
                    image.frame_count = 1;
                }
            }
            return images;
        }

        fn decodeKittyFrames(
            decoder: *Decoder,
            alloc: Allocator,
            logical_budget: *LogicalAllocationBudget,
            limits: Scene.Limits,
        ) CodecError![]Scene.KittyAnimationFrame {
            const count = try decoder.readCount(limits.max_kitty_frames);
            const frames = try allocSlice(
                Scene.KittyAnimationFrame,
                alloc,
                count,
                54,
                decoder,
                logical_budget,
            );
            for (frames) |*frame| {
                frame.* = .{
                    .image_id = try decoder.readInt(u32),
                    .frame_number = try decoder.readInt(u32),
                    .resource_digest = undefined,
                    .gap_ms = 0,
                    .composition = .alpha_blend,
                    .disposal = .retain_canvas,
                    .source_frame = 0,
                };
                @memcpy(
                    &frame.resource_digest,
                    try decoder.readBytes(frame.resource_digest.len),
                );
                frame.gap_ms = try decoder.readInt(i32);
                frame.composition = try decoder.readEnum(
                    Scene.KittyFrameComposition,
                );
                frame.disposal = try decoder.readEnum(Scene.KittyFrameDisposal);
                frame.source_frame = try decoder.readInt(u32);
                frame.background = .{
                    .r = try decoder.readInt(u8),
                    .g = try decoder.readInt(u8),
                    .b = try decoder.readInt(u8),
                    .a = try decoder.readInt(u8),
                };
            }
            return frames;
        }

        fn decodeKittyPlacement(
            decoder: *Decoder,
        ) CodecError!Scene.KittyPlacement {
            return .{
                .image_id = try decoder.readInt(u32),
                .order = try decoder.readInt(u64),
                .x = try decoder.readInt(i32),
                .y = try decoder.readInt(i32),
                .z = try decoder.readInt(i32),
                .width = try decoder.readInt(u32),
                .height = try decoder.readInt(u32),
                .cell_offset_x = try decoder.readInt(u32),
                .cell_offset_y = try decoder.readInt(u32),
                .source_x = try decoder.readInt(u32),
                .source_y = try decoder.readInt(u32),
                .source_width = try decoder.readInt(u32),
                .source_height = try decoder.readInt(u32),
                .animation_frame = try decoder.readInt(u32),
            };
        }

        fn findKittyResource(
            resources: []const Scene.KittyResource,
            digest: Scene.KittyResourceDigest,
        ) ?*const Scene.KittyResource {
            var low: usize = 0;
            var high = resources.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                switch (std.mem.order(u8, &resources[mid].digest, &digest)) {
                    .lt => low = mid + 1,
                    .gt => high = mid,
                    .eq => return &resources[mid],
                }
            }
            return null;
        }

        const Encoder = struct {
            alloc: Allocator,
            limit: usize,
            bytes: std.ArrayList(u8) = .empty,

            fn writeBytes(self: *Encoder, value: []const u8) CodecError!void {
                if (value.len > self.limit -| self.bytes.items.len)
                    return error.LimitExceeded;
                try self.bytes.appendSlice(self.alloc, value);
            }
            fn writeInt(self: *Encoder, comptime T: type, value: T) CodecError!void {
                var bytes: [@sizeOf(T)]u8 = undefined;
                std.mem.writeInt(T, &bytes, value, .little);
                try self.writeBytes(&bytes);
            }
            fn writeCount(self: *Encoder, value: usize) CodecError!void {
                try self.writeInt(u32, std.math.cast(u32, value) orelse
                    return error.LimitExceeded);
            }
            fn writeBool(self: *Encoder, value: bool) CodecError!void {
                try self.writeInt(u8, @intFromBool(value));
            }
            fn writeEnum(self: *Encoder, value: anytype) CodecError!void {
                try self.writeInt(u8, @intCast(@intFromEnum(value)));
            }
            fn writeOptionalRGB(self: *Encoder, value: ?Scene.RGB) CodecError!void {
                if (value) |color| {
                    try self.writeBool(true);
                    try encodeRGB(self, color);
                } else try self.writeBool(false);
            }
        };

        const Decoder = struct {
            bytes: []const u8,
            index: usize = 0,
            fn remaining(self: *const Decoder) usize {
                return self.bytes.len -| self.index;
            }
            fn readBytes(self: *Decoder, count: usize) CodecError![]const u8 {
                if (count > self.remaining()) return error.Truncated;
                defer self.index += count;
                return self.bytes[self.index..][0..count];
            }
            fn readInt(self: *Decoder, comptime T: type) CodecError!T {
                const bytes = try self.readBytes(@sizeOf(T));
                return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
            }
            fn readCount(self: *Decoder, max: anytype) CodecError!usize {
                const value = try self.readInt(u32);
                if (value > max) return error.LimitExceeded;
                return value;
            }
            fn readBool(self: *Decoder) CodecError!bool {
                return switch (try self.readInt(u8)) {
                    0 => false,
                    1 => true,
                    else => error.InvalidBoolean,
                };
            }
            fn readEnum(self: *Decoder, comptime T: type) CodecError!T {
                return std.meta.intToEnum(T, try self.readInt(u8)) catch
                    return error.InvalidEnum;
            }
            fn readOptionalRGB(self: *Decoder) CodecError!?Scene.RGB {
                return if (try self.readBool()) try decodeRGB(self) else null;
            }
            fn done(self: *const Decoder) bool {
                return self.index == self.bytes.len;
            }
        };

        const LogicalAllocationBudget = struct {
            remaining: usize,
            fn ensureBytes(self: *const LogicalAllocationBudget, bytes: usize) CodecError!void {
                if (bytes > self.remaining) return error.LimitExceeded;
            }
            fn ensure(self: *const LogicalAllocationBudget, count: usize, size: usize) CodecError!void {
                const bytes = std.math.mul(usize, count, size) catch
                    return error.LimitExceeded;
                try self.ensureBytes(bytes);
            }
            fn ensureProduct(
                self: *const LogicalAllocationBudget,
                left: usize,
                right: usize,
                size: usize,
            ) CodecError!void {
                const count = std.math.mul(usize, left, right) catch
                    return error.LimitExceeded;
                try self.ensure(count, size);
            }
            fn claim(self: *LogicalAllocationBudget, count: usize, size: usize) CodecError!void {
                const bytes = std.math.mul(usize, count, size) catch
                    return error.LimitExceeded;
                if (bytes > self.remaining) return error.LimitExceeded;
                self.remaining -= bytes;
            }
        };

        fn allocSlice(
            comptime T: type,
            alloc: Allocator,
            count: usize,
            min_wire_bytes: usize,
            decoder: *Decoder,
            budget: *LogicalAllocationBudget,
        ) CodecError![]T {
            const minimum = std.math.mul(usize, count, min_wire_bytes) catch
                return error.LimitExceeded;
            if (minimum > decoder.remaining()) return error.Truncated;
            try budget.claim(count, @sizeOf(T));
            return try alloc.alloc(T, count);
        }

        fn encodeRGB(encoder: *Encoder, value: Scene.RGB) CodecError!void {
            try encoder.writeInt(u8, value.r);
            try encoder.writeInt(u8, value.g);
            try encoder.writeInt(u8, value.b);
        }
        fn decodeRGB(decoder: *Decoder) CodecError!Scene.RGB {
            return .{
                .r = try decoder.readInt(u8),
                .g = try decoder.readInt(u8),
                .b = try decoder.readInt(u8),
            };
        }
        fn encodeColors(encoder: *Encoder, value: Scene.Colors) CodecError!void {
            try encoder.writeOptionalRGB(value.background_override);
            try encoder.writeOptionalRGB(value.foreground_override);
            try encoder.writeOptionalRGB(value.cursor_override);
            try encoder.writeBool(value.reverse);
            try encoder.writeBytes(&value.palette_mask);
            for (0..value.palette.len) |index| {
                if (!value.paletteIsSet(@intCast(index))) continue;
                try encodeRGB(encoder, value.palette[index]);
            }
        }
        fn decodeColors(decoder: *Decoder) CodecError!Scene.Colors {
            var result: Scene.Colors = .empty;
            result.background_override = try decoder.readOptionalRGB();
            result.foreground_override = try decoder.readOptionalRGB();
            result.cursor_override = try decoder.readOptionalRGB();
            result.reverse = try decoder.readBool();
            @memcpy(&result.palette_mask, try decoder.readBytes(result.palette_mask.len));
            for (0..result.palette.len) |index| {
                if (!result.paletteIsSet(@intCast(index))) continue;
                result.palette[index] = try decodeRGB(decoder);
            }
            return result;
        }
        fn encodeRowAnchor(encoder: *Encoder, value: Scene.RowAnchor) CodecError!void {
            try encoder.writeInt(u64, value.absolute_row);
        }
        fn decodeRowAnchor(decoder: *Decoder, revision: u64) CodecError!Scene.RowAnchor {
            return .{
                .row_space_revision = revision,
                .absolute_row = try decoder.readInt(u64),
            };
        }
        fn encodeCoordinate(encoder: *Encoder, value: Scene.Coordinate) CodecError!void {
            try encodeRowAnchor(encoder, value.row);
            try encoder.writeInt(u32, value.column);
        }
        fn decodeCoordinate(decoder: *Decoder, revision: u64) CodecError!Scene.Coordinate {
            return .{
                .row = try decodeRowAnchor(decoder, revision),
                .column = try decoder.readInt(u32),
            };
        }
        fn encodeViewportCoordinate(
            encoder: *Encoder,
            value: Scene.ViewportCoordinate,
        ) CodecError!void {
            try encoder.writeInt(u32, value.row);
            try encoder.writeInt(u32, value.column);
        }
        fn decodeViewportCoordinateUnchecked(
            decoder: *Decoder,
        ) CodecError!Scene.ViewportCoordinate {
            return .{
                .row = try decoder.readInt(u32),
                .column = try decoder.readInt(u32),
            };
        }
        fn decodeViewportCoordinate(
            decoder: *Decoder,
            bounds: Scene.Bounds,
        ) CodecError!Scene.ViewportCoordinate {
            const value = try decodeViewportCoordinateUnchecked(decoder);
            if (value.row >= bounds.rows or value.column >= bounds.columns)
                return error.InvalidCoordinate;
            return value;
        }

        fn encodeCursorCell(encoder: *Encoder, value: Scene.CursorCell) CodecError!void {
            switch (value.content) {
                .text => {
                    try encoder.writeInt(u8, 0);
                    try encoder.writeBytes(&.{ 0, 0, 0 });
                },
                .background_palette => |index| {
                    try encoder.writeInt(u8, 1);
                    try encoder.writeBytes(&.{ index, 0, 0 });
                },
                .background_rgb => |color| {
                    try encoder.writeInt(u8, 2);
                    try encodeRGB(encoder, color);
                },
            }
            try encoder.writeEnum(value.wide_role);
        }
        fn decodeCursorCell(decoder: *Decoder) CodecError!Scene.CursorCell {
            const content: Scene.CursorCellContent = switch (try decoder.readInt(u8)) {
                0 => text: {
                    if (!std.mem.eql(u8, try decoder.readBytes(3), &.{ 0, 0, 0 }))
                        return error.InvalidHeader;
                    break :text .text;
                },
                1 => palette: {
                    const index = try decoder.readInt(u8);
                    if (!std.mem.eql(u8, try decoder.readBytes(2), &.{ 0, 0 }))
                        return error.InvalidHeader;
                    break :palette .{ .background_palette = index };
                },
                2 => .{ .background_rgb = try decodeRGB(decoder) },
                else => return error.InvalidEnum,
            };
            return .{
                .content = content,
                .wide_role = try decoder.readEnum(Scene.WideRole),
            };
        }

        fn encodeStyleColor(encoder: *Encoder, value: Scene.StyleColor) CodecError!void {
            switch (value) {
                .none => try encoder.writeInt(u8, 0),
                .palette => |index| {
                    try encoder.writeInt(u8, 1);
                    try encoder.writeInt(u8, index);
                },
                .rgb => |color| {
                    try encoder.writeInt(u8, 2);
                    try encodeRGB(encoder, color);
                },
            }
        }
        fn decodeStyleColor(decoder: *Decoder) CodecError!Scene.StyleColor {
            return switch (try decoder.readInt(u8)) {
                0 => .none,
                1 => .{ .palette = try decoder.readInt(u8) },
                2 => .{ .rgb = try decodeRGB(decoder) },
                else => error.InvalidEnum,
            };
        }
        fn encodeStyle(encoder: *Encoder, value: Scene.Style) CodecError!void {
            try encodeStyleColor(encoder, value.foreground);
            try encodeStyleColor(encoder, value.background);
            try encodeStyleColor(encoder, value.underline_color);
            var flags: u16 = 0;
            if (value.bold) flags |= 1 << 0;
            if (value.italic) flags |= 1 << 1;
            if (value.faint) flags |= 1 << 2;
            if (value.blink) flags |= 1 << 3;
            if (value.inverse) flags |= 1 << 4;
            if (value.invisible) flags |= 1 << 5;
            if (value.strikethrough) flags |= 1 << 6;
            if (value.overline) flags |= 1 << 7;
            flags |= @as(u16, @intFromEnum(value.underline)) << 8;
            try encoder.writeInt(u16, flags);
        }
        fn decodeStyle(decoder: *Decoder) CodecError!Scene.Style {
            const foreground = try decodeStyleColor(decoder);
            const background = try decodeStyleColor(decoder);
            const underline_color = try decodeStyleColor(decoder);
            const flags = try decoder.readInt(u16);
            if (flags & ~@as(u16, 0x07FF) != 0) return error.InvalidScene;
            const underline = std.meta.intToEnum(
                Scene.Underline,
                (flags >> 8) & 0x07,
            ) catch return error.InvalidEnum;
            return .{
                .foreground = foreground,
                .background = background,
                .underline_color = underline_color,
                .bold = flags & (1 << 0) != 0,
                .italic = flags & (1 << 1) != 0,
                .faint = flags & (1 << 2) != 0,
                .blink = flags & (1 << 3) != 0,
                .inverse = flags & (1 << 4) != 0,
                .invisible = flags & (1 << 5) != 0,
                .strikethrough = flags & (1 << 6) != 0,
                .overline = flags & (1 << 7) != 0,
                .underline = underline,
            };
        }

        fn encodeCell(encoder: *Encoder, value: Scene.Cell) CodecError!void {
            try encoder.writeInt(u32, value.column);
            switch (value.content) {
                .codepoint => |codepoint| {
                    try encoder.writeInt(u8, 0);
                    try encoder.writeInt(u32, codepoint);
                },
                .grapheme => |codepoints| {
                    try encoder.writeInt(u8, 1);
                    try encoder.writeCount(codepoints.len);
                    for (codepoints) |codepoint| try encoder.writeInt(u32, codepoint);
                },
                .background_palette => |index| {
                    try encoder.writeInt(u8, 2);
                    try encoder.writeInt(u8, index);
                },
                .background_rgb => |color| {
                    try encoder.writeInt(u8, 3);
                    try encodeRGB(encoder, color);
                },
            }
            try encoder.writeEnum(value.wide_role);
            var flags: u8 = 0;
            if (value.protected) flags |= 1 << 0;
            if (value.hyperlink != null) flags |= 1 << 1;
            try encoder.writeInt(u8, flags);
            if (value.hyperlink) |identity| try encoder.writeBytes(&identity);
            try encoder.writeEnum(value.semantic_content);
            try encodeStyle(encoder, value.style);
        }
        fn decodeCell(
            decoder: *Decoder,
            alloc: Allocator,
            budget: *LogicalAllocationBudget,
            expected_column: u32,
            limits: Scene.Limits,
            total_graphemes: *usize,
        ) CodecError!Scene.Cell {
            const column = try decoder.readInt(u32);
            if (column != expected_column) return error.InvalidIdentity;
            const content: Scene.CellContent = switch (try decoder.readInt(u8)) {
                0 => codepoint: {
                    const raw = try decoder.readInt(u32);
                    if (raw > std.math.maxInt(u21)) return error.InvalidCodepoint;
                    break :codepoint .{ .codepoint = @intCast(raw) };
                },
                1 => grapheme: {
                    const count = try decoder.readCount(
                        limits.max_grapheme_codepoints_per_cell,
                    );
                    if (count == 0) return error.InvalidScene;
                    total_graphemes.* = std.math.add(
                        usize,
                        total_graphemes.*,
                        count,
                    ) catch return error.LimitExceeded;
                    if (total_graphemes.* > limits.max_total_grapheme_codepoints)
                        return error.LimitExceeded;
                    const values = try allocSlice(
                        u21,
                        alloc,
                        count,
                        4,
                        decoder,
                        budget,
                    );
                    for (values) |*value| {
                        const raw = try decoder.readInt(u32);
                        if (raw > std.math.maxInt(u21)) return error.InvalidCodepoint;
                        value.* = @intCast(raw);
                    }
                    break :grapheme .{ .grapheme = values };
                },
                2 => .{ .background_palette = try decoder.readInt(u8) },
                3 => .{ .background_rgb = try decodeRGB(decoder) },
                else => return error.InvalidEnum,
            };
            const wide_role = try decoder.readEnum(Scene.WideRole);
            const flags = try decoder.readInt(u8);
            if (flags & ~@as(u8, 0x03) != 0) return error.InvalidBoolean;
            const hyperlink: ?Scene.HyperlinkIdentity = if (flags & (1 << 1) != 0) link: {
                var identity: Scene.HyperlinkIdentity = undefined;
                @memcpy(&identity, try decoder.readBytes(identity.len));
                break :link identity;
            } else null;
            return .{
                .column = column,
                .content = content,
                .wide_role = wide_role,
                .protected = flags & (1 << 0) != 0,
                .hyperlink = hyperlink,
                .semantic_content = try decoder.readEnum(Scene.SemanticContent),
                .style = try decodeStyle(decoder),
            };
        }
    };
}
