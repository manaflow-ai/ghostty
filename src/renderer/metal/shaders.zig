const std = @import("std");
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const objc = @import("objc");
const math = @import("../../math.zig");
const global = @import("../../global.zig");

const mtl = @import("api.zig");
const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.metal);

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{ "bg_color", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "bg_color_fragment",
            .blending_enabled = false,
        } },
        .{ "cell_bg", .{
            .vertex_fn = "full_screen_vertex",
            .fragment_fn = "cell_bg_fragment",
            .blending_enabled = true,
        } },
        .{ "cell_text", .{
            .vertex_attributes = CellText,
            .vertex_fn = "cell_text_vertex",
            .fragment_fn = "cell_text_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "image", .{
            .vertex_attributes = Image,
            .vertex_fn = "image_vertex",
            .fragment_fn = "image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
        .{ "bg_image", .{
            .vertex_attributes = BgImage,
            .vertex_fn = "bg_image_vertex",
            .fragment_fn = "bg_image_fragment",
            .step_fn = .per_instance,
            .blending_enabled = true,
        } },
    };

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: []const u8,
    fragment_fn: []const u8,
    step_fn: mtl.MTLVertexStepFunction = .per_vertex,
    blending_enabled: bool,

    fn initPipeline(
        self: PipelineDescription,
        device: objc.Object,
        library: objc.Object,
        pixel_format: mtl.MTLPixelFormat,
    ) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .device = device,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .vertex_library = library,
            .fragment_library = library,
            .step_fn = self.step_fn,
            .attachments = &.{.{
                .pixel_format = pixel_format,
                .blending_enabled = self.blending_enabled,
            }},
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;

    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    library: objc.Object,

    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Custom shaders to run against the final drawable texture. This
    /// can be used to apply a lot of effects. Each shader is run in sequence
    /// against the output of the previous shader.
    post_pipelines: []const Pipeline,

    /// Non-null for a process-wide pipeline cache entry. The cache key includes
    /// custom shader source, so tabs with the same configuration can share
    /// compiled pipelines without conflating distinct user shaders.
    shared: ?*SharedShaders = null,

    /// Set to true when deinited, if you try to deinit a defunct set
    /// of shaders it will just be ignored, to prevent double-free.
    defunct: bool = false,

    /// Initialize our shader set.
    ///
    /// "post_shaders" is an optional list of postprocess shaders to run
    /// against the final drawable texture. This is an array of shader source
    /// code, not file paths.
    ///
    /// The allocator parameter is unused because shared shader state is
    /// process-wide and allocated with `shared_shader_allocator`. It remains
    /// in the signature for graphics API compatibility.
    pub fn init(
        _: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        return try initShared(device, post_shaders, pixel_format);
    }

    fn initOwned(
        alloc: Allocator,
        device: objc.Object,
        post_shaders: []const [:0]const u8,
        pixel_format: mtl.MTLPixelFormat,
    ) !Shaders {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(
                device,
                library,
                pixel_format,
            );
            initialized_pipelines += 1;
        }

        const post_pipelines: []const Pipeline = initPostPipelines(
            alloc,
            device,
            library,
            post_shaders,
            pixel_format,
        ) catch |err| err: {
            // If an error happens while building postprocess shaders we
            // want to just not use any postprocess shaders since we don't
            // want to block Ghostty from working.
            log.warn("error initializing postprocess shaders err={}", .{err});
            break :err &.{};
        };
        errdefer if (post_pipelines.len > 0) {
            for (post_pipelines) |pipeline| pipeline.deinit();
            alloc.free(post_pipelines);
        };

        return .{
            .library = library,
            .pipelines = pipelines,
            .post_pipelines = post_pipelines,
        };
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        if (self.defunct) return;
        self.defunct = true;

        if (self.shared) |entry| {
            releaseShared(entry);
            return;
        }

        self.deinitOwned(alloc);
    }

    fn deinitOwned(self: *Shaders, alloc: Allocator) void {
        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
        self.library.msgSend(void, objc.sel("release"), .{});

        // Release our postprocess shaders
        if (self.post_pipelines.len > 0) {
            for (self.post_pipelines) |pipeline| {
                pipeline.deinit();
            }
            alloc.free(self.post_pipelines);
        }
    }
};

