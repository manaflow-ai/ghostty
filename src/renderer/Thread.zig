//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("../global.zig").xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const BlockingQueue = @import("../datastruct/main.zig").BlockingQueue;
const App = @import("../App.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.renderer_thread);

const DRAW_INTERVAL = 8; // 120 FPS
const CURSOR_BLINK_INTERVAL = 600;

/// Coalesces renderer visibility changes across one mailbox drain. The flags
/// still update in message order, but expensive renderer work observes only
/// the final state after every already-queued transition has been applied.
const VisibilityDrainState = struct {
    initial: bool,
    current: bool,

    fn init(visible: bool) VisibilityDrainState {
        return .{ .initial = visible, .current = visible };
    }

    fn apply(self: *VisibilityDrainState, visible: bool) bool {
        if (self.current == visible) return false;
        self.current = visible;
        return true;
    }

    fn rendererTransition(self: VisibilityDrainState) ?bool {
        return if (self.initial == self.current) null else self.current;
    }
};

const MailboxDrainResult = struct {
    rendered_visibility_regain: bool = false,
};

/// Apply the one renderer visibility transition left after mailbox
/// coalescing. The context seam keeps the wake behavior directly testable
/// without constructing a platform renderer.
fn applyRendererVisibilityTransition(
    context: anytype,
    visible: ?bool,
) MailboxDrainResult {
    const final_visible = visible orelse return .{};
    const result: MailboxDrainResult = .{
        .rendered_visibility_regain = final_visible and
            context.updateAndDrawFrame(),
    };
    context.setRendererVisible(final_visible);
    return result;
}

/// A successful visibility-regain render already satisfies this wake. Other
/// wakes retain the normal render callback, including a retry after failure.
fn renderAfterMailboxDrain(
    context: anytype,
    result: MailboxDrainResult,
) void {
    if (!result.rendered_visibility_regain) context.renderWakeFrame();
}

/// Whether calls to `drawFrame` must be done from the app thread.
///
/// If this is `true` then we send a `redraw_surface` message to the apprt
/// whenever we need to draw instead of calling `drawFrame` directly.
const must_draw_from_app_thread =
    if (@hasDecl(apprt.App, "must_draw_from_app_thread"))
        apprt.App.must_draw_from_app_thread
    else
        false;

/// The type used for sending messages to the IO thread. For now this is
/// hardcoded with a capacity. We can make this a comptime parameter in
/// the future if we want it configurable.
pub const Mailbox = BlockingQueue(rendererpkg.Message, 64);

/// Allocator used for some state
alloc: std.mem.Allocator,

/// The main event loop for the application. The user data of this loop
/// is always the allocator used to create the loop. This is a convenience
/// so that users of the loop always have an allocator.
loop: xev.Loop,

/// This can be used to wake up the renderer and force a render safely from
/// any thread.
wakeup: xev.Async,
wakeup_c: xev.Completion = .{},

/// This can be used to stop the renderer on the next loop iteration.
stop: xev.Async,
stop_c: xev.Completion = .{},

/// The timer used for rendering
render_h: xev.Timer,
render_c: xev.Completion = .{},

/// The timer used for draw calls. Draw calls don't update from the
/// terminal state so they're much cheaper. They're used for animation
/// and are paused when the terminal is not focused.
draw_h: xev.Timer,
draw_c: xev.Completion = .{},
draw_active: bool = false,

/// This async is used to force a draw immediately. This does not
/// coalesce like the wakeup does.
draw_now: xev.Async,
draw_now_c: xev.Completion = .{},

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},

/// The surface we're rendering to.
surface: *apprt.Surface,

/// The underlying renderer implementation.
renderer: *rendererpkg.Renderer,

/// Pointer to the shared state that is used to generate the final render.
state: *rendererpkg.State,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: *Mailbox,

/// Mailbox to send messages to the app thread
app_mailbox: App.Mailbox,

/// Configuration we need derived from the main config.
config: DerivedConfig,

