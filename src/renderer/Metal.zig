//! Graphics API wrapper for Metal.
pub const Metal = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Metal);
const shadertoy = @import("shadertoy.zig");

const mtl = @import("metal/api.zig");
const IOSurfaceLayer = @import("metal/IOSurfaceLayer.zig");
const CompletionLifetime = @import("metal/CompletionLifetime.zig");

pub const GraphicsAPI = Metal;
pub const Target = @import("metal/Target.zig");
pub const Frame = @import("metal/Frame.zig");
pub const RenderPass = @import("metal/RenderPass.zig");
pub const Pipeline = @import("metal/Pipeline.zig");
const bufferpkg = @import("metal/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("metal/Sampler.zig");
pub const Texture = @import("metal/Texture.zig");
pub const shaders = @import("metal/shaders.zig");
pub const RendererCompletionLifetime = CompletionLifetime.Lifetime(Renderer);
const RendererCompletionGeneration = CompletionLifetime.Generation(Renderer);
pub const PreparedPresentation = IOSurfaceLayer.PreparedSurfaceUpdate;

pub const custom_shader_target: shadertoy.Target = .msl;
// The fragCoord for Metal shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Triple buffering.
pub const swap_chain_count = 3;

const log = std.log.scoped(.metal);

layer: IOSurfaceLayer,

/// MTLDevice
device: objc.Object,
/// MTLCommandQueue
queue: objc.Object,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The default storage mode to use for resources created with our device.
///
/// This is based on whether the device is a discrete GPU or not, since
/// discrete GPUs do not have unified memory and therefore do not support
/// the "shared" storage mode, instead we have to use the "managed" mode.
default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32,

/// We start an AutoreleasePool before `drawFrame` and end it afterwards.
autorelease_pool: ?*objc.AutoreleasePool = null,

/// Owns the ref-counted gate for the current swap-chain generation.
completion_generation: RendererCompletionGeneration,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Metal {
    comptime switch (builtin.os.tag) {
        .macos, .ios => {},
        else => @compileError("unsupported platform for Metal"),
    };

    var completion_generation = try RendererCompletionGeneration.init(alloc);
    errdefer completion_generation.deinit();

    // Choose our MTLDevice and create a MTLCommandQueue for that device.
    const device = try chooseDevice();
    errdefer device.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    errdefer queue.release();

    // Grab metadata about the device.
    const default_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        // manage mode is not supported by iOS
        .ios => .shared,
        else => if (device.getProperty(bool, "hasUnifiedMemory")) .shared else .managed,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );

    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the metadata about our underlying view that we'll be rendering to.
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.embedded => .{
            .scaleFactor = @floatCast(opts.rt_surface.content_scale.x),
            .view = switch (opts.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },

        else => @compileError("unsupported apprt for metal"),
    };

    // Create an IOSurfaceLayer which we can assign to the view to make
    // it in to a "layer-hosting view", so that we can manually control
    // the layer contents.
    var layer = try IOSurfaceLayer.init();
    errdefer layer.release();

    // Add our layer to the view.
    //
    // On macOS we do this by making the view "layer-hosting"
    // by assigning it to the view's `layer` property BEFORE
    // setting `wantsLayer` to `true`.
    //
    // On iOS, views are always layer-backed, and `layer`
    // is readonly, so instead we add it as a sublayer.
    switch (comptime builtin.os.tag) {
        .macos => {
            info.view.setProperty("layer", layer.layer.value);
            info.view.setProperty("wantsLayer", true);
        },

        .ios => {
            const view_layer = objc.Object.fromId(info.view.getProperty(?*anyopaque, "layer"));
            view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value});
        },

        else => @compileError("unsupported target for Metal"),
    }

    // Ensure that if our layer is oversized it
    // does not overflow the bounds of the view.
    info.view.setProperty("clipsToBounds", true);

    // Ensure that our layer has a content scale set to
    // match the scale factor of the window. This avoids
    // magnification issues leading to blurry rendering.
    layer.layer.setProperty("contentsScale", info.scaleFactor);

    // This makes it so that our display callback will actually be called.
    layer.layer.setProperty("needsDisplayOnBoundsChange", true);

    return .{
        .layer = layer,
        .device = device,
        .queue = queue,
        .blending = opts.config.blending,
        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
        .completion_generation = completion_generation,
    };
}

