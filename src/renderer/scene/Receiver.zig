//! Bounded semantic-scene decoder/cache for a standalone renderer worker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../../terminal/main.zig");

pub fn Receiver(comptime Scene: type) type {
    return struct {
        const Self = @This();

        alloc: Allocator,
        terminal_id: Scene.TerminalIdentity,
        terminal_epoch: u64,
        presentation_id: Scene.PresentationIdentity,
        presentation_generation: u64,
        supported_capabilities: Scene.CapabilityManifest,
        custom_shader_count: u32,
        limits: Scene.Limits,
        color_defaults: terminal.RenderState.Colors,
        scene: ?Scene.Owned = null,
        materialized: ?Scene.Materialized = null,
        stats: Stats = .{},

        pub const Options = struct {
            terminal_id: Scene.TerminalIdentity,
            terminal_epoch: u64,
            presentation_id: Scene.PresentationIdentity,
            presentation_generation: u64,
            supported_capabilities: Scene.CapabilityManifest = .baseline,
            custom_shader_count: u32 = 0,
            limits: Scene.Limits = .{},
            color_defaults: terminal.RenderState.Colors = terminal.RenderState.empty.colors,
        };

        pub const ApplyKind = enum {
            initial,
            rematerialized,
            presentation_metadata,
        };

        pub const Stats = struct {
            updates_applied: u64 = 0,
            rematerializations: u64 = 0,
            presentation_metadata_fast_paths: u64 = 0,
        };

        pub const Error = Scene.CodecError || Scene.ApplyUpdateError ||
            Scene.Materialized.Error ||
            Scene.Materialized.PresentationUpdateError || error{
            InvalidRoute,
            NoScene,
        };

        pub fn init(alloc: Allocator, options: Options) Error!Self {
            if (Scene.identityIsZero(options.terminal_id) or
                options.terminal_epoch == 0 or
                Scene.identityIsZero(options.presentation_id) or
                options.presentation_generation == 0 or
                !options.supported_capabilities.validRequired() or
                (options.custom_shader_count > 0) !=
                    options.supported_capabilities.contains(.custom_shaders))
                return error.InvalidRoute;
            return .{
                .alloc = alloc,
                .terminal_id = options.terminal_id,
                .terminal_epoch = options.terminal_epoch,
                .presentation_id = options.presentation_id,
                .presentation_generation = options.presentation_generation,
                .supported_capabilities = options.supported_capabilities,
                .custom_shader_count = options.custom_shader_count,
                .limits = options.limits,
                .color_defaults = options.color_defaults,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.materialized) |*value| value.deinit(self.alloc);
            if (self.scene) |*value| value.deinit();
            self.* = undefined;
        }

        pub fn reset(self: *Self, options: Options) Error!void {
            var next = try Self.init(self.alloc, options);
            if (self.materialized) |*value| value.deinit(self.alloc);
            if (self.scene) |*value| value.deinit();
            next.stats = self.stats;
            self.* = next;
        }

        pub fn apply(self: *Self, encoded: []const u8) Error!ApplyKind {
            const expected = self.expectation();
            var update = try Scene.decodeAlloc(
                self.alloc,
                encoded,
                expected,
                self.limits,
            );
            defer update.deinit();

            if (self.scene == null) {
                var initial = try Scene.ownedFromInitialUpdate(
                    &update,
                    self.supported_capabilities,
                    self.limits,
                );
                errdefer initial.deinit();
                try self.validateCustomShaderCount(&initial.presentation);
                var materialized = try Scene.Materialized.initSeeded(
                    self.alloc,
                    &initial,
                    self.supported_capabilities,
                    self.limits,
                    self.color_defaults,
                );
                errdefer materialized.deinit(self.alloc);
                self.scene = initial;
                self.materialized = materialized;
                self.stats.updates_applied += 1;
                self.stats.rematerializations += 1;
                return .initial;
            }

            const cached = &self.scene.?;
            const canonical = switch (update.canonical) {
                .unchanged => &cached.canonical,
                .full => |*section| &section.value,
            };
            const presentation = switch (update.presentation) {
                .unchanged => &cached.presentation,
                .full => |*section| &section.value,
            };
            try self.validateCustomShaderCount(presentation);
            if (update.required_capabilities.bits !=
                canonical.required_capabilities.bits)
                return error.InvalidCapabilityManifest;
            if (update.canonical == .unchanged) {
                try Scene.validatePresentationAgainstCachedCanonical(
                    canonical,
                    presentation,
                    self.limits,
                );
            } else {
                try Scene.validatePair(
                    canonical,
                    presentation,
                    self.supported_capabilities,
                    self.limits,
                );
            }

            const metadata_only = update.canonical == .unchanged and
                update.presentation == .full and metadata: {
                self.materialized.?.updatePresentationMetadata(
                    &cached.canonical,
                    &cached.presentation,
                    presentation,
                    self.limits,
                ) catch |err| switch (err) {
                    error.RequiresRematerialization => break :metadata false,
                    else => return err,
                };
                break :metadata true;
            };

            if (metadata_only) {
                // Validation above makes this move infallible apart from
                // programmer-visible cache inconsistencies.
                try Scene.applyUpdate(
                    cached,
                    &update,
                    self.supported_capabilities,
                    self.limits,
                );
                self.stats.updates_applied += 1;
                self.stats.presentation_metadata_fast_paths += 1;
                return .presentation_metadata;
            }

            // Materialize the candidate pair before moving cache ownership so
            // allocation failure leaves the currently renderable scene intact.
            var materialized = try Scene.Materialized.initPairSeeded(
                self.alloc,
                canonical,
                presentation,
                self.supported_capabilities,
                self.limits,
                self.color_defaults,
            );
            errdefer materialized.deinit(self.alloc);
            try Scene.applyUpdate(
                cached,
                &update,
                self.supported_capabilities,
                self.limits,
            );
            self.materialized.?.deinit(self.alloc);
            self.materialized = materialized;
            self.stats.updates_applied += 1;
            self.stats.rematerializations += 1;
            return .rematerialized;
        }

        pub fn projection(self: *Self) Error!Scene.Projection {
            return if (self.materialized) |*value|
                value.projection()
            else
                error.NoScene;
        }

        pub fn current(self: *const Self) Error!*const Scene.Owned {
            return if (self.scene) |*value| value else error.NoScene;
        }

        fn expectation(self: *const Self) Scene.DecodeExpectation {
            return .{
                .terminal_id = self.terminal_id,
                .terminal_epoch = self.terminal_epoch,
                .canonical_ref = if (self.scene) |*value|
                    value.canonical.ref
                else
                    null,
                .canonical_cache = if (self.scene) |*value|
                    &value.canonical
                else
                    null,
                .presentation_id = self.presentation_id,
                .presentation_generation = self.presentation_generation,
                .presentation_ref = if (self.scene) |*value|
                    value.presentation.ref
                else
                    null,
                .supported_capabilities = self.supported_capabilities,
            };
        }

        fn validateCustomShaderCount(
            self: *const Self,
            presentation: *const Scene.PresentationEnvelope,
        ) error{InvalidCapabilityManifest}!void {
            if (presentation.content.custom_shader_count != self.custom_shader_count)
                return error.InvalidCapabilityManifest;
        }
    };
}