/// cmux iOS fork: count of bounded frame-state acquire timeouts, used to
/// throttle the greppable `render.frame.acquire.timeout` log line. Wraps.
frame_acquire_timeouts: u64 = 0,

/// cmux iOS fork: true once the embedder has used `renderNow` as an external
/// renderer-mailbox drainer. libxev loop state is single-thread-owned: once
/// this is set, only the external render serial queue may drain the mailbox or
/// mutate renderer state; the renderer OS thread only keeps async stop alive.
external_drain: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// Monotonic millisecond epoch used to derive cursor blink phase while
/// `external_drain` disables the renderer-thread cursor timer.
cursor_blink_epoch_ms: i64 = 0,

flags: packed struct {
    /// This is true when a blinking cursor should be visible and false
    /// when it should not be visible. This is toggled on a timer by the
    /// thread automatically.
    cursor_blink_visible: bool = false,

    /// This is true when the inspector is active.
    has_inspector: bool = false,

    /// This is true when the view is visible. This is used to determine
    /// if we should be rendering or not.
    visible: bool = true,

    /// This is true when the view is focused. This defaults to true
    /// and it is up to the apprt to set the correct value.
    focused: bool = true,
} = .{},

pub const DerivedConfig = struct {
    custom_shader_animation: configpkg.CustomShaderAnimation,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .custom_shader_animation = config.@"custom-shader-animation",
        };
    }
};

/// Initialize the thread. This does not START the thread. This only sets
/// up all the internal state necessary prior to starting the thread. It
/// is up to the caller to start the thread with the threadMain entrypoint.
pub fn init(
    alloc: Allocator,
    config: *const configpkg.Config,
    surface: *apprt.Surface,
    renderer_impl: *rendererpkg.Renderer,
    state: *rendererpkg.State,
    app_mailbox: App.Mailbox,
) !Thread {
    // Create our event loop.
    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    // This async handle is used to "wake up" the renderer and force a render.
    var wakeup_h = try xev.Async.init();
    errdefer wakeup_h.deinit();

    // This async handle is used to stop the loop and force the thread to end.
    var stop_h = try xev.Async.init();
    errdefer stop_h.deinit();

    // The primary timer for rendering.
    var render_h = try xev.Timer.init();
    errdefer render_h.deinit();

    // Draw timer, see comments.
    var draw_h = try xev.Timer.init();
    errdefer draw_h.deinit();

    // Draw now async, see comments.
    var draw_now = try xev.Async.init();
    errdefer draw_now.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    return .{
        .alloc = alloc,
        .config = .init(config),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_h = draw_h,
        .draw_now = draw_now,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
        .app_mailbox = app_mailbox,
    };
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_h.deinit();
    self.draw_now.deinit();
    self.cursor_h.deinit();
    self.loop.deinit();

    // Nothing can possibly access the mailbox anymore, destroy it.
    self.mailbox.destroy(self.alloc);
}

/// Perform a full render cycle synchronously from the calling thread.
/// cmux fork: iOS drives frames from a platform display callback. Delete this
/// when upstream exposes a synchronous embedder render tick.
pub fn renderNow(self: *Thread) void {
    self.enterExternalDrainMode();
    _ = self.drainMailbox() catch |err| fallback: {
        log.err("renderNow: error draining mailbox err={}", .{err});
        break :fallback MailboxDrainResult{};
    };

    self.renderer.updateFrame(
        self.state,
        self.effectiveCursorBlinkVisible(),
    ) catch |err| {
        log.warn("renderNow: error updating frame err={}", .{err});
        return;
    };

    self.drawFrame(true);
}

/// Drain the renderer mailbox once, applying every queued message.
///
/// cmux iOS fork: a public seam over the private `drainMailbox` so a producer
/// running on the iOS render serial queue (where `render_now` is the mailbox's
/// only drainer) can flush a full mailbox inline before pushing a state-carrying
/// message that must NOT be dropped (e.g. `.font_grid`, whose handler derefs the
/// old grid). Safe to call from that queue for the same reason `render_now` is:
/// `render_now` already calls `drainMailbox` on this serial queue every frame
/// (see `renderNow`), so this is byte-identical drain behavior and adds no new
/// concurrency. `drainMailbox` and its handlers take no `renderer_state.mutex`,
/// so it cannot self-deadlock against a caller that holds it. Delete when
/// upstream exposes a synchronous embedder render tick.
pub fn drainMailboxNow(self: *Thread) void {
    self.enterExternalDrainMode();
    _ = self.drainMailbox() catch |err| {
        log.err("drainMailboxNow: error draining mailbox err={}", .{err});
        return;
    };
}