const SharedShadersKey = struct {
    device: usize,
    pixel_format: mtl.MTLPixelFormat,
    post_shaders: []const [:0]const u8,

    fn eql(self: SharedShadersKey, other: SharedShadersKey) bool {
        if (self.device != other.device or
            self.pixel_format != other.pixel_format or
            self.post_shaders.len != other.post_shaders.len)
        {
            return false;
        }

        for (self.post_shaders, other.post_shaders) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs, rhs)) return false;
        }
        return true;
    }
};

const SharedShaders = struct {
    key: SharedShadersKey,
    device: objc.Object,
    library: objc.Object,
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    references: usize,
    retention: Retention,

    const Retention = union(enum) {
        /// Standard shaders remain cached for the process lifetime.
        persistent,

        /// Keep the most recently released successful custom configuration.
        recent_custom,

        /// Reuse a failed custom configuration until this fixed retry
        /// deadline. Renderer ownership does not alter compile policy.
        failed_custom: std.Io.Timestamp,
    };
};

const shared_shader_allocator = std.heap.c_allocator;
const retained_idle_custom_shader_entries = 1;
const retained_idle_failed_shader_entries = 1;
const failed_custom_shader_retry_delay: std.Io.Duration = .fromSeconds(30);
const BoundedRetention = enum { recent_custom, failed_custom };
var shared_shader_mutex: std.Io.Mutex = .init;
var shared_shader_entries: std.ArrayListUnmanaged(*SharedShaders) = .empty;
var shared_shader_build_count = std.atomic.Value(usize).init(0);

