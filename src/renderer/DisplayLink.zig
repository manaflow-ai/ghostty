//! A CVDisplayLink that is only ever started, stopped, or re-targeted
//! from the main thread.
//!
//! ## Why start and stop must happen on the main thread
//!
//! CoreVideo's `CVDisplayLinkStop` clears the link's running flag and
//! then waits, once and unconditionally, for the link's IO thread to
//! notice and exit. While it waits, the link's mutex is released. If any
//! thread calls `CVDisplayLinkStart` during that wait, the flag is set
//! again and a second IO thread is created. The first IO thread wakes up,
//! sees the flag set, and keeps running. Nothing ever signals the waiting
//! `CVDisplayLinkStop`, so it blocks forever.
//!
//! CoreVideo itself performs exactly this stop and start sequence, on the
//! main thread, inside its display reconfiguration callback. That fires
//! whenever the display the link is bound to changes mode, which happens
//! on display sleep and wake, resolution changes, and hotplug.
//! `CVDisplayLinkSetCurrentCGDisplay` performs the same sequence. None of
//! these calls take a lock that protects against each other.
//!
//! So a start or stop issued from the render thread can collide with
//! CoreVideo's own, and whichever side loses is stuck in
//! `CVDisplayLinkStop` forever. In Ghostty that first wedged the render
//! thread, then the main thread as soon as it waited on the renderer, and
//! the whole app froze. See
//! https://github.com/ghostty-org/ghostty/discussions/14150.
//!
//! The fix is to issue every state change from the main thread, where it
//! is serialized with CoreVideo's own reconfiguration handling simply by
//! running on the same thread.
const DisplayLink = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const global = @import("../global.zig");

const log = std.log.scoped(.display_link);

alloc: Allocator,

/// The underlying CVDisplayLink. Its state is only changed on the
/// main thread.
link: *macos.video.DisplayLink,

/// Set when `close` finishes on the main thread. A sync that was already
/// queued at that point sees this, skips its work, and frees the struct.
/// Main thread only.
closed: bool = false,

/// cmux fork: the owner's callback and its userdata. CoreVideo calls
/// `outputCallback` with this struct as its userdata, and that forwards
/// to the owner's callback under `target_mutex`. `close` clears both
/// under the same mutex, so once `close` returns the owner's userdata is
/// never touched again, even before the main thread stops the link. That
/// lets `close` run on any thread: cmux frees some surfaces off the main
/// thread.
target: ?*anyopaque = null,
target_fn: ?*const fn (*macos.video.DisplayLink, *anyopaque) void = null,
target_mutex: std.Io.Mutex = .init,

/// The display the link was last bound to with `setDisplay`, or zero
/// if `setDisplay` was never called. Main thread only.
display: u32 = 0,

/// The state the owner has asked for. Written by `setRunning` and
/// `setDisplay` on the owner's thread and read by the sync on the
/// main thread. Packing both fields into one atomic means the sync
/// always sees them together as they were last requested.
requested: std.atomic.Value(Requested) = .init(.{}),

/// True while a sync is queued on the main thread and has not yet
/// started. Used to collapse many requests into one sync, and by
/// `close` to know whether a queued sync still needs this struct.
sync_queued: std.atomic.Value(bool) = .init(false),

/// The state the owner wants the link in. This is a single 64-bit
/// value so that it can be read and written atomically as a whole.
const Requested = packed struct(u64) {
    /// Whether the link should be running.
    running: bool = false,

    _padding: u31 = 0,

    /// The CGDirectDisplayID the link should be bound to, or zero if
    /// no display has been requested.
    display: u32 = 0,
};

/// Create a display link bound to the active displays. The link starts
/// out stopped and has no output callback. Call `setOutputCallback`, then
/// `setRunning` to start it.
///
/// This can be called from any thread. Creating a link does not change
/// its running state, so it does not collide with CoreVideo's
/// reconfiguration handling.
///
/// Fails if no display is available, which can happen briefly while
/// the session is locked or a display is asleep. Callers can continue
/// without vsync.
pub fn create(alloc: Allocator) !*DisplayLink {
    const link = try macos.video.DisplayLink.createWithActiveCGDisplays();
    errdefer link.release();

    const self = try alloc.create(DisplayLink);
    errdefer alloc.destroy(self);
    self.* = .{
        .alloc = alloc,
        .link = link,
    };

    return self;
}

