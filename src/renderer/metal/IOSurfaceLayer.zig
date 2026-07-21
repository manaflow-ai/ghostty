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

/// The underlying CALayer
layer: objc.Object,

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

    // The layer gravity is set to top-left so that the contents aren't
    // stretched during resize operations before a new frame has been drawn.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });

    return .{ .layer = layer };
}

pub fn release(self: *IOSurfaceLayer) void {
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
pub inline fn setSurface(self: *IOSurfaceLayer, surface: *IOSurface) !void {
    return self.setSurfaceWithPresentation(surface, null);
}

/// Sets the layer contents and acknowledges the exact token after the size
/// guard succeeds. This callback runs on main in the same block as assignment.
pub inline fn setSurfaceWithPresentation(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    presentation: ?FramePresentation,
) !void {
    // We retain the surface to make sure it's not GC'd
    // before we can set it as the contents of the layer.
    //
    // We release in the callback after setting the contents.
    surface.retain();
    // NOTE: Since `self.layer` is passed as an `objc.c.id`, it's
    //       automatically retained when the block is copied, so we
    //       don't need to retain it ourselves like with the surface.

    var block = SetSurfaceBlock.init(.{
        .layer = self.layer.value,
        .surface = surface,
        .presentation_callback = if (presentation) |value| value.callback else null,
        .presentation_userdata = if (presentation) |value| value.userdata else null,
        .presentation_token = if (presentation) |value| value.token else 0,
    }, &setSurfaceCallback);

    // We check if we're on the main thread and run the block directly if so.
    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
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

/// Sets the layer's `contents` to the provided IOSurface.
///
/// Does not ensure this happens on the main thread.
pub inline fn setSurfaceSync(self: *IOSurfaceLayer, surface: *IOSurface) void {
    self.layer.setProperty("contents", surface);
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    presentation_callback: ?*const fn (?*anyopaque, u64) callconv(.c) void,
    presentation_userdata: ?*anyopaque,
    presentation_token: u64,
}, .{}, void);

const DetachFromHostBlock = objc.Block(struct {
    layer: objc.c.id,
    display_cb: ?*anyopaque,
    display_ctx: ?*anyopaque,
}, .{}, void);

fn setSurfaceCallback(
    block: *const SetSurfaceBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    const surface: *IOSurface = block.surface;

    // See explanation of why we retain and release in `setSurface`.
    defer surface.release();

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
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{ surface.getWidth(), surface.getHeight(), width, height },
        );
        return;
    }

    layer.setProperty("contents", surface);
    if (block.presentation_callback) |callback| {
        callback(block.presentation_userdata, block.presentation_token);
    }
}

fn detachFromHostCallback(
    block: *const DetachFromHostBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);

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

    try testing.expect(!surfaceUpdateRunsInline(true, true));
    try testing.expect(surfaceUpdateRunsInline(true, false));
    try testing.expect(!surfaceUpdateRunsInline(false, false));

    var layer = try IOSurfaceLayer.init();
    defer layer.layer.release();
    try testing.expect(layer.surfaceUpdatesActive());
    layer.invalidateSurfaceUpdates();
    try testing.expect(!layer.surfaceUpdatesActive());
}