fn initShared(
    device: objc.Object,
    post_shaders: []const [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) !Shaders {
    const key: SharedShadersKey = .{
        .device = @intFromPtr(device.value),
        .pixel_format = pixel_format,
        .post_shaders = post_shaders,
    };

    // Pipeline compilation is expensive and Metal retains significant
    // process-wide compiler state even after duplicate pipelines are
    // released. Serialize cache misses so concurrent surface initialization or
    // restoration cannot compile the same pipeline collection more than once.
    shared_shader_mutex.lockUncancelable(global.io());
    defer shared_shader_mutex.unlock(global.io());

    if (findSharedLocked(
        key,
        .now(global.io(), .awake),
    )) |entry| {
        entry.references += 1;
        return shadersFromShared(entry);
    }

    _ = shared_shader_build_count.fetchAdd(1, .monotonic);
    var candidate = try Shaders.initOwned(
        shared_shader_allocator,
        device,
        post_shaders,
        pixel_format,
    );
    const owned_post_shaders = clonePostShaders(post_shaders) catch |err| {
        candidate.deinit(shared_shader_allocator);
        return err;
    };
    errdefer freePostShaders(owned_post_shaders);

    const entry = shared_shader_allocator.create(SharedShaders) catch |err| {
        candidate.deinit(shared_shader_allocator);
        return err;
    };
    entry.* = .{
        .key = .{
            .device = key.device,
            .pixel_format = key.pixel_format,
            .post_shaders = owned_post_shaders,
        },
        .device = device.retain(),
        .library = candidate.library,
        .pipelines = candidate.pipelines,
        .post_pipelines = candidate.post_pipelines,
        .references = 1,
        .retention = if (post_shaders.len == 0)
            .persistent
        else if (candidate.post_pipelines.len == post_shaders.len)
            .recent_custom
        else
            .{ .failed_custom = std.Io.Timestamp
                .now(global.io(), .awake)
                .addDuration(failed_custom_shader_retry_delay) },
    };

    shared_shader_entries.append(
        shared_shader_allocator,
        entry,
    ) catch |err| {
        candidate.deinit(shared_shader_allocator);
        entry.device.release();
        shared_shader_allocator.destroy(entry);
        return err;
    };

    candidate.shared = entry;
    return candidate;
}

fn findSharedLocked(
    key: SharedShadersKey,
    now: std.Io.Timestamp,
) ?*SharedShaders {
    pruneExpiredFailedShadersLocked(now);

    // A successful retry wins over an older failure for the same key.
    for (shared_shader_entries.items) |entry| {
        if (!entry.key.eql(key)) continue;
        switch (entry.retention) {
            .persistent, .recent_custom => return entry,
            .failed_custom => {},
        }
    }

    for (shared_shader_entries.items) |entry| {
        if (!entry.key.eql(key)) continue;
        switch (entry.retention) {
            .failed_custom => |retry_after| {
                if (now.toNanoseconds() < retry_after.toNanoseconds()) {
                    return entry;
                }
            },
            .persistent, .recent_custom => continue,
        }
    }
    return null;
}

/// Caller holds `shared_shader_mutex`.
fn pruneExpiredFailedShadersLocked(now: std.Io.Timestamp) void {
    var i: usize = 0;
    while (i < shared_shader_entries.items.len) {
        const entry = shared_shader_entries.items[i];
        const expired = switch (entry.retention) {
            .failed_custom => |retry_after| entry.references == 0 and
                now.toNanoseconds() >= retry_after.toNanoseconds(),
            .persistent, .recent_custom => false,
        };
        if (!expired) {
            i += 1;
            continue;
        }

        _ = shared_shader_entries.orderedRemove(i);
        destroySharedLocked(entry);
    }
}

fn shadersFromShared(entry: *SharedShaders) Shaders {
    return .{
        .library = entry.library,
        .pipelines = entry.pipelines,
        .post_pipelines = entry.post_pipelines,
        .shared = entry,
    };
}

fn releaseShared(entry: *SharedShaders) void {
    shared_shader_mutex.lockUncancelable(global.io());
    defer shared_shader_mutex.unlock(global.io());

    std.debug.assert(entry.references > 0);
    entry.references -= 1;
    if (entry.references > 0) return;

    switch (entry.retention) {
        .persistent => {},
        .recent_custom => {
            trimIdleShadersLocked(
                entry,
                .recent_custom,
                retained_idle_custom_shader_entries,
            );
        },
        .failed_custom => |retry_after| {
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            if (now.toNanoseconds() >= retry_after.toNanoseconds()) {
                removeSharedLocked(entry);
                return;
            }
            trimIdleShadersLocked(
                entry,
                .failed_custom,
                retained_idle_failed_shader_entries,
            );
        },
    }
}

fn clonePostShaders(
    post_shaders: []const [:0]const u8,
) ![]const [:0]const u8 {
    if (post_shaders.len == 0) return &.{};

    const result = try shared_shader_allocator.alloc(
        [:0]const u8,
        post_shaders.len,
    );
    errdefer shared_shader_allocator.free(result);

    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |source| {
        shared_shader_allocator.free(source);
    };

    for (post_shaders, 0..) |source, i| {
        result[i] = try shared_shader_allocator.dupeZ(u8, source);
        initialized += 1;
    }
    return result;
}

fn freePostShaders(post_shaders: []const [:0]const u8) void {
    if (post_shaders.len == 0) return;
    for (post_shaders) |source| shared_shader_allocator.free(source);
    shared_shader_allocator.free(post_shaders);
}

fn hasBoundedRetention(
    entry: *SharedShaders,
    retention: BoundedRetention,
) bool {
    if (entry.references != 0) return false;
    return switch (entry.retention) {
        .persistent => false,
        .recent_custom => retention == .recent_custom,
        .failed_custom => retention == .failed_custom,
    };
}

/// Caller holds `shared_shader_mutex`.
fn trimIdleShadersLocked(
    preserve: *SharedShaders,
    retention: BoundedRetention,
    maximum_entries: usize,
) void {
    var idle_count: usize = 0;
    for (shared_shader_entries.items) |entry| {
        if (hasBoundedRetention(entry, retention)) idle_count += 1;
    }
    if (idle_count <= maximum_entries) return;

    var i: usize = 0;
    while (i < shared_shader_entries.items.len and
        idle_count > maximum_entries)
    {
        const entry = shared_shader_entries.items[i];
        if (entry != preserve and hasBoundedRetention(entry, retention)) {
            _ = shared_shader_entries.orderedRemove(i);
            destroySharedLocked(entry);
            idle_count -= 1;
            continue;
        }
        i += 1;
    }
}

/// Caller holds `shared_shader_mutex`.
fn removeSharedLocked(target: *SharedShaders) void {
    for (shared_shader_entries.items, 0..) |entry, i| {
        if (entry != target) continue;
        _ = shared_shader_entries.orderedRemove(i);
        destroySharedLocked(entry);
        return;
    }
    log.warn("shared shader entry missing from cache during removal", .{});
    return;
}

/// Caller holds `shared_shader_mutex`.
fn destroySharedLocked(entry: *SharedShaders) void {
    var owned: Shaders = .{
        .library = entry.library,
        .pipelines = entry.pipelines,
        .post_pipelines = entry.post_pipelines,
    };
    owned.deinit(shared_shader_allocator);
    freePostShaders(entry.key.post_shaders);
    entry.device.release();
    shared_shader_allocator.destroy(entry);
}

fn clearSharedCacheForTesting() void {
    shared_shader_mutex.lockUncancelable(global.io());
    defer shared_shader_mutex.unlock(global.io());

    for (shared_shader_entries.items) |entry| {
        std.debug.assert(entry.references == 0);
        destroySharedLocked(entry);
    }
    shared_shader_entries.deinit(shared_shader_allocator);
    shared_shader_entries = .empty;
}

/// The uniforms that are passed to our shaders.
pub const Uniforms = extern struct {
    // Note: all of the explicit alignments are copied from the
    // MSL developer reference just so that we can be sure that we got
    // it all exactly right.

    /// The projection matrix for turning world coordinates to normalized.
    /// This is calculated based on the size of the screen.
    projection_matrix: math.Mat align(16),

    /// Size of the screen (render target) in pixels.
    screen_size: [2]f32 align(8),

    /// Size of a single cell in pixels, unscaled.
    cell_size: [2]f32 align(8),

    /// Size of the grid in columns and rows.
    grid_size: [2]u16 align(4),

    /// The padding around the terminal grid in pixels. In order:
    /// top, right, bottom, left.
    grid_padding: [4]f32 align(16),

    /// Bit mask defining which directions to
    /// extend cell colors in to the padding.
    /// Order, LSB first: left, right, up, down
    padding_extend: PaddingExtend align(1),

    /// The minimum contrast ratio for text. The contrast ratio is calculated
    /// according to the WCAG 2.0 spec.
    min_contrast: f32 align(4),

    /// The cursor position and color.
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),

    /// The background color for the whole surface.
    bg_color: [4]u8 align(4),

    /// Various booleans.
    ///
    /// TODO: Maybe put these in a packed struct, like for OpenGL.
    bools: extern struct {
        /// Whether the cursor is 2 cells wide.
        cursor_wide: bool align(1),

        /// Indicates that colors provided to the shader are already in
        /// the P3 color space, so they don't need to be converted from
        /// sRGB.
        use_display_p3: bool align(1),

        /// Indicates that the color attachments for the shaders have
        /// an `*_srgb` pixel format, which means the shaders need to
        /// output linear RGB colors rather than gamma encoded colors,
        /// since blending will be performed in linear space and then
        /// Metal itself will re-encode the colors for storage.
        use_linear_blending: bool align(1),

        /// Enables a weight correction step that makes text rendered
        /// with linear alpha blending have a similar apparent weight
        /// (thickness) to gamma-incorrect blending.
        use_linear_correction: bool align(1) = false,
    },

    const PaddingExtend = packed struct(u8) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u4 = 0,
    };
};