fn enterExternalDrainMode(self: *Thread) void {
    if (comptime builtin.os.tag != .ios) return;
    if (!self.external_drain.load(.seq_cst)) {
        self.cursor_blink_epoch_ms = std.time.milliTimestamp();
        self.flags.cursor_blink_visible = true;
        self.external_drain.store(true, .seq_cst);
    }
}

fn externalDrainActive(self: *const Thread) bool {
    if (comptime builtin.os.tag != .ios) return false;
    return self.external_drain.load(.seq_cst);
}

fn resetExternalCursorBlink(self: *Thread) void {
    self.flags.cursor_blink_visible = true;
    self.cursor_blink_epoch_ms = std.time.milliTimestamp();
}

fn effectiveCursorBlinkVisible(self: *Thread) bool {
    if (!self.externalDrainActive()) return self.flags.cursor_blink_visible;
    if (!self.flags.focused) return true;

    const epoch = self.cursor_blink_epoch_ms;
    if (epoch <= 0) return true;

    const now = std.time.milliTimestamp();
    const raw_elapsed = now - epoch;
    const elapsed: u64 = if (raw_elapsed > 0) @intCast(raw_elapsed) else 0;
    const interval = cursorBlinkInterval();
    if (interval == 0) return true;
    return ((elapsed / interval) % 2) == 0;
}

/// The main entrypoint for the thread.
pub fn threadMain(self: *Thread) void {
    // Call child function so we can use errors...
    self.threadMain_() catch |err| {
        // In the future, we should expose this on the thread struct.
        log.warn("error in renderer err={}", .{err});
    };
}

fn threadMain_(self: *Thread) !void {
    defer log.debug("renderer thread exited", .{});

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"renderer".*);
    }

    // Setup our crash metadata
    crash.sentry.thread_state = .{
        .type = .renderer,
        .surface = self.renderer.surface_mailbox.surface,
    };
    defer crash.sentry.thread_state = null;

    // Setup our thread QoS
    self.setQosClass();

    // Run our loop start/end callbacks if the renderer cares.
    const has_loop = @hasDecl(rendererpkg.Renderer, "loopEnter");
    if (has_loop) try self.renderer.loopEnter(self);
    defer if (has_loop) self.renderer.loopExit();

    // Run our thread start/end callbacks. This is important because some
    // renderers have to do per-thread setup. For example, OpenGL has to set
    // some thread-local state since that is how it works.
    try self.renderer.threadEnter(self.surface);
    defer self.renderer.threadExit();

    // Start the async handlers
    self.wakeup.wait(&self.loop, &self.wakeup_c, Thread, self, wakeupCallback);
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);

    // Send an initial wakeup message so that we render right away.
    try self.wakeup.notify();

    // Start blinking the cursor.
    self.cursor_h.run(
        &self.loop,
        &self.cursor_c,
        cursorBlinkInterval(),
        Thread,
        self,
        cursorTimerCallback,
    );

    // Start the draw timer
    self.syncDrawTimer();

    // Run
    log.debug("starting renderer thread", .{});
    defer log.debug("starting renderer thread shutdown", .{});
    _ = try self.loop.run(.until_done);
}

