//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;
const FramePresentation = @import("../../renderer.zig").FramePresentation;

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;
var surface_updates_active_sentinel: usize = 0;

/// The underlying CALayer
layer: objc.Object,
/// Separately owned validity and size-generation state retained by queued
/// presentation blocks after the renderer releases the layer wrapper.
presentation_lifetime: *PresentationLifetime,

pub fn init() !IOSurfaceLayer {
    // The layer returned by `[CALayer layer]` is autoreleased, which means
    // that at the end of the current autorelease pool it will be deallocated
    // if it isn't retained, so we retain it here manually an extra time.
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();

    const presentation_lifetime = try PresentationLifetime.create();
    errdefer presentation_lifetime.release();

    // The layer gravity is set to top-left so that the contents aren't
    // stretched during resize operations before a new frame has been drawn.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setInstanceVariable("surface_updates_active", .{
        .value = @ptrCast(&surface_updates_active_sentinel),
    });

    return .{
        .layer = layer,
        .presentation_lifetime = presentation_lifetime,
    };
}

pub fn release(self: *IOSurfaceLayer) void {
    self.invalidateSurfaceUpdates();
    self.presentation_lifetime.release();
    self.layer.release();
}

/// Detaches this layer from its host if its display callback still belongs to
/// the provided owner. This must run synchronously with the main queue because
/// Core Animation may call `display` from a main-thread transaction while the
/// renderer is being destroyed on another thread.
pub fn detachFromHostIfDisplayCallbackOwned(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    // Close the presentation gate before the main-queue detach barrier. Any
    // already queued update then owns enough state to cancel without touching
    // detached UI or embedder callback userdata.
    self.presentation_lifetime.invalidate();
    var block = DetachFromHostBlock.init(.{
        .layer = self.layer.value,
        .display_cb = @ptrCast(@constCast(display_cb)),
        .display_ctx = display_ctx,
    }, &detachFromHostCallback);

    // We check if we're on the main thread and run the block directly if so.
    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        detachFromHostCallback(&block);
    } else {
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Makes sure to do so on the main thread to avoid visual artifacts.
pub inline fn setSurface(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    generation: u64,
) !void {
    return self.setSurface_(surface, generation, null);
}

/// Sets the layer contents and acknowledges the exact token after the size
/// guard succeeds. This callback runs on main in the same block as assignment.
pub inline fn setSurfaceWithPresentation(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    generation: u64,
    presentation: FramePresentation,
) !void {
    self.prepareSurfaceWithPresentation(
        surface,
        generation,
        presentation,
    ).dispatch();
}

/// A layer update whose Objective-C layer and IOSurface ownership no longer
/// depends on the renderer that prepared it. This lets the renderer recycle a
/// replacement-backed frame before the update can invoke external callbacks.
pub const PreparedSurfaceUpdate = struct {
    layer: objc.Object,
    surface: *IOSurface,
    presentation: FramePresentation,
    lifetime: *PresentationLifetime,
    generation: u64,

    /// Transfer this update to the main queue. Dispatch copies and retains the
    /// Objective-C layer capture; the callback consumes the IOSurface retain.
    pub fn dispatch(self: PreparedSurfaceUpdate) void {
        defer self.layer.release();

        var block = SetSurfaceBlock.init(.{
            .layer = self.layer.value,
            .surface = self.surface,
            .lifetime = self.lifetime,
            .generation = self.generation,
            .presentation_callback = self.presentation.callback,
            .presentation_userdata = self.presentation.userdata,
            .presentation_token = self.presentation.token,
            .presentation_delivery_gate = self.presentation.delivery_gate,
            .presentation_delivery_gate_userdata = self.presentation.delivery_gate_userdata,
        }, &setSurfaceCallback);
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
};

/// Retain everything a tokened main-thread layer update needs before its
/// rendered target is detached from the swap chain.
pub fn prepareSurfaceWithPresentation(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    generation: u64,
    presentation: FramePresentation,
) PreparedSurfaceUpdate {
    surface.retain();
    self.presentation_lifetime.retain();
    return .{
        .layer = self.layer.retain(),
        .surface = surface,
        .presentation = presentation,
        .lifetime = self.presentation_lifetime,
        .generation = generation,
    };
}

fn setSurface_(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    generation: u64,
    presentation: ?FramePresentation,
) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    self.presentation_lifetime.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .lifetime = self.presentation_lifetime,
        .generation = generation,
        .presentation_callback = if (presentation) |value| value.callback else null,
        .presentation_userdata = if (presentation) |value| value.userdata else null,
        .presentation_token = if (presentation) |value| value.token else 0,
        .presentation_delivery_gate = if (presentation) |value| value.delivery_gate else null,
        .presentation_delivery_gate_userdata = if (presentation) |value| value.delivery_gate_userdata else null,
    }, &setSurfaceCallback);

    // Ordinary updates retain their proven inline-on-main behavior. Tokened
    // updates always queue, even from main, so their external callback cannot
    // run inside the renderer draw mutex.
    const NSThread = objc.getClass("NSThread").?;
    if (surfaceUpdateRunsInline(
        NSThread.msgSend(bool, "isMainThread", .{}),
        presentation != null,
    )) {
        setSurfaceCallback(&block);
    } else {
        // NOTE: The block will be copied when we pass it to dispatch_async,
        //       and then automatically be deallocated by the objc runtime
        //       once it's executed.

        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Record the clamped drawable dimensions observed for the frame about to be
/// encoded and return their monotonic generation.
pub fn observePresentationSize(
    self: *IOSurfaceLayer,
    width: usize,
    height: usize,
) u64 {
    return self.presentation_lifetime.observeSize(width, height);
}

pub fn presentationGeneration(self: *IOSurfaceLayer) u64 {
    return self.presentation_lifetime.currentGeneration();
}

/// Reject prepared updates from a swap-chain lifetime that has ended even
/// when the replacement lifetime happens to use the same drawable dimensions.
pub fn advancePresentationGeneration(self: *IOSurfaceLayer) void {
    self.presentation_lifetime.advanceGeneration();
}

fn surfaceUpdateRunsInline(is_main_thread: bool, tokened: bool) bool {
    return is_main_thread and !tokened;
}

fn surfaceUpdatesActive(self: *const IOSurfaceLayer) bool {
    return self.layer.getInstanceVariable("surface_updates_active").value != null;
}

/// Prevent queued surface assignments and presentation callbacks from running.
/// The synchronous main-queue barrier orders invalidation after blocks already
/// queued and before any later GPU completion blocks inspect the flag.
pub fn invalidateSurfaceUpdates(self: *IOSurfaceLayer) void {
    self.presentation_lifetime.invalidate();
    var block = InvalidateSurfaceUpdatesBlock.init(.{
        .layer = self.layer.value,
    }, &invalidateSurfaceUpdatesCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        invalidateSurfaceUpdatesCallback(&block);
    } else {
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Does not ensure this happens on the main thread.
pub inline fn setSurfaceSync(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    generation: u64,
) bool {
    var live = self.presentation_lifetime.acquire(generation) orelse
        return false;
    defer live.deinit();

    if (!self.surfaceUpdatesActive()) return false;
    const bounds = self.layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = self.layer.getProperty(f64, "contentsScale");
    const width: usize = @intFromFloat(bounds.size.width * scale);
    const height: usize = @intFromFloat(bounds.size.height * scale);
    if (width != surface.getWidth() or height != surface.getHeight()) {
        log.debug(
            "setSurfaceSync(): surface is stale or wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return false;
    }

    self.layer.setProperty("contents", surface);
    return true;
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    lifetime: *PresentationLifetime,
    generation: u64,
    presentation_callback: ?*const fn (?*anyopaque, u64) callconv(.c) void,
    presentation_userdata: ?*anyopaque,
    presentation_token: u64,
    presentation_delivery_gate: ?*const fn (?*anyopaque) callconv(.c) void,
    presentation_delivery_gate_userdata: ?*anyopaque,
}, .{}, void);

const DetachFromHostBlock = objc.Block(struct {
    layer: objc.c.id,
    display_cb: ?*anyopaque,
    display_ctx: ?*anyopaque,
}, .{}, void);

const InvalidateSurfaceUpdatesBlock = objc.Block(struct {
    layer: objc.c.id,
}, .{}, void);

fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const lifetime = block.lifetime;

    // See explanation of why we retain and release in `setSurface`.
    defer block.surface.release();
    defer lifetime.release();

    {
        // Generation observation, invalidation, and assignment share this
        // lease, so a resize cannot advance between validation and assignment.
        var live = lifetime.acquire(block.generation) orelse return;
        defer live.deinit();

        const layer = objc.Object.fromId(block.layer);
        const surface: *IOSurface = block.surface;

        // Preserve the layer-owned delivery gate from current main. This is
        // checked only after the independently owned lifetime is known live.
        if (layer.getInstanceVariable("surface_updates_active").value == null)
            return;

        // We check to see if the surface is the appropriate size for
        // the layer, if it's not then we discard it. This is because
        // asynchronously drawn frames can sometimes finish just after
        // a synchronously drawn frame during a resize, and if we don't
        // discard the improperly sized surface it creates jank.
        const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
        const scale = layer.getProperty(f64, "contentsScale");
        const width: usize = @intFromFloat(bounds.size.width * scale);
        const height: usize = @intFromFloat(bounds.size.height * scale);
        if (width != surface.getWidth() or height != surface.getHeight()) {
            log.debug(
                "setSurfaceCallback(): surface is stale or wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
                .{ surface.getWidth(), surface.getHeight(), width, height },
            );
            return;
        }

        layer.setProperty("contents", surface);
    }

    if (block.presentation_callback) |callback| {
        if (block.presentation_delivery_gate) |gate| {
            gate(block.presentation_delivery_gate_userdata);
        }
        callback(block.presentation_userdata, block.presentation_token);
    }
}

fn detachFromHostCallback(
    block: *const DetachFromHostBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);

    // This layer is terminally owned by the renderer being destroyed, even if
    // another display callback replaced the one recorded by the detach guard.
    layer.setInstanceVariable("surface_updates_active", .{ .value = null });

    // Ownership guard: if this layer's callback has been rebound to another
    // renderer, leave the binding alone.
    const cur_cb: ?*anyopaque = @ptrCast(layer.getInstanceVariable("display_cb").value);
    const cur_ctx: ?*anyopaque = @ptrCast(layer.getInstanceVariable("display_ctx").value);
    if (cur_cb != block.display_cb or cur_ctx != block.display_ctx) {
        return;
    }

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });
    layer.setProperty("contents", @as(?*anyopaque, null));
    layer.msgSend(void, objc.sel("removeFromSuperlayer"), .{});
}