test "standard shaders reuse pipeline state across surfaces and restores" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();

    {
        var active = try Shaders.init(
            testing.allocator,
            device,
            &.{},
            .bgra8unorm,
        );
        defer active.deinit(testing.allocator);

        {
            var hidden = try Shaders.init(
                testing.allocator,
                device,
                &.{},
                .bgra8unorm,
            );
            defer hidden.deinit(testing.allocator);

            try testing.expectEqual(
                active.pipelines.bg_color.state.value,
                hidden.pipelines.bg_color.state.value,
            );
        }

        {
            var restored = try Shaders.init(
                testing.allocator,
                device,
                &.{},
                .bgra8unorm,
            );
            defer restored.deinit(testing.allocator);

            try testing.expectEqual(
                active.pipelines.bg_color.state.value,
                restored.pipelines.bg_color.state.value,
            );
        }
    }

    clearSharedCacheForTesting();
    shared_shader_mutex.lockUncancelable(global.io());
    defer shared_shader_mutex.unlock(global.io());
    try testing.expectEqual(@as(usize, 0), shared_shader_entries.items.len);
}

test "concurrent standard shader initialization compiles once" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();

    const Context = struct {
        start: *std.Io.Event,
        device: objc.Object,
        shaders: ?Shaders = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            self.start.waitUncancelable(global.io());
            self.shaders = Shaders.init(
                std.heap.c_allocator,
                self.device,
                &.{},
                .bgra8unorm_srgb,
            ) catch |err| {
                self.err = err;
                return;
            };
        }
    };

    const thread_count = 5;
    var start: std.Io.Event = .unset;
    var contexts: [thread_count]Context = undefined;
    var threads: [thread_count]std.Thread = undefined;

    shared_shader_build_count.store(0, .monotonic);
    for (&contexts, &threads) |*context, *thread| {
        context.* = .{
            .start = &start,
            .device = device,
        };
        thread.* = try std.Thread.spawn(.{}, Context.run, .{context});
    }

    start.set(global.io());
    for (&threads) |*thread| thread.join();

    defer {
        for (&contexts) |*context| {
            if (context.shaders) |*value| {
                value.deinit(std.heap.c_allocator);
            }
        }
        clearSharedCacheForTesting();
    }

    for (&contexts) |*context| {
        if (context.err) |err| return err;
        try testing.expect(context.shaders != null);
        try testing.expectEqual(
            contexts[0].shaders.?.pipelines.bg_color.state.value,
            context.shaders.?.pipelines.bg_color.state.value,
        );
    }

    try testing.expectEqual(
        @as(usize, 1),
        shared_shader_build_count.load(.monotonic),
    );
}