/// Set the output callback. `callbackFn` is invoked by CoreVideo on its
/// own thread once per display refresh while the link is running, with
/// `userdata` as its argument. `userdata` must stay valid until `close`
/// returns.
///
/// cmux fork: the renderer sets the callback on the render thread when
/// its loop starts, because that is when `draw_now` has a stable address.
/// The link is stopped at that point. Setting the callback does not
/// change the link's running state, so it is safe off the main thread.
pub fn setOutputCallback(
    self: *DisplayLink,
    comptime Userdata: type,
    comptime callbackFn: *const fn (*macos.video.DisplayLink, ?*Userdata) void,
    userdata: ?*Userdata,
) !void {
    const Trampoline = struct {
        fn call(link: *macos.video.DisplayLink, ud: *anyopaque) void {
            callbackFn(link, @ptrCast(@alignCast(ud)));
        }
    };

    {
        self.target_mutex.lockUncancelable(global.io());
        defer self.target_mutex.unlock(global.io());
        self.target = userdata;
        self.target_fn = &Trampoline.call;
    }

    try self.link.setOutputCallback(DisplayLink, &outputCallback, self);
}

/// The callback CoreVideo invokes on its IO thread. Forwards to the
/// owner's callback unless `close` has detached it.
fn outputCallback(link: *macos.video.DisplayLink, ud: ?*DisplayLink) void {
    const self = ud orelse return;
    self.target_mutex.lockUncancelable(global.io());
    defer self.target_mutex.unlock(global.io());
    const target = self.target orelse return;
    const target_fn = self.target_fn orelse return;
    target_fn(link, target);
}

/// Stop and release the display link. The pointer is invalid after
/// this call.
///
/// Can be called on any thread. The owner's callback is detached before
/// this returns, so whatever its userdata pointed at can be freed right
/// after. The stop and release themselves happen on the main thread:
/// inline if this is the main thread, otherwise shortly after through the
/// main queue. Stopping waits for CoreVideo's IO thread to exit, and that
/// is only safe on the main thread, where CoreVideo's own stop and start
/// also run and so cannot restart the link while we wait.
///
/// No other method may be called on this link after or concurrently
/// with `close`. In practice the render thread that makes those calls
/// has already exited by the time the renderer is deinitialized.
pub fn close(self: *DisplayLink) void {
    {
        self.target_mutex.lockUncancelable(global.io());
        defer self.target_mutex.unlock(global.io());
        self.target = null;
        self.target_fn = null;
    }

    if (pthread_main_np() != 0) {
        self.finishClose();
        return;
    }

    macos.dispatch.c.dispatch_async_f(
        macos.dispatch.c.dispatch_get_main_queue(),
        self,
        &closeCallback,
    );
}

extern "c" fn pthread_main_np() c_int;

fn closeCallback(ud: ?*anyopaque) callconv(.c) void {
    const self: *DisplayLink = @ptrCast(@alignCast(ud.?));
    self.finishClose();
}

/// The main-thread half of `close`.
fn finishClose(self: *DisplayLink) void {
    assert(!self.closed);
    self.closed = true;

    if (self.link.isRunning()) self.link.stop() catch |err| {
        log.warn("error stopping display link err={}", .{err});
    };
    self.link.release();

    // If a sync is still queued on the main thread it runs after us and
    // still needs this struct, so it frees it instead of us. Both run on
    // the main thread, and the render thread that queues syncs has exited,
    // so this read cannot race a new queueSync.
    if (!self.sync_queued.load(.seq_cst)) self.destroy();
}

fn destroy(self: *DisplayLink) void {
    const alloc = self.alloc;
    self.* = undefined;
    alloc.destroy(self);
}