fn setQosClass(self: *const Thread) void {
    // Thread QoS classes are only relevant on macOS.
    if (comptime !builtin.target.os.tag.isDarwin()) return;

    const class: internal_os.macos.QosClass = class: {
        // If we aren't visible (our view is fully occluded) then we
        // always drop our rendering priority down because it's just
        // mostly wasted work.
        //
        // The renderer itself should be doing this as well (for example
        // Metal will stop our DisplayLink) but this also helps with
        // general forced updates and CPU usage i.e. a rebuild cells call.
        if (!self.flags.visible) break :class .utility;

        // If we're not focused, but we're visible, then we set a higher
        // than default priority because framerates still matter but it isn't
        // as important as when we're focused.
        if (!self.flags.focused) break :class .user_initiated;

        // We are focused and visible, we are the definition of user interactive.
        break :class .user_interactive;
    };

    if (internal_os.macos.setQosClass(class)) {
        log.debug("thread QoS class set class={}", .{class});
    } else |err| {
        log.warn("error setting QoS class err={}", .{err});
    }
}

fn syncDrawTimer(self: *Thread) void {
    skip: {
        // If our renderer supports animations and has them, then we
        // can apply draw timer based on custom shader animation configuration.
        if (@hasDecl(rendererpkg.Renderer, "hasAnimations") and
            self.renderer.hasAnimations())
        {
            // If our config says to always animate, we do so.
            switch (self.config.custom_shader_animation) {
                // Always animate
                .always => break :skip,
                // Only when focused
                .true => if (self.flags.focused) break :skip,
                // Never animate
                .false => {},
            }
        }

        // We're skipping the draw timer. Stop it on the next iteration.
        self.draw_active = false;
        return;
    }

    // Set our active state so it knows we're running. We set this before
    // even checking the active state in case we have a pending shutdown.
    self.draw_active = true;

    // If our draw timer is already active, then we don't have to do anything.
    if (self.draw_c.state() == .active) return;

    // Start the timer which loops
    self.draw_h.run(
        &self.loop,
        &self.draw_c,
        DRAW_INTERVAL,
        Thread,
        self,
        drawCallback,
    );
}