test "standard shader cache survives a renderer handoff gap" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();

    shared_shader_build_count.store(0, .monotonic);

    var hidden = try Shaders.init(
        testing.allocator,
        device,
        &.{},
        .bgra8unorm,
    );
    hidden.deinit(testing.allocator);

    var restored = try Shaders.init(
        testing.allocator,
        device,
        &.{},
        .bgra8unorm,
    );
    restored.deinit(testing.allocator);
    defer clearSharedCacheForTesting();

    try testing.expectEqual(
        @as(usize, 1),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader cache survives a renderer handoff gap" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const custom_shader: [:0]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 main0(float4 position [[position]]) {
        \\    return float4(position.x, position.y, 0.0, 1.0);
        \\}
    ;

    var hidden = try Shaders.init(
        testing.allocator,
        device,
        &.{custom_shader},
        .bgra8unorm,
    );
    try testing.expect(hidden.shared != null);
    try testing.expectEqual(@as(usize, 1), hidden.post_pipelines.len);
    const standard_pipeline = hidden.pipelines.bg_color.state.value;
    const post_pipeline = hidden.post_pipelines[0].state.value;
    hidden.deinit(testing.allocator);

    var restored = try Shaders.init(
        testing.allocator,
        device,
        &.{custom_shader},
        .bgra8unorm,
    );
    defer restored.deinit(testing.allocator);

    try testing.expect(restored.shared != null);
    try testing.expectEqual(
        standard_pipeline,
        restored.pipelines.bg_color.state.value,
    );
    try testing.expectEqual(
        post_pipeline,
        restored.post_pipelines[0].state.value,
    );
}

test "custom shader cache bounds idle configurations" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const first_source: [:0]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 main0(float4 position [[position]]) {
        \\    return float4(position.x, 0.0, 0.0, 1.0);
        \\}
    ;
    const second_source: [:0]const u8 =
        \\#include <metal_stdlib>
        \\using namespace metal;
        \\fragment float4 main0(float4 position [[position]]) {
        \\    return float4(0.0, position.y, 0.0, 1.0);
        \\}
    ;

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{first_source},
        .bgra8unorm,
    );
    first.deinit(testing.allocator);

    var second = try Shaders.init(
        testing.allocator,
        device,
        &.{second_source},
        .bgra8unorm,
    );
    second.deinit(testing.allocator);

    {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        var idle_custom_entries: usize = 0;
        var retained_latest = false;
        for (shared_shader_entries.items) |entry| {
            if (entry.references != 0) continue;
            switch (entry.retention) {
                .recent_custom => {
                    idle_custom_entries += 1;
                    retained_latest = retained_latest or
                        entry.key.eql(.{
                            .device = @intFromPtr(device.value),
                            .pixel_format = .bgra8unorm,
                            .post_shaders = &.{second_source},
                        });
                },
                .persistent, .failed_custom => {},
            }
        }

        try testing.expectEqual(
            @as(usize, retained_idle_custom_shader_entries),
            idle_custom_entries,
        );
        try testing.expect(retained_latest);
    }
}

