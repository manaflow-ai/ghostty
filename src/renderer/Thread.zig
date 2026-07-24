//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("../global.zig").xev;
const crash = @import("../crash/main.zig");
const internal_os = @import("../os/main.zig");
const rendererpkg = @import("../renderer.zig");
const instrumentationpkg = @import("instrumentation.zig");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const terminalpkg = @import("../terminal/main.zig");
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

/// Latest-value publication for surface lifecycle state. These values are
/// idempotent and have no owned payloads, so producers can replace an unread
/// request instead of waiting for space in the ordered renderer mailbox.
///
/// Each property has its own atomic slot. Zero means no pending request;
/// booleans use one/ two for false/true, and display ids are offset by one so
/// every u32 value remains representable. A producer that races `take` either
/// lands in the returned update or remains pending for the next renderer wake.
const SurfaceStateRequests = struct {
    const Update = struct {
        visible: ?bool = null,
        focused: ?bool = null,
        display_id: ?u32 = null,
    };

    visible: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    focused: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    display_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn publishVisible(self: *SurfaceStateRequests, value: bool) void {
        self.visible.store(if (value) 2 else 1, .release);
    }

    fn publishFocused(self: *SurfaceStateRequests, value: bool) void {
        self.focused.store(if (value) 2 else 1, .release);
    }

    fn publishDisplayID(self: *SurfaceStateRequests, value: u32) void {
        self.display_id.store(@as(u64, value) + 1, .release);
    }

    fn take(self: *SurfaceStateRequests) Update {
        return .{
            .visible = decodeBool(self.visible.swap(0, .acq_rel)),
            .focused = decodeBool(self.focused.swap(0, .acq_rel)),
            .display_id = decodeDisplayID(self.display_id.swap(0, .acq_rel)),
        };
    }

    fn decodeBool(value: u8) ?bool {
        return switch (value) {
            0 => null,
            1 => false,
            2 => true,
            else => unreachable,
        };
    }

    fn decodeDisplayID(value: u64) ?u32 {
        return if (value == 0) null else @intCast(value - 1);
    }
};

const DrawFrameResult = enum {
    skipped_invisible,
    deferred_to_vsync,
    app_mailbox_full,
    backend_failed,
    submitted,
};

const VisibilityRegainAttempt = enum {
    not_pending,
    failed,
    pending,
    submitted,
};

/// A recoverable app-thread submission failure retains the already-updated
/// frame. Capacity notifications retry only the draw submission, never the
/// expensive terminal rebuild. A generation makes stale notifications no-op.
const VisibilityRegainState = struct {
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    next_generation: u64 = 0,

    fn cancel(self: *VisibilityRegainState) void {
        self.pending.store(false, .release);
    }

    fn isPending(self: *const VisibilityRegainState) bool {
        return self.pending.load(.acquire);
    }

    fn pendingGeneration(self: *const VisibilityRegainState) ?u64 {
        if (!self.pending.load(.acquire)) return null;
        const generation = self.generation.load(.acquire);
        if (!self.pending.load(.acquire)) return null;
        return generation;
    }

    /// Start or refresh a reveal frame for a real renderer wake. The update
    /// runs once for this generation; capacity retries call `retrySubmission`
    /// directly and therefore never rebuild it again.
    fn updateAndSubmit(
        self: *VisibilityRegainState,
        context: anytype,
    ) VisibilityRegainAttempt {
        self.cancel();
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        self.generation.store(self.next_generation, .release);

        if (!context.updateVisibilityRegainFrame()) return .failed;
        self.pending.store(true, .release);
        return self.retrySubmission(context, self.next_generation);
    }

    fn retrySubmission(
        self: *VisibilityRegainState,
        context: anytype,
        expected_generation: u64,
    ) VisibilityRegainAttempt {
        const generation = self.pendingGeneration() orelse return .not_pending;
        if (generation != expected_generation) return .not_pending;

        return switch (context.drawForcedVisibilityRegainFrame()) {
            .submitted => submitted: {
                self.cancel();
                break :submitted .submitted;
            },
            // This is the only failure with a concrete readiness signal: the
            // failed push wakes the app, and its mailbox drain reports capacity.
            .app_mailbox_full => .pending,
            // Backend errors have no general readiness contract. Preserve the
            // prior normal-wake behavior instead of latching a retry loop.
            .backend_failed,
            .skipped_invisible,
            .deferred_to_vsync,
            => failed: {
                self.cancel();
                break :failed .failed;
            },
        };
    }
};

const MailboxDrainResult = struct {
    visibility_regain_started: bool = false,
    rendered_visibility_regain: bool = false,
    mailbox_pending: bool = false,
};

/// Process ordinary renderer messages and report whether work remains.
///
/// The context seam keeps the wake batching policy deterministic in tests
/// without constructing a platform renderer.
fn drainMessageBatch(context: anytype) !bool {
    const limit = context.pendingMessageCount();
    for (0..limit) |_| {
        const message = context.popMessage() orelse break;
        try context.handleMessage(message);
    }
    return context.pendingMessageCount() > 0;
}

/// Apply the one renderer visibility transition left after mailbox
/// coalescing. The context seam keeps the wake behavior directly testable
/// without constructing a platform renderer.
fn applyRendererVisibilityTransition(
    context: anytype,
    regain: *VisibilityRegainState,
    visible: ?bool,
) MailboxDrainResult {
    const final_visible = visible orelse return .{};
    var result: MailboxDrainResult = .{};
    if (final_visible) {
        result.visibility_regain_started = true;
        result.rendered_visibility_regain =
            regain.updateAndSubmit(context) == .submitted;
    } else {
        regain.cancel();
    }
    context.setRendererVisible(final_visible);
    return result;
}