/// Drain the mailbox.
fn drainMailbox(self: *Thread) !MailboxDrainResult {
    // There's probably a more elegant way to do this...
    //
    // This is effectively an @autoreleasepool{} block, which we need in
    // order to ensure that autoreleased objects are properly released.
    const pool = if (builtin.os.tag.isDarwin())
        @import("objc").AutoreleasePool.init()
    else
        void;
    defer if (builtin.os.tag.isDarwin()) pool.deinit();

    const external_drain = self.externalDrainActive();
    var visibility = VisibilityDrainState.init(self.flags.visible);

    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),

            .visible => |v| visible: {
                // If our state didn't change we do nothing.
                if (!visibility.apply(v)) break :visible;

                // Set our visible state
                self.flags.visible = v;

                // Visibility affects our QoS class
                self.setQosClass();

                // Note that we're explicitly today not stopping any
                // cursor timers, draw timers, etc. These things have very
                // little resource cost and properly maintaining their active
                // state across different transitions is going to be bug-prone,
                // so its easier to just let them keep firing and have them
                // check the visible state themselves to control their behavior.
            },

            .focus => |v| focus: {
                // If our state didn't change we do nothing.
                if (self.flags.focused == v) break :focus;

                // Set our state
                self.flags.focused = v;

                // Focus affects our QoS class
                self.setQosClass();

                // Set it on the renderer
                try self.renderer.setFocus(v);

                if (external_drain) {
                    if (v) self.resetExternalCursorBlink();
                    break :focus;
                }

                // We always resync our draw timer (may disable it)
                self.syncDrawTimer();

                if (!v) {
                    // If we're not focused, then we stop the cursor blink
                    if (self.cursor_c.state() == .active and
                        self.cursor_c_cancel.state() == .dead)
                    {
                        self.cursor_h.cancel(
                            &self.loop,
                            &self.cursor_c,
                            &self.cursor_c_cancel,
                            void,
                            null,
                            cursorCancelCallback,
                        );
                    }
                } else {
                    // If we're focused, we immediately show the cursor again
                    // and then restart the timer.
                    if (self.cursor_c.state() != .active) {
                        self.flags.cursor_blink_visible = true;
                        self.cursor_h.run(
                            &self.loop,
                            &self.cursor_c,
                            cursorBlinkInterval(),
                            Thread,
                            self,
                            cursorTimerCallback,
                        );
                    }
                }
            },

            .reset_cursor_blink => {
                self.flags.cursor_blink_visible = true;
                if (external_drain) {
                    self.resetExternalCursorBlink();
                    continue;
                }
                if (self.cursor_c.state() == .active) {
                    self.cursor_h.reset(
                        &self.loop,
                        &self.cursor_c,
                        &self.cursor_c_cancel,
                        cursorBlinkInterval(),
                        Thread,
                        self,
                        cursorTimerCallback,
                    );
                }
            },

            .font_grid => |grid| {
                self.renderer.setFontGrid(grid.grid);
                grid.set.deref(grid.old_key);
            },

            .resize => |v| self.renderer.setScreenSize(v),

            .change_config => |config| {
                defer config.alloc.destroy(config.thread);
                defer config.alloc.destroy(config.impl);
                try self.changeConfig(config.thread);
                try self.renderer.changeConfig(config.impl);

                // Stop and start the draw timer to capture the new
                // hasAnimations value.
                if (!external_drain) self.syncDrawTimer();
            },

            .search_viewport_matches => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_matches) |*m| m.arena.deinit();
                self.renderer.search_matches = v;
                self.renderer.search_matches_dirty = true;
            },

            .search_selected_match => |v| {
                // Note we don't free the new value because we expect our
                // allocators to match.
                if (self.renderer.search_selected_match) |*m| m.arena.deinit();
                self.renderer.search_selected_match = v;
                self.renderer.search_matches_dirty = true;
            },

            .inspector => |v| {
                self.flags.has_inspector = v;
            },

            .macos_display_id => |v| {
                if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
                    try self.renderer.setMacOSDisplayID(v);
                }
            },

            // cmux fork: release/recreate the renderer's GPU resources (swap
            // chain / IOSurface) without freeing the surface. Safe here because
            // this runs on the renderer thread (so it never races a draw), the
            // surface is occluded when this is sent (macOS `drawFrame` early-
            // returns on `!flags.visible`), and both calls take `draw_mutex`.
            .display_realized => |v| {
                if (v) {
                    try self.renderer.displayRealized();
                } else {
                    self.renderer.displayUnrealized();
                }
            },
        }
    }

    if (external_drain) return .{};

    // Hidden wakeups leave terminal dirty flags untouched. Rebuild exactly
    // once from their union before making the renderer visible again, then
    // present immediately. A full-redraw dirty bit remains authoritative
    // inside RenderState.update.
    return applyRendererVisibilityTransition(
        self,
        visibility.rendererTransition(),
    );
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    self.config = config.*;
}

fn updateAndDrawFrame(self: *Thread) bool {
    self.renderer.updateFrame(
        self.state,
        self.flags.cursor_blink_visible,
    ) catch |err| {
        log.warn("error rendering err={}", .{err});
        return false;
    };
    self.drawFrame(false);
    return true;
}

fn setRendererVisible(self: *Thread, visible: bool) void {
    self.renderer.setVisible(visible);
}