test "custom shader compiler fallback retries after backoff expires" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    shared_shader_build_count.store(0, .monotonic);

    var fallback = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    try testing.expectEqual(@as(usize, 0), fallback.post_pipelines.len);
    fallback.deinit(testing.allocator);

    {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        var found = false;
        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(.{
                .device = @intFromPtr(device.value),
                .pixel_format = .bgra8unorm,
                .post_shaders = &.{invalid_source},
            })) continue;

            switch (entry.retention) {
                .failed_custom => {
                    entry.retention = .{
                        .failed_custom = .now(global.io(), .awake),
                    };
                    found = true;
                },
                .persistent, .recent_custom => {},
            }
        }
        try testing.expect(found);
    }

    var retry = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer retry.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), retry.post_pipelines.len);
    try testing.expectEqual(
        @as(usize, 2),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler fallback backs off across renderer restores" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    shared_shader_build_count.store(0, .monotonic);

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    try testing.expectEqual(@as(usize, 0), first.post_pipelines.len);
    first.deinit(testing.allocator);

    var restored = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), restored.post_pipelines.len);

    try testing.expectEqual(
        @as(usize, 1),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler backoff begins when compilation fails" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    shared_shader_build_count.store(0, .monotonic);
    const compile_started_at: std.Io.Timestamp = .now(global.io(), .awake);

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer first.deinit(testing.allocator);

    // Retry policy belongs to the compile attempt, not renderer lifetime.
    {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        var found = false;
        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(.{
                .device = @intFromPtr(device.value),
                .pixel_format = .bgra8unorm,
                .post_shaders = &.{invalid_source},
            })) continue;

            switch (entry.retention) {
                .failed_custom => |retry_after| {
                    try testing.expect(
                        retry_after.toNanoseconds() >
                            compile_started_at.toNanoseconds(),
                    );
                    found = true;
                },
                .persistent, .recent_custom => {},
            }
        }
        try testing.expect(found);
    }

    const retry_after_before: ?std.Io.Timestamp = before: {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(.{
                .device = @intFromPtr(device.value),
                .pixel_format = .bgra8unorm,
                .post_shaders = &.{invalid_source},
            })) continue;

            break :before switch (entry.retention) {
                .failed_custom => |retry_after| retry_after,
                .persistent, .recent_custom => null,
            };
        }
        break :before null;
    };
    try testing.expect(retry_after_before != null);

    first.deinit(testing.allocator);

    // Releasing the renderer must not move the compile-attempt deadline.
    {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        var found = false;
        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(.{
                .device = @intFromPtr(device.value),
                .pixel_format = .bgra8unorm,
                .post_shaders = &.{invalid_source},
            })) continue;

            switch (entry.retention) {
                .failed_custom => |retry_after| {
                    try testing.expectEqualDeep(
                        retry_after_before.?,
                        retry_after,
                    );
                    found = true;
                },
                .persistent, .recent_custom => {},
            }
        }
        try testing.expect(found);
    }

    var restored = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer restored.deinit(testing.allocator);

    try testing.expectEqual(
        @as(usize, 1),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler backoff deadline does not slide on reuse" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    const key: SharedShadersKey = .{
        .device = @intFromPtr(device.value),
        .pixel_format = .bgra8unorm,
        .post_shaders = &.{invalid_source},
    };

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    first.deinit(testing.allocator);

    var restored = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    const retry_after_before: ?std.Io.Timestamp = before: {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(key)) continue;
            break :before switch (entry.retention) {
                .failed_custom => |retry_after| retry_after,
                .persistent, .recent_custom => null,
            };
        }
        break :before null;
    };
    try testing.expect(retry_after_before != null);

    restored.deinit(testing.allocator);

    const retry_after_after: ?std.Io.Timestamp = after: {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(key)) continue;
            break :after switch (entry.retention) {
                .failed_custom => |retry_after| retry_after,
                .persistent, .recent_custom => null,
            };
        }
        break :after null;
    };
    try testing.expectEqualDeep(retry_after_before, retry_after_after);
}