pub fn deinit(self: *Metal) void {
    // Init failures can deinitialize Metal without the generic renderer's
    // prepare/finish hooks. Invalidation is idempotent.
    self.completion_generation.deinit();
    self.queue.release();
    self.device.release();
    self.layer.release();
}

pub fn prepareDeinit(self: *Metal) void {
    switch (comptime builtin.os.tag) {
        .ios => {
            const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
            self.layer.detachFromHostIfDisplayCallbackOwned(
                @ptrCast(&displayCallback),
                @ptrCast(renderer),
            );
        },

        else => self.layer.invalidateSurfaceUpdates(),
    }
}

/// Called after the swap chain had a bounded opportunity to drain. From this
/// point, a late GPU callback must not touch renderer or target state.
pub fn finishFrameGeneration(self: *Metal) void {
    self.completion_generation.finish();
}

/// Install a distinct gate before replacement swap-chain frames can be used.
pub fn startFrameGeneration(self: *Metal) !void {
    const renderer: *Renderer = @alignCast(@fieldParentPtr("api", self));
    try self.completion_generation.restart(renderer);
}

pub fn loopEnter(self: *Metal) void {
    const renderer: *Renderer = @alignCast(@fieldParentPtr("api", self));
    self.completion_generation.bind(renderer);
    self.layer.setDisplayCallback(
        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}

fn displayCallback(renderer: *Renderer) align(8) void {
    renderer.drawFrame(true) catch |err| {
        log.warn("Error drawing frame in display callback, err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now we use this to start an AutoreleasePool.
pub fn drawFrameStart(self: *Metal) void {
    assert(self.autorelease_pool == null);
    self.autorelease_pool = .init();
}

/// Actions taken after `drawFrame` is done.
///
/// Right now we use this to end our AutoreleasePool.
pub fn drawFrameEnd(self: *Metal) void {
    assert(self.autorelease_pool != null);
    self.autorelease_pool.?.deinit();
    self.autorelease_pool = null;
}

pub fn initShaders(
    self: *const Metal,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.device,
        custom_shaders,
        // Using an `*_srgb` pixel format makes Metal gamma encode
        // the pixels written to it *after* blending, which means
        // we get linear alpha blending rather than gamma-incorrect
        // blending.
        if (self.blending.isLinear())
            mtl.MTLPixelFormat.bgra8unorm_srgb
        else
            mtl.MTLPixelFormat.bgra8unorm,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Metal) !struct { width: u32, height: u32 } {
    const bounds = self.layer.layer.getProperty(graphics.Rect, "bounds");
    const scale = self.layer.layer.getProperty(f64, "contentsScale");

    // We need to clamp our runtime surface size to the maximum
    // possible texture size since we can't create a screen buffer (texture)
    // larger than that.
    return .{
        .width = @min(
            @as(u32, @intFromFloat(bounds.size.width * scale)),
            self.max_texture_size,
        ),
        .height = @min(
            @as(u32, @intFromFloat(bounds.size.height * scale)),
            self.max_texture_size,
        ),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Metal, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .storage_mode = self.default_storage_mode,
        .width = width,
        .height = height,
    });
}

/// Present the provided target.
pub inline fn present(self: *Metal, target: Target, sync: bool) !void {
    if (sync) {
        self.layer.setSurfaceSync(target.surface);
    } else {
        try self.layer.setSurface(target.surface);
    }
}

/// Replace an exclusively owned swap-chain target and return the rendered
/// target as an immutable presentation snapshot. The replacement copies the
/// target's creation parameters, so this GPU callback never races mutable
/// renderer configuration.
pub fn detachPresentationTarget(self: *Metal, target: *Target) !Target {
    const replacement = try target.replacement(self.device);
    const frozen = target.*;
    target.* = replacement;
    return frozen;
}

/// Retain a frozen target's layer update before its replacement-backed frame
/// is returned to the swap chain.
pub fn preparePresentation(
    self: *Metal,
    target: Target,
    presentation: rendererpkg.FramePresentation,
) PreparedPresentation {
    return self.layer.prepareSurfaceWithPresentation(
        target.surface,
        presentation,
    );
}

/// Present one explicitly tokened frame. iOS acknowledges only after the
/// exact IOSurface passes the main-thread layer size guard and is assigned.
pub inline fn presentWithPresentation(
    self: *Metal,
    target: Target,
    sync: bool,
    presentation: rendererpkg.FramePresentation,
) !void {
    // A tokened render may be submitted from any embedder-owned queue. Layer
    // assignment and acknowledgement must therefore use the main-thread path
    // even when the GPU frame itself completed synchronously.
    _ = sync;
    try self.layer.setSurfaceWithPresentation(target.surface, presentation);
}

/// Present the last presented target again. (noop for Metal)
pub inline fn presentLastTarget(self: *Metal) !void {
    _ = self;
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: Metal) bufferpkg.Options {
    return .{
        .device = self.device,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.default_storage_mode,
        },
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Metal) Texture.Options {
    return .{
        .device = self.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.default_storage_mode,
        },
        .usage = .{
            // textureOptions is currently only used for custom shaders,
            // which require both the shader read (for when multiple shaders
            // are chained) and render target (for the final output) usage.
            // Disabling either of these will lead to metal validation
            // errors in Xcode.
            .shader_read = true,
            .render_target = true,
        },
    };
}

pub inline fn samplerOptions(self: Metal) Sampler.Options {
    return .{
        .device = self.device,

        // These parameters match Shadertoy behaviors.
        .min_filter = .linear,
        .mag_filter = .linear,
        .s_address_mode = .clamp_to_edge,
        .t_address_mode = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(
        self: ImageTextureFormat,
        srgb: bool,
    ) mtl.MTLPixelFormat {
        return switch (self) {
            .gray => if (srgb) .r8unorm_srgb else .r8unorm,
            .rgba => if (srgb) .rgba8unorm_srgb else .rgba8unorm,
            .bgra => if (srgb) .bgra8unorm_srgb else .bgra8unorm,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Metal,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device,
        .pixel_format = format.toPixelFormat(srgb),
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.default_storage_mode,
        },
        .usage = .{
            // We only need to read from this texture from a shader.
            .shader_read = true,
        },
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Metal,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .grayscale => .r8unorm,
        .bgra => .bgra8unorm_srgb,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    return try Texture.init(
        .{
            .device = self.device,
            .pixel_format = pixel_format,
            .resource_options = .{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = self.default_storage_mode,
            },
            .usage = .{
                // We only need to read from this texture from a shader.
                .shader_read = true,
            },
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *Metal,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    // `loopEnter` normally binds first, but an embedder-owned synchronous
    // render can race renderer-thread startup. Binding is idempotent.
    self.completion_generation.bind(renderer);
    return try Frame.begin(.{
        .queue = self.queue,
        .completion_lifetime = self.completion_generation.lifetime(),
    }, target, null);
}

/// Begin a frame whose exact CALayer assignment must be acknowledged to the
/// embedder after GPU completion.
pub inline fn beginFrameWithPresentation(
    self: *Metal,
    renderer: *Renderer,
    target: *Target,
    presentation: rendererpkg.FramePresentation,
) !Frame {
    self.completion_generation.bind(renderer);
    var gated = presentation;
    gated.delivery_gate = &waitForDrawCriticalSection;
    gated.delivery_gate_userdata = renderer;
    return try Frame.begin(.{
        .queue = self.queue,
        .completion_lifetime = self.completion_generation.lifetime(),
    }, target, gated);
}

fn waitForDrawCriticalSection(userdata: ?*anyopaque) callconv(.c) void {
    const renderer: *Renderer = @ptrCast(@alignCast(userdata.?));
    renderer.draw_mutex.lock();
    renderer.draw_mutex.unlock();
}

fn chooseDevice() error{NoMetalDevice}!objc.Object {
    var chosen_device: ?objc.Object = null;

    switch (comptime builtin.os.tag) {
        .macos => {
            const devices = objc.Object.fromId(mtl.MTLCopyAllDevices());
            defer devices.release();

            var iter = devices.iterate();
            while (iter.next()) |device| {
                // We want a GPU that’s connected to a display.
                if (device.getProperty(bool, "isHeadless")) continue;
                chosen_device = device;
                // If the user has an eGPU plugged in, they probably want
                // to use it. Otherwise, integrated GPUs are better for
                // battery life and thermals.
                if (device.getProperty(bool, "isRemovable") or
                    device.getProperty(bool, "isLowPower")) break;
            }
        },
        .ios => {
            chosen_device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
        },
        else => @compileError("unsupported target for Metal"),
    }

    const device = chosen_device orelse return error.NoMetalDevice;
    return device.retain();
}

/// Determines the maximum 2D texture size supported by the device.
/// We need to clamp our frame size to this if it's larger.
fn queryMaxTextureSize(device: objc.Object) u32 {
    // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple10},
    )) return 32768;

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple3},
    )) return 16384;

    return 8192;
}

test "metal completion lifetime rejects late target access and retains itself" {
    const testing = std.testing;
    const Context = struct {
        calls: usize = 0,
    };
    const Lifetime = CompletionLifetime.Lifetime(Context);

    var context: Context = .{};
    const lifetime = try Lifetime.create(testing.allocator);
    lifetime.bind(&context);

    {
        var live = lifetime.acquire().?;
        defer live.deinit();
        live.context.calls += 1;
    }
    try testing.expectEqual(@as(usize, 1), context.calls);

    // Model the copied MTL completion block retaining the lifetime after the
    // renderer-owned reference is released during API teardown.
    lifetime.retain();
    lifetime.invalidate();
    lifetime.release();
    defer lifetime.release();

    // A stale target is intentionally poisonous. Invalidated completion work
    // must reject the lease before it can dereference target-owned state.
    const stale_target: *usize = @ptrFromInt(@alignOf(usize));
    var touched_target = false;
    if (lifetime.acquire()) |live_value| {
        var live = live_value;
        defer live.deinit();
        stale_target.* = 1;
        touched_target = true;
    }
    try testing.expect(!touched_target);
}

test "metal completion invalidation waits for an active callback lease" {
    const testing = std.testing;
    const Context = struct {};
    const Lifetime = CompletionLifetime.Lifetime(Context);
    const State = struct {
        lifetime: *Lifetime,
        callback_entered: *std.Thread.Semaphore,
        callback_can_exit: *std.Thread.Semaphore,
        invalidation_started: *std.Thread.Semaphore,
        invalidation_done: *std.atomic.Value(bool),

        fn callback(self: *@This()) void {
            var live = self.lifetime.acquire().?;
            defer live.deinit();
            self.callback_entered.post();
            self.callback_can_exit.wait();
        }

        fn invalidate(self: *@This()) void {
            self.invalidation_started.post();
            self.lifetime.invalidate();
            self.invalidation_done.store(true, .seq_cst);
        }
    };

    var context: Context = .{};
    const lifetime = try Lifetime.create(testing.allocator);
    defer lifetime.release();
    lifetime.bind(&context);

    var callback_entered: std.Thread.Semaphore = .{};
    var callback_can_exit: std.Thread.Semaphore = .{};
    var invalidation_started: std.Thread.Semaphore = .{};
    var invalidation_done = std.atomic.Value(bool).init(false);
    var state: State = .{
        .lifetime = lifetime,
        .callback_entered = &callback_entered,
        .callback_can_exit = &callback_can_exit,
        .invalidation_started = &invalidation_started,
        .invalidation_done = &invalidation_done,
    };

    const callback_thread = try std.Thread.spawn(.{}, State.callback, .{&state});
    callback_entered.wait();
    const invalidation_thread = try std.Thread.spawn(.{}, State.invalidate, .{&state});
    invalidation_started.wait();

    // The callback owns the live lease and therefore the lifetime mutex.
    try testing.expect(!invalidation_done.load(.seq_cst));
    callback_can_exit.post();
    callback_thread.join();
    invalidation_thread.join();

    try testing.expect(invalidation_done.load(.seq_cst));
    try testing.expect(lifetime.acquire() == null);
}

test "metal completion generation rejects old callbacks after rotation" {
    const testing = std.testing;
    const Context = struct {
        generation: usize,
    };
    const Generation = CompletionLifetime.Generation(Context);

    var old_context: Context = .{ .generation = 1 };
    var new_context: Context = .{ .generation = 2 };
    var generation = try Generation.init(testing.allocator);
    defer generation.deinit();
    generation.bind(&old_context);

    // Model a copied old-generation MTL completion block.
    const old_lifetime = generation.lifetime();
    old_lifetime.retain();
    defer old_lifetime.release();

    generation.finish();
    try generation.restart(&new_context);
    try testing.expect(generation.lifetime() != old_lifetime);

    // The old command must be rejected even though the replacement generation
    // is live at the same renderer address.
    try testing.expect(old_lifetime.acquire() == null);
    var live = generation.lifetime().acquire().?;
    defer live.deinit();
    try testing.expectEqual(@as(usize, 2), live.context.generation);
}