fn renderWakeFrame(self: *Thread) void {
    _ = renderCallback(self, undefined, undefined, {});
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) void {
    // If we're invisible, we do not draw.
    //
    // cmux iOS fork: skip this early-return on iOS. The iOS embedder owns
    // occlusion on the Swift side (it stops dispatching `render_now` while the
    // surface is occluded/backgrounded via `renderingSuspended` + the dispatch
    // gate, and resumes on foreground), so a `render_now` that actually reaches
    // here is always meant to draw. Honoring `flags.visible` here is unsafe on
    // iOS because the `.visible` mailbox message is delivered non-blocking
    // (instant, can drop on a full mailbox under load — see `occlusionCallback`):
    // a dropped `.visible=true` would latch `flags.visible=false` and make every
    // `render_now` no-op, permanently blanking the surface. macOS keeps the
    // proven behavior (its renderer thread drives frames off `flags.visible`).
    if (comptime builtin.os.tag != .ios) {
        if (!self.flags.visible) return;
    }

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return;

    if (must_draw_from_app_thread) {
        _ = self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        );
    } else {
        self.renderer.drawFrame(false) catch |err| switch (err) {
            // cmux iOS fork: a bounded frame-state acquire timed out under GPU
            // backpressure; the frame is SKIPPED and the display link
            // re-requests on the next tick. Occasional timeouts = a transient
            // completion backlog that the bounded wait bridged (healthy).
            // Continuous timeouts = a true permanent GPU completion stall (the
            // surface-rebuild escalation, tracked separately, is then needed).
            // Log greppably but throttled so a storm doesn't flood the log.
            error.Timeout => {
                self.frame_acquire_timeouts +%= 1;
                if (self.frame_acquire_timeouts % 30 == 1) {
                    log.warn(
                        "render.frame.acquire.timeout count={}",
                        .{self.frame_acquire_timeouts},
                    );
                }
            },
            else => log.warn("error drawing err={}", .{err}),
        };
    }
}

fn wakeupCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in wakeup err={}", .{err});
        return .rearm;
    };

    const t = self_.?;
    if (t.externalDrainActive()) return .rearm;

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const drain_result = t.drainMailbox() catch |err| fallback: {
        log.err("error draining mailbox err={}", .{err});
        break :fallback MailboxDrainResult{};
    };

    // Render immediately unless a successful visibility regain already did.
    renderAfterMailboxDrain(t, drain_result);

    // The below is not used anymore but if we ever want to introduce
    // a configuration to introduce a delay to coalesce renders, we can
    // use this.
    //
    // // If the timer is already active then we don't have to do anything.
    // if (t.render_c.state() == .active) return .rearm;
    //
    // // Timer is not active, let's start it
    // t.render_h.run(
    //     &t.loop,
    //     &t.render_c,
    //     10,
    //     Thread,
    //     t,
    //     renderCallback,
    // );

    return .rearm;
}

fn drawNowCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in draw now err={}", .{err});
        return .rearm;
    };

    // Draw immediately
    const t = self_.?;
    if (t.externalDrainActive()) return .rearm;
    t.drawFrame(true);

    return .rearm;
}

fn drawCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    if (t.externalDrainActive()) {
        t.draw_active = false;
        return .disarm;
    }

    // Draw
    t.drawFrame(false);

    // Only continue if we're still active
    if (t.draw_active) {
        t.draw_h.run(&t.loop, &t.draw_c, DRAW_INTERVAL, Thread, t, drawCallback);
    }

    return .disarm;
}

fn renderCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    if (t.externalDrainActive()) return .disarm;

    // Preserve terminal dirty state while hidden. The visibility regain path
    // consumes the accumulated row union in one update before presenting.
    if (!t.flags.visible) return .disarm;

    // Update our frame data
    t.renderer.updateFrame(
        t.state,
        t.flags.cursor_blink_visible,
    ) catch |err|
        log.warn("error rendering err={}", .{err});

    // Draw
    t.drawFrame(false);

    return .disarm;
}

test "visibility drain coalesces rapid hide show ordering" {
    var state = VisibilityDrainState.init(true);
    try std.testing.expect(state.apply(false));
    try std.testing.expect(state.apply(true));
    try std.testing.expect(state.apply(false));
    try std.testing.expectEqual(false, state.rendererTransition().?);

    var canceled = VisibilityDrainState.init(true);
    try std.testing.expect(canceled.apply(false));
    try std.testing.expect(canceled.apply(true));
    try std.testing.expectEqual(null, canceled.rendererTransition());
}