/// A successful visibility-regain render already satisfies this wake. Other
/// wakes retain the normal render callback, including a retry after failure.
fn renderAfterMailboxDrain(
    context: anytype,
    regain: *VisibilityRegainState,
    result: MailboxDrainResult,
) void {
    // A later fallible mailbox handler can abort the drain after `.visible`
    // changed the thread flags but before the coalesced renderer transition.
    // Commit that transition through the same retained reveal path as a
    // successful drain before deciding whether this wake still needs a render.
    const recovery = applyRendererVisibilityTransition(
        context,
        regain,
        context.pendingRendererVisibilityTransition(),
    );
    const effective_result: MailboxDrainResult = .{
        .visibility_regain_started = result.visibility_regain_started or
            recovery.visibility_regain_started,
        .rendered_visibility_regain = result.rendered_visibility_regain or
            recovery.rendered_visibility_regain,
    };

    if (effective_result.rendered_visibility_regain) return;

    if (effective_result.visibility_regain_started) {
        if (regain.pendingGeneration()) |generation| {
            // Preserve one immediate app-queue retry. If the same queue is
            // still full, its eventual drain is the next causal retry event.
            _ = regain.retrySubmission(context, generation);
            return;
        }
        context.renderWakeFrame();
        return;
    }

    if (regain.isPending()) {
        // A normal renderer wake means terminal/cursor state may have changed
        // since the retained frame, so create exactly one fresh generation.
        _ = regain.updateAndSubmit(context);
        return;
    }

    context.renderWakeFrame();
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

/// Set after the stop watcher is armed. Embedded callers can destroy a
/// surface immediately after creation, so Surface.init must not return while
/// a stop notification could still be lost during thread startup.
started: std.Thread.ResetEvent = .{},

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

/// Dedicated, coalescing retry signal for a retained visibility submission.
/// Keeping this separate from `draw_now` makes stale capacity notifications
/// no-op instead of turning them into duplicate forced draws.
visibility_retry: xev.Async,
visibility_retry_c: xev.Completion = .{},
visibility_retry_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

/// The timer used for cursor blinking
cursor_h: xev.Timer,
cursor_c: xev.Completion = .{},
cursor_c_cancel: xev.Completion = .{},

/// Incremental scrollback compression scheduling.
compression: Compression = undefined,

/// Last selection activity delivered to the apprt. This is renderer-owned so
/// callbacks can run after the terminal mutex is released.
selection_activity: terminalpkg.Terminal.SelectionActivity = 0,

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

/// Optional, content-free renderer activity callback supplied by an embedder.
instrumentation: instrumentationpkg.Instrumentation,

/// Retained until a visibility-regain frame is actually submitted.
visibility_regain: VisibilityRegainState = .{},

/// Coalesced surface state published without entering the bounded mailbox.
surface_state_requests: SurfaceStateRequests = .{},

/// Last visibility state forwarded to the renderer. Renderer-thread owned.
/// This can temporarily differ from `flags.visible` only when a later
/// mailbox handler aborts a drain before its coalesced transition commits.
renderer_visible: bool = true,

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
    scrollback_compression: bool,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .custom_shader_animation = config.@"custom-shader-animation",
            .scrollback_compression = config.@"scrollback-compression",
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
    instrumentation: instrumentationpkg.Instrumentation,
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

    // Visibility submission retry, signaled only by app-mailbox capacity.
    var visibility_retry = try xev.Async.init();
    errdefer visibility_retry.deinit();

    // Setup a timer for blinking the cursor
    var cursor_timer = try xev.Timer.init();
    errdefer cursor_timer.deinit();

    // The mailbox for messaging this thread
    var mailbox = try Mailbox.create(alloc);
    errdefer mailbox.destroy(alloc);

    var result: Thread = .{
        .alloc = alloc,
        .config = .init(config),
        .loop = loop,
        .wakeup = wakeup_h,
        .stop = stop_h,
        .render_h = render_h,
        .draw_h = draw_h,
        .draw_now = draw_now,
        .visibility_retry = visibility_retry,
        .cursor_h = cursor_timer,
        .surface = surface,
        .renderer = renderer_impl,
        .state = state,
        .mailbox = mailbox,
        .app_mailbox = app_mailbox,
        .instrumentation = instrumentation,
    };

    // Only enable compression if we have it enabled... save some
    // minor resources.
    if (comptime terminalpkg.compression_enabled) {
        result.compression = try .init();
    }

    return result;
}

/// Clean up the thread. This is only safe to call once the thread
/// completes executing; the caller must join prior to this.
pub fn deinit(self: *Thread) void {
    self.stop.deinit();
    self.wakeup.deinit();
    self.render_h.deinit();
    self.draw_h.deinit();
    self.draw_now.deinit();
    self.visibility_retry.deinit();
    self.cursor_h.deinit();
    if (comptime terminalpkg.compression_enabled)
        self.compression.deinit();
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

    self.notifySelectionChanged();

    self.updateFrame(self.effectiveCursorBlinkVisible()) catch |err| {
        log.warn("renderNow: error updating frame err={}", .{err});
        return;
    };

    _ = self.drawFrame(true);
}

/// Force a new frame and attach an exact platform-presentation completion.
/// iOS keeps Metal completion asynchronous even though `sync=true` is used to
/// force allocation of a fresh swap-chain target.
pub fn renderNowWithPresentation(
    self: *Thread,
    presentation: rendererpkg.FramePresentation,
) void {
    self.enterExternalDrainMode();
    _ = self.drainMailbox() catch |err| fallback: {
        log.err("renderNowWithPresentation: error draining mailbox err={}", .{err});
        break :fallback MailboxDrainResult{};
    };

    self.notifySelectionChanged();

    self.updateFrame(self.effectiveCursorBlinkVisible()) catch |err| {
        log.warn("renderNowWithPresentation: error updating frame err={}", .{err});
        return;
    };

    return finishRenderNowWithPresentation(
        self.renderer,
        &self.instrumentation,
        presentation,
    );
}