/// Returns true if the link is running right now, meaning CoreVideo is
/// invoking the output callback on every display refresh.
///
/// This reports the link's actual state, not the state most recently
/// requested with `setRunning`. The two differ briefly after a request,
/// and also when a start failed or CoreVideo stopped the link itself
/// during a display reconfiguration. Can be called from any thread.
pub fn isRunning(self: *DisplayLink) bool {
    return self.link.isRunning();
}

/// Request that the link run, or stop running. Never blocks.
///
/// The change is applied shortly after on the main thread. Until then
/// `isRunning` keeps reporting the old state. Calling this repeatedly
/// with the same value is cheap, and calling it with alternating values
/// in quick succession results in at most one real change.
///
/// This and `setDisplay` must be called from a single thread, which
/// for the renderer is the render thread. That thread is the only
/// writer of the requested state, so no compare-and-swap is needed.
pub fn setRunning(self: *DisplayLink, running: bool) void {
    var requested = self.requested.load(.seq_cst);

    // cmux fork: queue a sync whenever the request changes, not only when
    // it differs from the link's current state. A sync that already read
    // the old request may not have applied it yet, so the current state
    // can still match the new request while the pending start or stop is
    // about to undo it. Upstream calls this every frame and recovers; the
    // fork only calls it on focus, visibility and loop enter or exit.
    if (requested.running == running and
        running == self.link.isRunning()) return;

    requested.running = running;
    self.requested.store(requested, .seq_cst);
    self.queueSync();
}

/// Request that the link be bound to the given CGDirectDisplayID, so
/// that it follows that display's refresh rate. Never blocks.
///
/// Call this when the window moves to a different screen. A display ID
/// of zero means no display and is ignored. See `setRunning` for the
/// threading requirement.
pub fn setDisplay(self: *DisplayLink, display_id: u32) void {
    if (display_id == 0) return;
    var requested = self.requested.load(.seq_cst);
    requested.display = display_id;
    self.requested.store(requested, .seq_cst);
    self.queueSync();
}

/// Queue a sync onto the main thread, unless one is already queued and
/// has not started yet.
///
/// A sync that has already started clears `sync_queued` before it reads
/// the requested state, so a request that arrives too late for it will
/// queue another sync rather than be lost.
fn queueSync(self: *DisplayLink) void {
    if (self.sync_queued.swap(true, .seq_cst)) return;
    macos.dispatch.c.dispatch_async_f(
        macos.dispatch.c.dispatch_get_main_queue(),
        self,
        &syncCallback,
    );
}

fn syncCallback(ud: ?*anyopaque) callconv(.c) void {
    const self: *DisplayLink = @ptrCast(@alignCast(ud.?));

    // Clear this before reading the requested state. See queueSync.
    self.sync_queued.store(false, .seq_cst);

    // If the owner closed the link while we were queued, it left the
    // struct for us to free. See close.
    if (self.closed) {
        self.destroy();
        return;
    }

    self.sync();
}

/// Make the link's actual state match the requested state. Main thread
/// only. Every CoreVideo call that changes the link's state is made
/// from here or from `close`.
fn sync(self: *DisplayLink) void {
    const requested = self.requested.load(.seq_cst);

    if (requested.display != 0 and requested.display != self.display) {
        // Record the display even if binding fails so that we don't
        // retry on every sync. The next display change tries again.
        self.display = requested.display;
        log.info("updating display link display id={}", .{requested.display});

        // If the link is running, CoreVideo stops and restarts it
        // internally. That is safe here for the same reason our own
        // stop below is.
        self.link.setCurrentCGDisplay(requested.display) catch |err| {
            log.warn("error setting display link display id err={}", .{err});
        };
    }

    const running = self.link.isRunning();
    if (requested.running and !running) {
        // If this fails the link stays stopped. The renderer notices
        // through isRunning and draws without vsync, and the next
        // request retries. This is logged at debug level because a
        // display can be unavailable for a while, such as during a
        // locked session, and we would otherwise log once per frame.
        self.link.start() catch |err| {
            log.debug("error starting display link err={}", .{err});
        };
    } else if (!requested.running and running) {
        self.link.stop() catch |err| {
            log.warn("error stopping display link err={}", .{err});
        };
    }
}