test "edited custom shader retries during compiler failure backoff" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const first_source: [:0]const u8 = "not valid metal first";
    const edited_source: [:0]const u8 = "not valid metal edited";
    shared_shader_build_count.store(0, .monotonic);

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{first_source},
        .bgra8unorm,
    );
    first.deinit(testing.allocator);

    var edited = try Shaders.init(
        testing.allocator,
        device,
        &.{edited_source},
        .bgra8unorm,
    );
    defer edited.deinit(testing.allocator);

    try testing.expectEqual(
        @as(usize, 2),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler fallback backs off while in use" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    shared_shader_build_count.store(0, .monotonic);

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer first.deinit(testing.allocator);

    var retry = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer retry.deinit(testing.allocator);

    try testing.expectEqual(
        @as(usize, 1),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler fallback backs off with live and idle consumers" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    shared_shader_build_count.store(0, .monotonic);

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    var second = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer second.deinit(testing.allocator);
    first.deinit(testing.allocator);

    var third = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer third.deinit(testing.allocator);

    try testing.expectEqual(
        @as(usize, 1),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler retries once after expiry with live fallback" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const invalid_source: [:0]const u8 = "not valid metal";
    const key: SharedShadersKey = .{
        .device = @intFromPtr(device.value),
        .pixel_format = .bgra8unorm,
        .post_shaders = &.{invalid_source},
    };
    shared_shader_build_count.store(0, .monotonic);

    var first = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer first.deinit(testing.allocator);

    {
        shared_shader_mutex.lockUncancelable(global.io());
        defer shared_shader_mutex.unlock(global.io());

        var found = false;
        for (shared_shader_entries.items) |entry| {
            if (!entry.key.eql(key)) continue;
            switch (entry.retention) {
                .failed_custom => {
                    entry.retention = .{
                        .failed_custom = .now(global.io(), .awake),
                    };
                    found = true;
                },
                .persistent, .recent_custom => {},
            }
        }
        try testing.expect(found);
    }

    var retry = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer retry.deinit(testing.allocator);

    var coalesced = try Shaders.init(
        testing.allocator,
        device,
        &.{invalid_source},
        .bgra8unorm,
    );
    defer coalesced.deinit(testing.allocator);

    try testing.expectEqual(
        @as(usize, 2),
        shared_shader_build_count.load(.monotonic),
    );
}

test "custom shader compiler fallback bounds idle configurations" {
    const testing = std.testing;
    const device_ptr = mtl.MTLCreateSystemDefaultDevice() orelse {
        return error.SkipZigTest;
    };
    const device = objc.Object.fromId(device_ptr);
    defer device.release();
    defer clearSharedCacheForTesting();

    const sources = [_][:0]const u8{
        "not valid metal first",
        "not valid metal second",
    };

    for (sources) |source| {
        var fallback = try Shaders.init(
            testing.allocator,
            device,
            &.{source},
            .bgra8unorm,
        );
        fallback.deinit(testing.allocator);
    }

    shared_shader_mutex.lockUncancelable(global.io());
    defer shared_shader_mutex.unlock(global.io());

    var idle_failed_entries: usize = 0;
    var retained_latest = false;
    for (shared_shader_entries.items) |entry| {
        if (entry.references != 0) continue;
        switch (entry.retention) {
            .failed_custom => {
                idle_failed_entries += 1;
                retained_latest = retained_latest or
                    entry.key.eql(.{
                        .device = @intFromPtr(device.value),
                        .pixel_format = .bgra8unorm,
                        .post_shaders = &.{sources[1]},
                    });
            },
            .persistent, .recent_custom => {},
        }
    }

    try testing.expectEqual(
        @as(usize, retained_idle_failed_shader_entries),
        idle_failed_entries,
    );
    try testing.expect(retained_latest);
}

/// This is a single parameter for the terminal cell shader.
pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };

    test {
        // Minimizing the size of this struct is important,
        // so we test it in order to be aware of any changes.
        try std.testing.expectEqual(32, @sizeOf(CellText));
    }
};

