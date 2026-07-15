//! A wrapper around a CALayer with a utility method
//! for settings its `contents` to an IOSurface.
const IOSurfaceLayer = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const macos = @import("macos");
const presentation = @import("../presentation.zig");

const IOSurface = macos.iosurface.IOSurface;

const log = std.log.scoped(.IOSurfaceLayer);

/// We subclass CALayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;

/// The underlying CALayer
layer: objc.Object,

pub fn init(
    presentation_cb: ?presentation.Callback,
    presentation_ctx: ?*anyopaque,
) !IOSurfaceLayer {
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
    layer.setInstanceVariable(
        "presentation_cb",
        objc.Object.fromId(@constCast(presentation_cb)),
    );
    layer.setInstanceVariable(
        "presentation_ctx",
        objc.Object.fromId(presentation_ctx),
    );
    layer.setInstanceVariable("presentation_active", .{ .value = null });
    layer.setInstanceVariable("presentation_ticket", .{ .value = null });
    layer.setInstanceVariable("presentation_floor", .{ .value = null });

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
pub inline fn setSurface(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    ticket: ?u64,
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
        .ticket = ticket orelse 0,
        .has_ticket = ticket != null,
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

/// Install the current ticket on the main queue before its frame is submitted.
/// A later ticket supersedes an older in-flight frame, so stale presentation
/// callbacks cannot complete the newer terminal delivery.
pub fn beginPresentation(self: *IOSurfaceLayer, ticket: u64) void {
    var block = PresentationBeginBlock.init(.{
        .layer = self.layer.value,
        .ticket = ticket,
    }, &presentationBeginCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        presentationBeginCallback(&block);
    } else {
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Synchronously invalidate a ticket and every older queued presentation on
/// the main-layer owner. Existing contents stay visible until a newer ticket
/// reaches `setSurfaceCallback`.
pub fn invalidatePresentationThrough(
    self: *IOSurfaceLayer,
    ticket: u64,
) void {
    var block = PresentationInvalidationBlock.init(.{
        .layer = self.layer.value,
        .ticket = ticket,
    }, &presentationInvalidationCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        presentationInvalidationCallback(&block);
    } else {
        macos.dispatch.dispatch_sync(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

/// Report a ticket that failed before an IOSurface reached the layer. The
/// callback is always read and invoked on the main queue, where teardown also
/// clears it, so a queued completion cannot outlive its embedder userdata.
pub fn completePresentation(
    self: *IOSurfaceLayer,
    ticket: u64,
    status: presentation.Status,
) void {
    var block = PresentationBlock.init(.{
        .layer = self.layer.value,
        .ticket = ticket,
        .status = status,
    }, &presentationCallback);

    const NSThread = objc.getClass("NSThread").?;
    if (NSThread.msgSend(bool, "isMainThread", .{})) {
        presentationCallback(&block);
    } else {
        macos.dispatch.dispatch_async(
            @ptrCast(macos.dispatch.queue.getMain()),
            @ptrCast(&block),
        );
    }
}

const SetSurfaceBlock = objc.Block(struct {
    layer: objc.c.id,
    surface: *IOSurface,
    ticket: u64,
    has_ticket: bool,
}, .{}, void);

const PresentationBlock = objc.Block(struct {
    layer: objc.c.id,
    ticket: u64,
    status: presentation.Status,
}, .{}, void);

const PresentationBeginBlock = objc.Block(struct {
    layer: objc.c.id,
    ticket: u64,
}, .{}, void);

const PresentationInvalidationBlock = objc.Block(struct {
    layer: objc.c.id,
    ticket: u64,
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

    // Lifecycle invalidation must win before either the wrong-size callback or
    // the contents assignment. Otherwise a queued pre-suspend frame can flash
    // stale pixels after foreground resume even though Swift ignores its ACK.
    if (block.has_ticket and !presentationTicketIsActive(layer, block.ticket)) {
        return;
    }

    // We check to see if the surface is the appropriate size for
    // the layer, if it's not then we discard it. This is because
    // asynchronously drawn frames can sometimes finish just after
    // a synchronously drawn frame during a resize, and if we don't
    // discard the improperly sized surface it creates jank.
    const status = presentationStatusForLayerAndSurface(layer, surface);
    if (status == .wrong_size_discarded) {
        const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
        const scale = layer.getProperty(f64, "contentsScale");
        log.debug(
            "setSurfaceCallback(): surface is wrong size for layer, discarding. surface = {d}x{d}, layer = {d}x{d}",
            .{
                surface.getWidth(),
                surface.getHeight(),
                @as(usize, @intFromFloat(bounds.size.width * scale)),
                @as(usize, @intFromFloat(bounds.size.height * scale)),
            },
        );
        if (block.has_ticket) notifyPresentation(
            layer,
            block.ticket,
            .wrong_size_discarded,
        );
        return;
    }

    layer.setProperty("contents", surface);
    if (block.has_ticket) notifyPresentation(layer, block.ticket, .presented);
}

fn presentationCallback(
    block: *const PresentationBlock.Context,
) callconv(.c) void {
    notifyPresentation(
        objc.Object.fromId(block.layer),
        block.ticket,
        block.status,
    );
}

fn presentationBeginCallback(
    block: *const PresentationBeginBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    if (block.ticket <= presentationFloor(layer)) return;
    const active = layer.getInstanceVariable("presentation_active").value != null;
    const active_ticket = @intFromPtr(
        layer.getInstanceVariable("presentation_ticket").value,
    );
    if (active and block.ticket <= active_ticket) return;
    layer.setInstanceVariable(
        "presentation_ticket",
        objc.Object.fromId(@as(?*anyopaque, @ptrFromInt(block.ticket))),
    );
    layer.setInstanceVariable(
        "presentation_active",
        objc.Object.fromId(@as(?*anyopaque, @ptrFromInt(1))),
    );
}

fn presentationInvalidationCallback(
    block: *const PresentationInvalidationBlock.Context,
) callconv(.c) void {
    const layer = objc.Object.fromId(block.layer);
    const floor = @max(presentationFloor(layer), block.ticket);
    layer.setInstanceVariable(
        "presentation_floor",
        objc.Object.fromId(@as(?*anyopaque, @ptrFromInt(floor))),
    );

    const active_ticket = @intFromPtr(
        layer.getInstanceVariable("presentation_ticket").value,
    );
    if (active_ticket <= floor) {
        layer.setInstanceVariable("presentation_active", .{ .value = null });
        layer.setInstanceVariable("presentation_ticket", .{ .value = null });
    }
}

fn presentationFloor(layer: objc.Object) u64 {
    return @intFromPtr(layer.getInstanceVariable("presentation_floor").value);
}

fn presentationTicketIsActive(layer: objc.Object, ticket: u64) bool {
    if (ticket <= presentationFloor(layer)) return false;
    const active = layer.getInstanceVariable("presentation_active").value != null;
    const active_ticket = @intFromPtr(
        layer.getInstanceVariable("presentation_ticket").value,
    );
    return active and active_ticket == ticket;
}

fn notifyPresentation(
    layer: objc.Object,
    ticket: u64,
    status: presentation.Status,
) void {
    if (!presentationTicketIsActive(layer, ticket)) return;

    // Clear before invoking foreign code so reentrancy cannot complete twice.
    layer.setInstanceVariable("presentation_active", .{ .value = null });
    layer.setInstanceVariable("presentation_ticket", .{ .value = null });

    const callback: ?presentation.Callback = @ptrFromInt(@intFromPtr(
        layer.getInstanceVariable("presentation_cb").value,
    ));
    const cb = callback orelse return;
    cb(
        @ptrCast(layer.getInstanceVariable("presentation_ctx").value),
        ticket,
        status,
    );
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
    layer.setInstanceVariable("presentation_cb", .{ .value = null });
    layer.setInstanceVariable("presentation_ctx", .{ .value = null });
    layer.setInstanceVariable("presentation_active", .{ .value = null });
    layer.setInstanceVariable("presentation_ticket", .{ .value = null });
    layer.setInstanceVariable("presentation_floor", .{ .value = null });
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
    if (!subclass.addIvar("presentation_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("presentation_ctx")) return error.ObjCFailed;
    if (!subclass.addIvar("presentation_active")) return error.ObjCFailed;
    if (!subclass.addIvar("presentation_ticket")) return error.ObjCFailed;
    if (!subclass.addIvar("presentation_floor")) return error.ObjCFailed;

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

const PixelSize = struct {
    width: usize,
    height: usize,
};

const PresentationStatus = presentation.Status;

fn presentationStatusForSizes(
    layer_size: PixelSize,
    surface_size: PixelSize,
) PresentationStatus {
    if (layer_size.width != surface_size.width or
        layer_size.height != surface_size.height)
    {
        return .wrong_size_discarded;
    }
    return .presented;
}

fn presentationStatusForLayerAndSurface(
    layer: objc.Object,
    surface: *IOSurface,
) PresentationStatus {
    const bounds = layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = layer.getProperty(f64, "contentsScale");
    return presentationStatusForSizes(
        .{
            .width = @intFromFloat(bounds.size.width * scale),
            .height = @intFromFloat(bounds.size.height * scale),
        },
        .{ .width = surface.getWidth(), .height = surface.getHeight() },
    );
}

const PresentationTicketTracker = struct {
    invalidation_floor: u64 = 0,
    pending_ticket: ?u64 = null,
    contents_ticket: ?u64 = null,
    completed_ticket: ?u64 = null,
    completed_status: ?PresentationStatus = null,
    callback_count: usize = 0,

    fn begin(self: *@This(), ticket: u64) bool {
        if (ticket <= self.invalidation_floor) return false;
        if (self.pending_ticket) |pending| {
            if (ticket <= pending) return false;
        }
        self.pending_ticket = ticket;
        return true;
    }

    fn invalidateThrough(self: *@This(), ticket: u64) void {
        self.invalidation_floor = @max(self.invalidation_floor, ticket);
        if (self.pending_ticket) |pending| {
            if (pending <= self.invalidation_floor) self.pending_ticket = null;
        }
    }

    fn setSurface(self: *@This(), ticket: u64) bool {
        if (ticket <= self.invalidation_floor or
            self.pending_ticket != ticket) return false;
        self.contents_ticket = ticket;
        return self.complete(ticket, .presented);
    }

    fn complete(
        self: *@This(),
        ticket: u64,
        status: PresentationStatus,
    ) bool {
        if (ticket <= self.invalidation_floor or
            self.pending_ticket != ticket) return false;
        self.pending_ticket = null;
        self.completed_ticket = ticket;
        self.completed_status = status;
        self.callback_count += 1;
        return true;
    }
};

test "presentation ticket completes once with the exact terminal frame result" {
    var tracker = PresentationTicketTracker{};

    try std.testing.expect(tracker.begin(41));
    try std.testing.expect(!tracker.begin(41));
    try std.testing.expectEqual(
        PresentationStatus.wrong_size_discarded,
        presentationStatusForSizes(
            .{ .width = 100, .height = 60 },
            .{ .width = 101, .height = 60 },
        ),
    );
    try std.testing.expectEqual(
        PresentationStatus.presented,
        presentationStatusForSizes(
            .{ .width = 100, .height = 60 },
            .{ .width = 100, .height = 60 },
        ),
    );
    try std.testing.expect(tracker.complete(41, .presented));
    try std.testing.expect(!tracker.complete(41, .backend_failed));
    try std.testing.expectEqual(@as(?u64, 41), tracker.completed_ticket);
    try std.testing.expectEqual(PresentationStatus.presented, tracker.completed_status.?);
}

test "stale presentation cannot complete a newer ticket" {
    var tracker = PresentationTicketTracker{};

    try std.testing.expect(tracker.begin(7));
    try std.testing.expect(tracker.begin(8));
    try std.testing.expect(!tracker.complete(7, .presented));
    try std.testing.expect(tracker.complete(8, .wrong_size_discarded));
    try std.testing.expectEqual(@as(?u64, 8), tracker.completed_ticket);
}

test "invalidation gates queued begin and surface mutation through exact ticket" {
    var tracker = PresentationTicketTracker{ .contents_ticket = 40 };

    try std.testing.expect(tracker.begin(41));
    tracker.invalidateThrough(41);
    try std.testing.expect(!tracker.begin(41));
    try std.testing.expect(!tracker.setSurface(41));
    try std.testing.expectEqual(@as(?u64, 40), tracker.contents_ticket);
    try std.testing.expectEqual(@as(usize, 0), tracker.callback_count);

    try std.testing.expect(tracker.begin(42));
    try std.testing.expect(!tracker.begin(41));
    try std.testing.expect(!tracker.setSurface(41));
    try std.testing.expectEqual(@as(?u64, 40), tracker.contents_ticket);
    try std.testing.expect(tracker.setSurface(42));
    try std.testing.expectEqual(@as(?u64, 42), tracker.contents_ticket);
    try std.testing.expectEqual(@as(usize, 1), tracker.callback_count);
    try std.testing.expectEqual(@as(?u64, 42), tracker.completed_ticket);

    // The floor survives successful presentation, so even a very late queued
    // begin from before invalidation cannot reactivate ticket 41.
    try std.testing.expect(!tracker.begin(41));
}