/// Finish a forced draw before delivering a synchronous backend presentation.
/// Delivery is the final operation because it may reentrantly destroy Thread.
fn finishRenderNowWithPresentation(
    renderer: anytype,
    instrumentation: anytype,
    presentation: rendererpkg.FramePresentation,
) void {
    instrumentation.emit(.draw_frame_begin);
    const result = renderer.drawFrameWithPresentation(true, presentation);
    instrumentation.emit(.draw_frame_end);

    const completed = result catch |err| {
        switch (err) {
            error.Timeout => log.warn("renderNowWithPresentation: frame acquire timeout", .{}),
            else => log.warn("renderNowWithPresentation: error drawing err={}", .{err}),
        }
        return;
    };

    const value = completed orelse return;
    value.deliver();
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

/// Publish latest-value surface lifecycle state without waiting for renderer
/// mailbox capacity. Callers must notify `wakeup` after publishing.
pub fn publishVisible(self: *Thread, value: bool) void {
    self.surface_state_requests.publishVisible(value);
}

pub fn publishFocused(self: *Thread, value: bool) void {
    self.surface_state_requests.publishFocused(value);
}

pub fn publishDisplayID(self: *Thread, value: u32) void {
    self.surface_state_requests.publishDisplayID(value);
}

/// The app thread calls this after draining its mailbox. A failed
/// `redraw_surface` push wakes that thread even though no message was queued,
/// so mailbox capacity becoming available is the readiness signal for one
/// retained reveal retry.
pub fn appMailboxDrained(self: *Thread) void {
    const generation = self.visibility_regain.pendingGeneration() orelse return;
    self.visibility_retry_generation.store(generation, .release);
    self.visibility_retry.notify() catch |err| {
        log.warn("failed to notify visibility-regain retry err={}", .{err});
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

    // Arm stop before any fallible renderer setup. Surface.init waits for
    // this signal in embedded builds, making an immediate free deterministic.
    self.stop.wait(&self.loop, &self.stop_c, Thread, self, stopCallback);
    self.started.set();

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
    self.draw_now.wait(&self.loop, &self.draw_now_c, Thread, self, drawNowCallback);
    self.visibility_retry.wait(
        &self.loop,
        &self.visibility_retry_c,
        Thread,
        self,
        visibilityRetryCallback,
    );

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

    var message_drain: MailboxMessageDrainContext = .{
        .thread = self,
        .visibility = &visibility,
        .external_drain = external_drain,
    };
    const mailbox_pending = try drainMessageBatch(&message_drain);

    // Lifecycle state is latest-value rather than ordered work. Apply it after
    // the ordinary mailbox so an older compatibility message cannot overwrite
    // a newer request. A publication racing this take remains pending and its
    // own wakeup drives the next drain.
    const surface_state = self.surface_state_requests.take();
    if (surface_state.visible) |value| self.applyVisible(&visibility, value);
    if (surface_state.focused) |value| try self.applyFocused(value, external_drain);
    if (surface_state.display_id) |value| try self.applyDisplayID(value);

    if (external_drain) return .{ .mailbox_pending = mailbox_pending };

    // Hidden wakeups leave terminal dirty flags untouched. Rebuild exactly
    // once from their union before making the renderer visible again, then
    // present immediately. A full-redraw dirty bit remains authoritative
    // inside RenderState.update.
    var result = applyRendererVisibilityTransition(
        self,
        &self.visibility_regain,
        visibility.rendererTransition(),
    );
    result.mailbox_pending = mailbox_pending;
    return result;
}

const MailboxMessageDrainContext = struct {
    thread: *Thread,
    visibility: *VisibilityDrainState,
    external_drain: bool,

    fn pendingMessageCount(self: *@This()) Mailbox.Size {
        return self.thread.mailbox.count();
    }

    fn popMessage(self: *@This()) ?rendererpkg.Message {
        return self.thread.mailbox.pop();
    }

    fn handleMessage(
        self: *@This(),
        message: rendererpkg.Message,
    ) !void {
        try self.thread.handleMailboxMessage(
            message,
            self.visibility,
            self.external_drain,
        );
    }
};

fn handleMailboxMessage(
    self: *Thread,
    message: rendererpkg.Message,
    visibility: *VisibilityDrainState,
    external_drain: bool,
) !void {
    log.debug("mailbox message={}", .{message});
    switch (message) {
        .crash => @panic("crash request, crashing intentionally"),

        .visible => |v| self.applyVisible(visibility, v),

        .focus => |v| try self.applyFocused(v, external_drain),

        .reset_cursor_blink => {
            self.flags.cursor_blink_visible = true;
            if (external_drain) {
                self.resetExternalCursorBlink();
                return;
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

        .macos_display_id => |v| try self.applyDisplayID(v),

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

fn applyVisible(
    self: *Thread,
    visibility: *VisibilityDrainState,
    value: bool,
) void {
    if (!visibility.apply(value)) return;
    self.flags.visible = value;
    self.setQosClass();

    // Timers are intentionally left armed across visibility changes. Their
    // callbacks already consult this renderer-owned flag.
}

fn applyFocused(self: *Thread, value: bool, external_drain: bool) !void {
    if (self.flags.focused == value) return;
    self.flags.focused = value;
    self.setQosClass();
    try self.renderer.setFocus(value);

    if (external_drain) {
        if (value) self.resetExternalCursorBlink();
        return;
    }

    self.syncDrawTimer();
    if (!value) {
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
        return;
    }

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

fn applyDisplayID(self: *Thread, value: u32) !void {
    if (@hasDecl(rendererpkg.Renderer, "setMacOSDisplayID")) {
        try self.renderer.setMacOSDisplayID(value);
    }
}

fn changeConfig(self: *Thread, config: *const DerivedConfig) !void {
    // A newly enabled scheduler must reconsider existing history even when no
    // terminal activity occurred while compression was disabled.
    if (comptime terminalpkg.compression_enabled) {
        if (!self.config.scrollback_compression and
            config.scrollback_compression)
        {
            self.compression.activity = null;
        }
    }

    self.config = config.*;
}

fn updateVisibilityRegainFrame(self: *Thread) bool {
    self.updateFrame(self.flags.cursor_blink_visible) catch |err| {
        log.warn("error rendering err={}", .{err});
        return false;
    };
    return true;
}

fn drawForcedVisibilityRegainFrame(self: *Thread) DrawFrameResult {
    return self.drawFrame(true);
}

fn updateFrame(self: *Thread, cursor_blink_visible: bool) !void {
    self.instrumentation.emit(.update_frame_begin);
    defer self.instrumentation.emit(.update_frame_end);
    try self.renderer.updateFrame(self.state, cursor_blink_visible);
}

fn setRendererVisible(self: *Thread, visible: bool) void {
    self.renderer.setVisible(visible);
    self.renderer_visible = visible;
}

fn pendingRendererVisibilityTransition(self: *Thread) ?bool {
    if (self.renderer_visible == self.flags.visible) return null;
    return self.flags.visible;
}

fn renderWakeFrame(self: *Thread) void {
    _ = renderCallback(self, undefined, undefined, {});
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) DrawFrameResult {
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
        if (!self.flags.visible) return .skipped_invisible;
    }

    // If the renderer is managing a vsync on its own, we only draw
    // when we're forced to via `now`.
    if (!now and self.renderer.hasVsync()) return .deferred_to_vsync;

    if (must_draw_from_app_thread) {
        const pushed = self.app_mailbox.push(
            .{ .redraw_surface = self.surface },
            .{ .instant = {} },
        );
        if (pushed == 0) return .app_mailbox_full;

        // The app-thread runtime owns the actual backend call. Record only an
        // accepted submission, never a rejected nonblocking mailbox push.
        self.instrumentation.emit(.draw_frame_begin);
        self.instrumentation.emit(.draw_frame_end);
        return .submitted;
    } else {
        // Preflight skips above emit nothing. Once the backend is entered, the
        // pair measures that real draw invocation, including failure cleanup.
        self.instrumentation.emit(.draw_frame_begin);
        defer self.instrumentation.emit(.draw_frame_end);

        self.renderer.drawFrame(false) catch |err| {
            switch (err) {
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
            }
            return .backend_failed;
        };
        return .submitted;
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
    const regain_was_pending = t.visibility_regain.isPending();

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const drain_result = t.drainMailbox() catch |err| fallback: {
        log.err("error draining mailbox err={}", .{err});
        break :fallback MailboxDrainResult{
            .mailbox_pending = t.mailbox.count() > 0,
        };
    };

    // Render immediately unless a successful visibility regain already did.
    renderAfterMailboxDrain(t, &t.visibility_regain, drain_result);
    if (regain_was_pending and !t.visibility_regain.isPending()) {
        t.syncDrawTimer();
    }

    // A producer can refill the queue while this wake consumes its initial
    // snapshot. Render that snapshot before explicitly scheduling the next
    // batch so continuous output cannot starve lifecycle state or frames.
    if (drain_result.mailbox_pending) {
        t.wakeup.notify() catch |err| {
            log.warn("error scheduling pending renderer mailbox err={}", .{err});
        };
    }

    // PageList mutations maintain their own compression dirty state. Checking
    // it here covers output, resize, and viewport scrolling uniformly.
    t.compression.wake(t);

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

    // Draw immediately. App-thread submission recovery has its own async, so
    // this remains a pure display-link draw and cannot consume stale retries.
    const t = self_.?;
    if (t.externalDrainActive()) return .rearm;
    if (t.visibility_regain.isPending()) return .rearm;
    _ = t.drawFrame(true);

    return .rearm;
}

fn visibilityRetryCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch |err| {
        log.err("error in visibility-regain retry err={}", .{err});
        return .rearm;
    };

    const t = self_.?;
    if (t.externalDrainActive()) return .rearm;
    const generation = t.visibility_retry_generation.load(.acquire);
    if (t.visibility_regain.retrySubmission(t, generation) == .submitted) {
        t.syncDrawTimer();
    }
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

    // A retained app-thread submission waits for actual mailbox capacity.
    // Stop the animation timer rather than polling the pending atomic at 120Hz;
    // the successful capacity callback resynchronizes it.
    if (t.visibility_regain.isPending()) {
        t.draw_active = false;
        return .disarm;
    }
    _ = t.drawFrame(false);

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

    // Selection activity is a lock-free terminal-wide epoch, so hidden
    // surfaces can keep accessibility state current without rebuilding.
    t.notifySelectionChanged();

    // Preserve terminal dirty state while hidden. The visibility regain path
    // consumes the accumulated row union in one update before presenting.
    if (!t.flags.visible) return .disarm;

    // Update our frame data
    t.updateFrame(t.flags.cursor_blink_visible) catch |err|
        log.warn("error rendering err={}", .{err});

    // Draw
    _ = t.drawFrame(false);

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

test "renderer mailbox wake excludes messages added while draining" {
    const Context = struct {
        pending: usize = 1,
        handled: usize = 0,

        fn pendingMessageCount(self: *@This()) usize {
            return self.pending;
        }

        fn popMessage(self: *@This()) ?u8 {
            if (self.pending == 0) return null;
            self.pending -= 1;
            return 1;
        }

        fn handleMessage(self: *@This(), _: u8) !void {
            self.handled += 1;
            if (self.handled < 4) self.pending += 1;
        }
    };

    var context: Context = .{};
    try std.testing.expect(try drainMessageBatch(&context));
    try std.testing.expectEqual(@as(usize, 1), context.handled);
    try std.testing.expectEqual(@as(usize, 1), context.pending);
}

test "surface lifecycle state bypasses a full renderer mailbox and keeps latest values" {
    const mailbox = try Mailbox.create(std.testing.allocator);
    defer mailbox.destroy(std.testing.allocator);

    for (0..64) |_| {
        try std.testing.expect(mailbox.push(
            .{ .visible = false },
            .{ .instant = {} },
        ) != 0);
    }
    try std.testing.expectEqual(
        @as(Mailbox.Size, 0),
        mailbox.push(.{ .visible = false }, .{ .instant = {} }),
    );

    var state: SurfaceStateRequests = .{};
    state.publishVisible(false);
    state.publishVisible(true);
    state.publishFocused(false);
    state.publishDisplayID(7);
    state.publishDisplayID(42);

    const update = state.take();
    try std.testing.expectEqual(true, update.visible);
    try std.testing.expectEqual(false, update.focused);
    try std.testing.expectEqual(@as(u32, 42), update.display_id);
    try std.testing.expectEqual(
        @as(Mailbox.Size, 0),
        mailbox.push(.{ .visible = false }, .{ .instant = {} }),
    );
}

test "synchronous presentation is delivered after thread draw cleanup" {
    const Event = enum { begin, renderer_cleanup, end, callback };
    const State = struct {
        events: [4]Event = undefined,
        len: usize = 0,
        owner_alive: bool = true,
        owner_access_after_callback: bool = false,

        fn append(self: *@This(), event: Event) void {
            self.events[self.len] = event;
            self.len += 1;
        }

        fn presented(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(.callback);
            // Models a reentrant ghostty_surface_free destroying Thread.
            self.owner_alive = false;
        }
    };
    const MockInstrumentation = struct {
        state: *State,

        fn emit(
            self: *const @This(),
            event: instrumentationpkg.Event,
        ) void {
            if (!self.state.owner_alive) {
                self.state.owner_access_after_callback = true;
            }
            self.state.append(switch (event) {
                .draw_frame_begin => .begin,
                .draw_frame_end => .end,
                else => unreachable,
            });
        }
    };
    const MockRenderer = struct {
        state: *State,

        fn drawFrameWithPresentation(
            self: *@This(),
            _: bool,
            presentation: rendererpkg.FramePresentation,
        ) anyerror!?rendererpkg.FramePresentation {
            // Models generic renderer defers completing before ownership is
            // returned to Thread.
            self.state.append(.renderer_cleanup);
            return presentation;
        }
    };
    const Harness = struct {
        fn run(
            renderer: *MockRenderer,
            instrumentation: *const MockInstrumentation,
            presentation: rendererpkg.FramePresentation,
        ) void {
            if (@hasDecl(Thread, "finishRenderNowWithPresentation")) {
                return Thread.finishRenderNowWithPresentation(
                    renderer,
                    instrumentation,
                    presentation,
                );
            }

            // Exercise the pre-fix ownership order. The generic renderer
            // delivered before returning, then Thread ran its end defer.
            instrumentation.emit(.draw_frame_begin);
            const completed = renderer.drawFrameWithPresentation(
                true,
                presentation,
            ) catch unreachable;
            if (completed) |value| value.deliver();
            instrumentation.emit(.draw_frame_end);
        }
    };

    var state: State = .{};
    var renderer: MockRenderer = .{ .state = &state };
    const instrumentation: MockInstrumentation = .{ .state = &state };
    Harness.run(&renderer, &instrumentation, .{
        .callback = &State.presented,
        .userdata = &state,
        .token = 42,
    });

    try std.testing.expectEqualSlices(Event, &.{
        .begin,
        .renderer_cleanup,
        .end,
        .callback,
    }, state.events[0..state.len]);
    try std.testing.expect(!state.owner_access_after_callback);
}

test "mailbox drain error fallback reconciles deferred renderer visibility" {
    const ErrorFallbackRenderer = struct {
        flags_visible: bool = true,
        renderer_visible: bool = false,
        reconciliations: usize = 0,
        updates: usize = 0,
        submission_attempts: usize = 0,
        ordinary_wakes: usize = 0,

        fn pendingRendererVisibilityTransition(self: *@This()) ?bool {
            self.reconciliations += 1;
            if (self.renderer_visible == self.flags_visible) return null;
            return self.flags_visible;
        }

        fn updateVisibilityRegainFrame(self: *@This()) bool {
            self.updates += 1;
            return true;
        }

        fn drawForcedVisibilityRegainFrame(self: *@This()) DrawFrameResult {
            self.submission_attempts += 1;
            return .app_mailbox_full;
        }

        fn setRendererVisible(self: *@This(), visible: bool) void {
            self.renderer_visible = visible;
        }

        fn renderWakeFrame(self: *@This()) void {
            self.ordinary_wakes += 1;
        }
    };

    // This is the wakeup error fallback: a preceding reveal already changed
    // flags, but the failed drain returned no committed transition. Recovery
    // must retain the reveal when the app queue rejects both immediate draws.
    var renderer: ErrorFallbackRenderer = .{};
    var regain: VisibilityRegainState = .{};
    renderAfterMailboxDrain(&renderer, &regain, .{});

    try std.testing.expect(renderer.renderer_visible);
    try std.testing.expectEqual(1, renderer.reconciliations);
    try std.testing.expectEqual(1, renderer.updates);
    try std.testing.expectEqual(2, renderer.submission_attempts);
    try std.testing.expect(regain.isPending());
    try std.testing.expectEqual(0, renderer.ordinary_wakes);
}

test "visibility regain remains pending until submission succeeds" {
    const SubmissionRenderer = struct {
        updates: usize = 0,
        submission_attempts: usize = 0,
        outcomes: [6]DrawFrameResult = .{
            .app_mailbox_full,
            .app_mailbox_full,
            .submitted,
            .app_mailbox_full,
            .submitted,
            .app_mailbox_full,
        },
        outcome_index: usize = 0,
        visible: bool = false,
        ordinary_wakes: usize = 0,

        fn updateVisibilityRegainFrame(self: *@This()) bool {
            self.updates += 1;
            return true;
        }

        fn drawForcedVisibilityRegainFrame(self: *@This()) DrawFrameResult {
            self.submission_attempts += 1;
            const outcome = self.outcomes[self.outcome_index];
            self.outcome_index += 1;
            return outcome;
        }

        fn setRendererVisible(self: *@This(), visible: bool) void {
            self.visible = visible;
        }

        fn pendingRendererVisibilityTransition(_: *@This()) ?bool {
            return null;
        }

        fn renderWakeFrame(self: *@This()) void {
            self.ordinary_wakes += 1;
        }
    };

    var renderer: SubmissionRenderer = .{};
    var regain: VisibilityRegainState = .{};

    // The initial reveal and its immediate wake both see the same full app
    // queue. Neither failure may consume the pending reveal.
    const result = applyRendererVisibilityTransition(
        &renderer,
        &regain,
        true,
    );
    try std.testing.expect(!result.rendered_visibility_regain);
    try std.testing.expect(renderer.visible);
    try std.testing.expect(regain.isPending());
    renderAfterMailboxDrain(&renderer, &regain, result);
    try std.testing.expect(regain.isPending());
    try std.testing.expectEqual(0, renderer.ordinary_wakes);
    try std.testing.expectEqual(1, renderer.updates);
    try std.testing.expectEqual(2, renderer.submission_attempts);

    // The production app-drain callback carries this generation through its
    // dedicated async. It retries only the staged draw, never the update.
    const first_generation = regain.pendingGeneration().?;
    try std.testing.expectEqual(
        .submitted,
        regain.retrySubmission(&renderer, first_generation),
    );
    try std.testing.expect(!regain.isPending());
    try std.testing.expectEqual(3, renderer.submission_attempts);

    // A duplicate callback after success is inert.
    try std.testing.expectEqual(
        .not_pending,
        regain.retrySubmission(&renderer, first_generation),
    );
    try std.testing.expectEqual(3, renderer.submission_attempts);

    // A callback left over from the first reveal cannot submit a newer one.
    try std.testing.expectEqual(.pending, regain.updateAndSubmit(&renderer));
    const second_generation = regain.pendingGeneration().?;
    try std.testing.expect(first_generation != second_generation);
    try std.testing.expectEqual(
        .not_pending,
        regain.retrySubmission(&renderer, first_generation),
    );
    try std.testing.expectEqual(4, renderer.submission_attempts);
    try std.testing.expectEqual(
        .submitted,
        regain.retrySubmission(&renderer, second_generation),
    );
    try std.testing.expectEqual(2, renderer.updates);
    try std.testing.expectEqual(5, renderer.submission_attempts);

    // Hiding cancels a retained generation, so an app-drain callback cannot
    // resurrect a surface during teardown or occlusion.
    try std.testing.expectEqual(.pending, regain.updateAndSubmit(&renderer));
    const canceled_generation = regain.pendingGeneration().?;
    _ = applyRendererVisibilityTransition(&renderer, &regain, false);
    try std.testing.expect(!regain.isPending());
    try std.testing.expect(!renderer.visible);
    try std.testing.expectEqual(
        .not_pending,
        regain.retrySubmission(&renderer, canceled_generation),
    );
}

test "visibility regain renders exactly once per wake" {
    const DrawOutcome = enum {
        submitted,
        backend_failed,
        deferred_to_vsync,
        app_mailbox_dropped,
    };

    const EventCounts = struct {
        values: [4]usize = @splat(0),

        fn callback(
            userdata: ?*anyopaque,
            event: instrumentationpkg.Event,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.values[@intCast(@intFromEnum(event))] += 1;
        }

        fn count(self: *const @This(), event: instrumentationpkg.Event) usize {
            return self.values[@intCast(@intFromEnum(event))];
        }
    };

    const CountingRenderer = struct {
        updates: usize = 0,
        draws: usize = 0,
        visibility_changes: usize = 0,
        visible: bool = false,
        failed_updates_remaining: usize = 0,
        next_draw_outcome: DrawOutcome = .submitted,
        draw_requests: usize = 0,
        instrumentation: instrumentationpkg.Instrumentation = .{},

        // Models the old combined contract: update success is returned even
        // when the subsequent draw never reaches a backend or app mailbox.
        fn updateAndDrawFrame(self: *@This()) bool {
            if (!self.updateFrame()) return false;
            self.drawFrameLegacy();
            return true;
        }

        fn updateVisibilityRegainFrame(self: *@This()) bool {
            return self.updateFrame();
        }

        fn updateFrame(self: *@This()) bool {
            self.instrumentation.emit(.update_frame_begin);
            defer self.instrumentation.emit(.update_frame_end);
            self.updates += 1;
            if (self.failed_updates_remaining > 0) {
                self.failed_updates_remaining -= 1;
                return false;
            }
            return true;
        }

        fn drawFrameLegacy(self: *@This()) void {
            self.instrumentation.emit(.draw_frame_begin);
            defer self.instrumentation.emit(.draw_frame_end);
            self.draw_requests += 1;
            if (self.next_draw_outcome != .submitted) {
                self.next_draw_outcome = .submitted;
                return;
            }
            self.draws += 1;
        }

        fn drawVisibilityRegainFrame(self: *@This()) bool {
            return self.drawSubmittedFrame(false) == .submitted;
        }

        fn drawForcedVisibilityRegainFrame(self: *@This()) DrawFrameResult {
            return self.drawSubmittedFrame(true);
        }

        fn drawSubmittedFrame(
            self: *@This(),
            force: bool,
        ) DrawFrameResult {
            self.draw_requests += 1;
            if (self.next_draw_outcome != .submitted) {
                if (self.next_draw_outcome == .deferred_to_vsync and force) {
                    self.next_draw_outcome = .submitted;
                } else if (self.next_draw_outcome == .backend_failed) {
                    self.next_draw_outcome = .submitted;
                    self.instrumentation.emit(.draw_frame_begin);
                    self.instrumentation.emit(.draw_frame_end);
                    return .backend_failed;
                } else {
                    const result: DrawFrameResult =
                        if (self.next_draw_outcome == .app_mailbox_dropped)
                            .app_mailbox_full
                        else
                            .deferred_to_vsync;
                    if (self.next_draw_outcome != .deferred_to_vsync) {
                        self.next_draw_outcome = .submitted;
                    }
                    return result;
                }
            }

            self.instrumentation.emit(.draw_frame_begin);
            defer self.instrumentation.emit(.draw_frame_end);
            self.draws += 1;
            return .submitted;
        }

        fn setRendererVisible(self: *@This(), visible: bool) void {
            self.visibility_changes += 1;
            self.visible = visible;
        }

        fn pendingRendererVisibilityTransition(_: *@This()) ?bool {
            return null;
        }

        fn renderWakeFrame(self: *@This()) void {
            if (!self.visible) return;
            if (!self.updateVisibilityRegainFrame()) return;
            _ = self.drawVisibilityRegainFrame();
        }
    };

    var reveal_state = VisibilityDrainState.init(false);
    try std.testing.expect(reveal_state.apply(true));
    var reveal_events: EventCounts = .{};
    var reveal: CountingRenderer = .{ .instrumentation = .{
        .callback = EventCounts.callback,
        .userdata = &reveal_events,
    } };
    var reveal_regain: VisibilityRegainState = .{};
    const reveal_result = applyRendererVisibilityTransition(
        &reveal,
        &reveal_regain,
        reveal_state.rendererTransition(),
    );
    renderAfterMailboxDrain(&reveal, &reveal_regain, reveal_result);
    try std.testing.expectEqual(1, reveal.updates);
    try std.testing.expectEqual(1, reveal.draw_requests);
    try std.testing.expectEqual(1, reveal.draws);
    try std.testing.expectEqual(1, reveal.visibility_changes);
    try std.testing.expect(reveal.visible);
    try std.testing.expectEqual(1, reveal_events.count(.update_frame_begin));
    try std.testing.expectEqual(1, reveal_events.count(.update_frame_end));
    try std.testing.expectEqual(1, reveal_events.count(.draw_frame_begin));
    try std.testing.expectEqual(1, reveal_events.count(.draw_frame_end));

    // A wake without a visibility transition still renders normally.
    var ordinary_events: EventCounts = .{};
    var ordinary: CountingRenderer = .{
        .visible = true,
        .instrumentation = .{
            .callback = EventCounts.callback,
            .userdata = &ordinary_events,
        },
    };
    var ordinary_regain: VisibilityRegainState = .{};
    const ordinary_result = applyRendererVisibilityTransition(
        &ordinary,
        &ordinary_regain,
        null,
    );
    renderAfterMailboxDrain(&ordinary, &ordinary_regain, ordinary_result);
    try std.testing.expectEqual(1, ordinary.updates);
    try std.testing.expectEqual(1, ordinary.draw_requests);
    try std.testing.expectEqual(1, ordinary.draws);
    try std.testing.expectEqual(0, ordinary.visibility_changes);
    try std.testing.expectEqual(1, ordinary_events.count(.update_frame_begin));
    try std.testing.expectEqual(1, ordinary_events.count(.update_frame_end));
    try std.testing.expectEqual(1, ordinary_events.count(.draw_frame_begin));
    try std.testing.expectEqual(1, ordinary_events.count(.draw_frame_end));

    // Hidden wakes have no renderer update or draw activity.
    var hidden_events: EventCounts = .{};
    var hidden: CountingRenderer = .{
        .visible = true,
        .instrumentation = .{
            .callback = EventCounts.callback,
            .userdata = &hidden_events,
        },
    };
    var hidden_state = VisibilityDrainState.init(true);
    try std.testing.expect(hidden_state.apply(false));
    var hidden_regain: VisibilityRegainState = .{};
    const hidden_result = applyRendererVisibilityTransition(
        &hidden,
        &hidden_regain,
        hidden_state.rendererTransition(),
    );
    renderAfterMailboxDrain(&hidden, &hidden_regain, hidden_result);
    try std.testing.expect(!hidden_regain.isPending());
    try std.testing.expectEqual(0, hidden.updates);
    try std.testing.expectEqual(0, hidden.draw_requests);
    try std.testing.expectEqual(0, hidden.draws);
    try std.testing.expectEqual(1, hidden.visibility_changes);
    try std.testing.expect(!hidden.visible);
    for (hidden_events.values) |count| try std.testing.expectEqual(0, count);

    // A failed reveal update does not suppress the normal wake retry.
    var retry_events: EventCounts = .{};
    var retry: CountingRenderer = .{
        .failed_updates_remaining = 1,
        .instrumentation = .{
            .callback = EventCounts.callback,
            .userdata = &retry_events,
        },
    };
    var retry_regain: VisibilityRegainState = .{};
    const retry_result = applyRendererVisibilityTransition(
        &retry,
        &retry_regain,
        true,
    );
    renderAfterMailboxDrain(&retry, &retry_regain, retry_result);
    try std.testing.expectEqual(2, retry.updates);
    try std.testing.expectEqual(1, retry.draw_requests);
    try std.testing.expectEqual(1, retry.draws);
    try std.testing.expectEqual(1, retry.visibility_changes);
    try std.testing.expect(retry.visible);
    try std.testing.expectEqual(2, retry_events.count(.update_frame_begin));
    try std.testing.expectEqual(2, retry_events.count(.update_frame_end));
    try std.testing.expectEqual(1, retry_events.count(.draw_frame_begin));
    try std.testing.expectEqual(1, retry_events.count(.draw_frame_end));

    // A rejected app-mailbox push retains the already-updated frame. Its one
    // immediate retry must not rebuild terminal state.
    var app_events: EventCounts = .{};
    var app_renderer: CountingRenderer = .{
        .next_draw_outcome = .app_mailbox_dropped,
        .instrumentation = .{
            .callback = EventCounts.callback,
            .userdata = &app_events,
        },
    };
    var app_regain: VisibilityRegainState = .{};
    const app_result = applyRendererVisibilityTransition(
        &app_renderer,
        &app_regain,
        true,
    );
    try std.testing.expect(!app_result.rendered_visibility_regain);
    try std.testing.expect(app_regain.isPending());
    try std.testing.expectEqual(1, app_renderer.updates);
    try std.testing.expectEqual(1, app_renderer.draw_requests);
    try std.testing.expectEqual(0, app_events.count(.draw_frame_begin));
    renderAfterMailboxDrain(&app_renderer, &app_regain, app_result);
    try std.testing.expect(!app_regain.isPending());
    try std.testing.expectEqual(1, app_renderer.updates);
    try std.testing.expectEqual(2, app_renderer.draw_requests);
    try std.testing.expectEqual(1, app_renderer.draws);
    try std.testing.expectEqual(1, app_events.count(.draw_frame_begin));
    try std.testing.expectEqual(1, app_events.count(.draw_frame_end));

    // A backend error has no general readiness signal, so it never latches the
    // app-capacity state. Preserve the prior immediate normal-wake retry and
    // balanced backend instrumentation without creating a no-vsync retry loop.
    var backend_events: EventCounts = .{};
    var backend_renderer: CountingRenderer = .{
        .next_draw_outcome = .backend_failed,
        .instrumentation = .{
            .callback = EventCounts.callback,
            .userdata = &backend_events,
        },
    };
    var backend_regain: VisibilityRegainState = .{};
    const backend_result = applyRendererVisibilityTransition(
        &backend_renderer,
        &backend_regain,
        true,
    );
    try std.testing.expect(!backend_result.rendered_visibility_regain);
    try std.testing.expect(!backend_regain.isPending());
    try std.testing.expectEqual(1, backend_renderer.updates);
    try std.testing.expectEqual(1, backend_renderer.draw_requests);
    try std.testing.expectEqual(1, backend_events.count(.draw_frame_begin));
    renderAfterMailboxDrain(
        &backend_renderer,
        &backend_regain,
        backend_result,
    );
    try std.testing.expect(!backend_regain.isPending());
    try std.testing.expectEqual(2, backend_renderer.updates);
    try std.testing.expectEqual(2, backend_renderer.draw_requests);
    try std.testing.expectEqual(1, backend_renderer.draws);
    try std.testing.expectEqual(2, backend_events.count(.draw_frame_begin));
    try std.testing.expectEqual(2, backend_events.count(.draw_frame_end));

    // A normal wake can remain deferred while a display link owns vsync. The
    // reveal path must force one submission instead of relying on that same
    // deferred wake to make the newly visible surface nonblank.
    var deferred_events: EventCounts = .{};
    var deferred: CountingRenderer = .{
        .next_draw_outcome = .deferred_to_vsync,
        .instrumentation = .{
            .callback = EventCounts.callback,
            .userdata = &deferred_events,
        },
    };
    try std.testing.expect(!deferred.drawVisibilityRegainFrame());
    try std.testing.expect(!deferred.drawVisibilityRegainFrame());
    try std.testing.expectEqual(0, deferred.draws);
    try std.testing.expectEqual(0, deferred_events.count(.draw_frame_begin));
    try std.testing.expectEqual(0, deferred_events.count(.draw_frame_end));

    var deferred_regain: VisibilityRegainState = .{};
    const deferred_result = applyRendererVisibilityTransition(
        &deferred,
        &deferred_regain,
        true,
    );
    try std.testing.expect(deferred_result.rendered_visibility_regain);
    try std.testing.expect(!deferred_regain.isPending());
    try std.testing.expect(deferred.visible);
    try std.testing.expectEqual(1, deferred.updates);
    try std.testing.expectEqual(3, deferred.draw_requests);
    try std.testing.expectEqual(1, deferred.draws);
    try std.testing.expectEqual(1, deferred_events.count(.draw_frame_begin));
    try std.testing.expectEqual(1, deferred_events.count(.draw_frame_end));
}

/// Notify the apprt when the active selection changes. The activity epoch is
/// atomic, so this path never acquires the terminal mutex.
fn notifySelectionChanged(self: *Thread) void {
    const activity = self.state.terminal.selectionActivity();
    if (std.meta.eql(self.selection_activity, activity)) return;
    self.selection_activity = activity;

    _ = self.surface.rtApp().performAction(
        .{ .surface = self.surface.core() },
        .selection_changed,
        {},
    ) catch |err| {
        log.warn("apprt failed selection_changed notification err={}", .{err});
    };
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
    const self = self_.?;
    self.visibility_regain.cancel();
    self.loop.stop();
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

/// Schedules incremental terminal compression after renderer activity stops.
///
/// This owns all renderer-specific compression state. The terminal decides
/// when compression-relevant activity changes and performs the actual work;
/// the renderer only provides idle scheduling and avoids waiting for the
/// terminal lock.
const Compression = struct {
    const idle_interval = 250;
    const step_interval = 1;

    timer: xev.Timer,
    completion: xev.Completion = .{},
    reset_completion: xev.Completion = .{},
    activity: ?u64 = null,

    fn init() !Compression {
        return .{ .timer = try xev.Timer.init() };
    }

    fn deinit(self: *Compression) void {
        self.timer.deinit();
    }

    /// Start or postpone compression after a renderer wake.
    fn wake(self: *Compression, thread: *Thread) void {
        // If we have no compression then don't do anything.
        if (comptime !terminalpkg.compression_enabled) return;
        if (!thread.config.scrollback_compression) return;

        // PageList activity, rather than a generic renderer wake, restarts the
        // idle interval. In particular, the inspector wakes the renderer every
        // frame without changing terminal contents and must not starve this
        // timer indefinitely.
        if (thread.state.mutex.tryLock()) {
            defer thread.state.mutex.unlock();
            const activity = thread.state.terminal.compressionActivity();
            if (self.activity == activity) return;
            self.activity = activity;
        } else if (self.completion.state() == .active) {
            // Contention doesn't prove that compression-relevant activity
            // changed. Keep an existing deadline so frequent inspector frames
            // cannot postpone compression forever. The timer rechecks both the
            // activity token and lock availability before doing any work.
            return;
        }

        // Contention may mean parsing is active. Scheduling is a harmless
        // false positive when no compression work is actually pending, but is
        // necessary when no timer is already active.
        self.schedule(thread, idle_interval);
    }

    /// Start the one-shot timer, or move its deadline if it is already active.
    fn schedule(self: *Compression, thread: *Thread, delay_ms: u64) void {
        self.timer.reset(
            &thread.loop,
            &self.completion,
            &self.reset_completion,
            delay_ms,
            Thread,
            thread,
            timerCallback,
        );
    }

    fn timerCallback(
        thread_: ?*Thread,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch |err| switch (err) {
            error.Canceled => return .disarm,
            else => {
                log.warn("error in compression timer err={}", .{err});
                return .disarm;
            },
        };

        const thread = thread_ orelse return .disarm;
        const self = &thread.compression;

        if (self.step(thread)) |delay| self.schedule(thread, delay);
        return .disarm;
    }

    /// Try one bounded step without waiting for the terminal lock. The return
    /// value is the delay before another attempt, or null when work is done.
    fn step(self: *Compression, thread: *Thread) ?u64 {
        if (!thread.config.scrollback_compression) return null;

        const state = thread.state;
        if (!state.mutex.tryLock()) return idle_interval;
        defer state.mutex.unlock();

        const activity = state.terminal.compressionActivity();
        if (self.activity != activity) {
            self.activity = activity;
            return idle_interval;
        }

        return switch (state.terminal.compress(.incremental)) {
            .pending => step_interval,
            .unsupported,
            .complete,
            => null,
        };
    }
};