test "visibility regain renders exactly once per wake" {
    const CountingRenderer = struct {
        updates: usize = 0,
        draws: usize = 0,
        visibility_changes: usize = 0,
        visible: bool = false,
        failed_updates_remaining: usize = 0,

        fn updateAndDrawFrame(self: *@This()) bool {
            self.updates += 1;
            if (self.failed_updates_remaining > 0) {
                self.failed_updates_remaining -= 1;
                return false;
            }
            self.draws += 1;
            return true;
        }

        fn setRendererVisible(self: *@This(), visible: bool) void {
            self.visibility_changes += 1;
            self.visible = visible;
        }

        fn renderWakeFrame(self: *@This()) void {
            _ = self.updateAndDrawFrame();
        }
    };

    var reveal_state = VisibilityDrainState.init(false);
    try std.testing.expect(reveal_state.apply(true));
    var reveal: CountingRenderer = .{};
    const reveal_result = applyRendererVisibilityTransition(
        &reveal,
        reveal_state.rendererTransition(),
    );
    renderAfterMailboxDrain(&reveal, reveal_result);
    try std.testing.expectEqual(1, reveal.updates);
    try std.testing.expectEqual(1, reveal.draws);
    try std.testing.expectEqual(1, reveal.visibility_changes);
    try std.testing.expect(reveal.visible);

    // A wake without a visibility transition still renders normally.
    var ordinary: CountingRenderer = .{};
    const ordinary_result = applyRendererVisibilityTransition(&ordinary, null);
    renderAfterMailboxDrain(&ordinary, ordinary_result);
    try std.testing.expectEqual(1, ordinary.updates);
    try std.testing.expectEqual(1, ordinary.draws);
    try std.testing.expectEqual(0, ordinary.visibility_changes);

    // A failed reveal update does not suppress the normal wake retry.
    var retry: CountingRenderer = .{ .failed_updates_remaining = 1 };
    const retry_result = applyRendererVisibilityTransition(&retry, true);
    renderAfterMailboxDrain(&retry, retry_result);
    try std.testing.expectEqual(2, retry.updates);
    try std.testing.expectEqual(1, retry.draws);
    try std.testing.expectEqual(1, retry.visibility_changes);
    try std.testing.expect(retry.visible);
}

fn cursorTimerCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch |err| switch (err) {
        // This is sent when our timer is canceled. That's fine.
        error.Canceled => return .disarm,

        else => {
            log.warn("error in cursor timer callback err={}", .{err});
            unreachable;
        },
    };

    const t: *Thread = self_ orelse {
        // This shouldn't happen so we log it.
        log.warn("render callback fired without data set", .{});
        return .disarm;
    };
    if (t.externalDrainActive()) return .disarm;

    t.flags.cursor_blink_visible = !t.flags.cursor_blink_visible;
    t.wakeup.notify() catch {};

    t.cursor_h.run(
        &t.loop,
        &t.cursor_c,
        cursorBlinkInterval(),
        Thread,
        t,
        cursorTimerCallback,
    );
    return .disarm;
}

fn cursorCancelCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.CancelError!void,
) xev.CallbackAction {
    // This makes it easier to work across platforms where different platforms
    // support different sets of errors, so we just unify it.
    const CancelError = xev.Timer.CancelError || error{
        Canceled,
        NotFound,
        Unexpected,
    };

    _ = r catch |err| switch (@as(CancelError, @errorCast(err))) {
        error.Canceled => {}, // success
        error.NotFound => {}, // completed before it could cancel
        else => {
            log.warn("error in cursor cancel callback err={}", .{err});
            unreachable;
        },
    };

    return .disarm;
}

// fn prepFrameCallback(h: *libuv.Prepare) void {
//     _ = h;
//
//     tracy.frameMark();
// }

fn stopCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch unreachable;
    self_.?.loop.stop();
    return .disarm;
}

/// Returns the interval for the blinking cursor in milliseconds.
fn cursorBlinkInterval() u64 {
    if (std.valgrind.runningOnValgrind() > 0) {
        // If we're running under Valgrind, the cursor blink adds enough
        // churn that it makes some stalls annoying unless you're on a
        // super powerful computer, so we delay it.
        //
        // This is a hack, we should change some of our cursor timer
        // logic to be more efficient:
        // https://github.com/ghostty-org/ghostty/issues/8003
        return CURSOR_BLINK_INTERVAL * 5;
    }

    return CURSOR_BLINK_INTERVAL;
}