fn invalidateSurfaceUpdatesCallback(
    block: *const InvalidateSurfaceUpdatesBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    layer.setInstanceVariable("surface_updates_active", .{ .value = null });
}

const PresentationLifetime = struct {
    const Self = @This();

    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    mutex: std.Thread.Mutex = .{},
    valid: bool = true,
    generation: u64 = 1,
    observed_width: usize = 0,
    observed_height: usize = 0,

    const Live = struct {
        owner: *Self,

        fn deinit(self: *Live) void {
            self.owner.mutex.unlock();
        }
    };

    fn create() !*Self {
        const self = try std.heap.c_allocator.create(Self);
        self.* = .{};
        return self;
    }

    fn retain(self: *Self) void {
        const previous = self.refs.fetchAdd(1, .seq_cst);
        std.debug.assert(previous > 0);
    }

    fn release(self: *Self) void {
        const previous = self.refs.fetchSub(1, .seq_cst);
        std.debug.assert(previous > 0);
        if (previous == 1) std.heap.c_allocator.destroy(self);
    }

    fn invalidate(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.valid = false;
    }

    fn acquire(self: *Self, generation: u64) ?Live {
        self.mutex.lock();
        if (!self.valid or self.generation != generation) {
            self.mutex.unlock();
            return null;
        }
        return .{ .owner = self };
    }

    fn observeSize(self: *Self, width: usize, height: usize) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (width != self.observed_width or height != self.observed_height) {
            self.observed_width = width;
            self.observed_height = height;
            self.advanceGenerationLocked();
        }
        return self.generation;
    }

    fn advanceGeneration(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.advanceGenerationLocked();
    }

    fn advanceGenerationLocked(self: *Self) void {
        std.debug.assert(self.generation < std.math.maxInt(u64));
        self.generation += 1;
    }

    fn currentGeneration(self: *Self) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generation;
    }
};

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CALayer =
        objc.getClass("CALayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CALayer, "IOSurfaceLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;
    if (!subclass.addIvar("surface_updates_active")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    // Disable all animations for this layer by returning null for all actions.
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}

test "tokened surface updates defer delivery and teardown invalidates them" {
    const testing = std.testing;

    const CallbackState = struct {
        gate_count: usize = 0,
        callback_count: usize = 0,

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.gate_count += 1;
        }

        fn callback(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.callback_count += 1;
        }
    };

    try testing.expect(!surfaceUpdateRunsInline(true, true));
    try testing.expect(surfaceUpdateRunsInline(true, false));
    try testing.expect(!surfaceUpdateRunsInline(false, false));

    var layer = try IOSurfaceLayer.init();
    defer layer.release();
    try testing.expect(layer.surfaceUpdatesActive());
    layer.invalidateSurfaceUpdates();
    try testing.expect(!layer.surfaceUpdatesActive());

    // Exercise the queued block's actual entrypoint after invalidation. The
    // retained IOSurface is released, but neither presentation function may
    // observe surface-owned userdata after teardown begins.
    var surface = try IOSurface.init(.{
        .width = 1,
        .height = 1,
        .pixel_format = .@"32BGRA",
        .bytes_per_element = 4,
        .colorspace = null,
    });
    defer surface.deinit();
    surface.retain();
    const generation = layer.presentationGeneration();
    layer.presentation_lifetime.retain();

    var state: CallbackState = .{};
    var block = SetSurfaceBlock.init(.{
        .layer = layer.layer.value,
        .surface = surface,
        .lifetime = layer.presentation_lifetime,
        .generation = generation,
        .presentation_callback = &CallbackState.callback,
        .presentation_userdata = &state,
        .presentation_token = 42,
        .presentation_delivery_gate = &CallbackState.gate,
        .presentation_delivery_gate_userdata = &state,
    }, &setSurfaceCallback);
    setSurfaceCallback(&block);

    try testing.expectEqual(@as(usize, 0), state.gate_count);
    try testing.expectEqual(@as(usize, 0), state.callback_count);
}

test "stale same-size generation cannot acquire presentation lifetime" {
    var lifetime: PresentationLifetime = .{};

    const stale_generation = lifetime.observeSize(80, 24);
    _ = lifetime.observeSize(81, 24);
    const current_generation = lifetime.observeSize(80, 24);

    // The drawable returned to its prior dimensions, but the old frame still
    // belongs to an earlier lifetime and must not overwrite layer contents.
    try std.testing.expect(stale_generation != current_generation);
    try std.testing.expect(lifetime.acquire(stale_generation) == null);

    var current = lifetime.acquire(current_generation);
    try std.testing.expect(current != null);
    current.?.deinit();
}