/// This is a single parameter for the cell bg shader.
pub const CellBg = [4]u8;

/// Single parameter for the image shader. See shader for field details.
pub const Image = extern struct {
    grid_pos: [2]f32,
    cell_offset: [2]f32,
    source_rect: [4]f32,
    dest_size: [2]f32,
};

/// Single parameter for the bg image shader.
pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0,
            tc = 1,
            tr = 2,
            ml = 3,
            mc = 4,
            mr = 5,
            bl = 6,
            bc = 7,
            br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0,
            cover = 1,
            stretch = 2,
            none = 3,
        };
    };
};

/// Initialize the MTLLibrary. A MTLLibrary is a collection of shaders.
fn initLibrary(device: objc.Object) !objc.Object {
    const start: std.Io.Timestamp = .now(global.io(), .awake);

    const data = try macos.dispatch.Data.create(
        @embedFile("ghostty_metallib"),
        macos.dispatch.queue.getMain(),
        macos.dispatch.Data.DESTRUCTOR_DEFAULT,
    );
    defer data.release();

    var err: ?*anyopaque = null;
    const library = device.msgSend(
        objc.Object,
        objc.sel("newLibraryWithData:error:"),
        .{
            data,
            &err,
        },
    );
    try checkError(err, .err);

    log.debug("shader library loaded time={}us", .{start.untilNow(global.io(), .awake).toMicroseconds()});

    return library;
}

/// Initialize our custom shader pipelines.
///
/// The shaders argument is a set of shader source code, not file paths.
fn initPostPipelines(
    alloc: Allocator,
    device: objc.Object,
    library: objc.Object,
    shaders: []const [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) ![]const Pipeline {
    // If we have no shaders, do nothing.
    if (shaders.len == 0) return &.{};

    // Keeps track of how many shaders we successfully wrote.
    var i: usize = 0;

    // Initialize our result set. If any error happens, we undo everything.
    var pipelines = try alloc.alloc(Pipeline, shaders.len);
    errdefer {
        for (pipelines[0..i]) |pipeline| {
            pipeline.deinit();
        }
        alloc.free(pipelines);
    }

    // Build each shader. Note we don't use "0.." to build our index
    // because we need to keep track of our length to clean up above.
    for (shaders) |source| {
        pipelines[i] = try initPostPipeline(
            device,
            library,
            source,
            pixel_format,
        );
        i += 1;
    }

    return pipelines;
}

/// Initialize a single custom shader pipeline from shader source.
fn initPostPipeline(
    device: objc.Object,
    library: objc.Object,
    data: [:0]const u8,
    pixel_format: mtl.MTLPixelFormat,
) !Pipeline {
    // Create our library which has the shader source
    const post_library = library: {
        const source = try macos.foundation.String.createWithBytes(
            data,
            .utf8,
            false,
        );
        defer source.release();

        var err: ?*anyopaque = null;
        const post_library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithSource:options:error:"),
            .{ source, @as(?*anyopaque, null), &err },
        );
        // Invalid user post-shader source is recoverable: Ghostty falls back
        // to the standard renderer and lets the shared cache pace retries.
        try checkError(err, .warn);
        errdefer post_library.msgSend(void, objc.sel("release"), .{});

        break :library post_library;
    };
    defer post_library.msgSend(void, objc.sel("release"), .{});

    return try Pipeline.init(null, .{
        .device = device,
        .vertex_fn = "full_screen_vertex",
        .fragment_fn = "main0",
        .vertex_library = library,
        .fragment_library = post_library,
        .attachments = &.{
            .{
                .pixel_format = pixel_format,
                .blending_enabled = false,
            },
        },
    });
}

fn checkError(err_: ?*anyopaque, comptime level: std.log.Level) !void {
    const nserr = objc.Object.fromId(err_ orelse return);
    const str = @as(
        *macos.foundation.String,
        @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
    );

    switch (level) {
        .err => log.err("metal error={s}", .{str.cstringPtr(.ascii).?}),
        .warn => log.warn("metal error={s}", .{str.cstringPtr(.ascii).?}),
        else => @compileError("Metal failures must log as errors or warnings"),
    }
    return error.MetalFailed;
}
