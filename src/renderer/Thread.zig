//! Represents the renderer thread logic. The renderer thread is able to
//! be woken up to render.
pub const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
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

const RendererRealizedRequest = enum(u8) {
    unrealize = 1,
    realize = 2,
    rebuild = 3,

    fn fromBool(value: bool) RendererRealizedRequest {
        return if (value) .realize else .unrealize;
    }
};

/// Latest-value publication for surface lifecycle state. These values have no
/// owned payloads, so producers can replace an unread request instead of
/// waiting for space in the ordered renderer mailbox. Renderer rebuild is the
/// one stronger operation: a redundant realize publication preserves it so a
/// forced unrealize/realize transaction cannot be coalesced away.
///
/// Each property has its own atomic slot. Zero means no pending request;
/// booleans use one/two for false/true, renderer realization uses the enum
/// values above, and display ids are offset by one so every u32 value remains
/// representable. A producer that races `take` either lands in the returned
/// update or remains pending for the next renderer wake.
const SurfaceStateRequests = struct {
    const Update = struct {
        visible: ?bool = null,
        renderer_realized: ?RendererRealizedRequest = null,
        focused: ?bool = null,
        display_id: ?u32 = null,
    };

    visible: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    renderer_realized: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    focused: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    display_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn publishVisible(self: *SurfaceStateRequests, value: bool) void {
        self.visible.store(if (value) 2 else 1, .release);
    }

    fn publishRendererRealized(self: *SurfaceStateRequests, value: bool) void {
        const request = RendererRealizedRequest.fromBool(value);
        if (request == .unrealize) {
            self.renderer_realized.store(@intFromEnum(request), .release);
            return;
        }

        // Rebuild already has the same final realized state, but also carries
        // the required unrealize transition. A redundant realize must not
        // weaken it before the renderer consumes the slot.
        var current = self.renderer_realized.load(.monotonic);
        while (current != @intFromEnum(RendererRealizedRequest.rebuild)) {
            current = self.renderer_realized.cmpxchgWeak(
                current,
                @intFromEnum(request),
                .release,
                .monotonic,
            ) orelse return;
        }
    }

    fn publishRendererRebuild(self: *SurfaceStateRequests) void {
        self.renderer_realized.store(
            @intFromEnum(RendererRealizedRequest.rebuild),
            .release,
        );
    }

    fn publishFocused(self: *SurfaceStateRequests, value: bool) void {
        self.focused.store(if (value) 2 else 1, .release);
    }

    fn publishDisplayID(self: *SurfaceStateRequests, value: u32) void {
        self.display_id.store(@as(u64, value) + 1, .release);
    }

    fn restoreFocusedIfEmpty(
        self: *SurfaceStateRequests,
        value: bool,
    ) void {
        _ = self.focused.cmpxchgStrong(
            0,
            if (value) 2 else 1,
            .release,
            .monotonic,
        );
    }

    fn restoreRendererRealizedIfEmpty(
        self: *SurfaceStateRequests,
        value: RendererRealizedRequest,
    ) void {
        _ = self.renderer_realized.cmpxchgStrong(
            0,
            @intFromEnum(value),
            .release,
            .monotonic,
        );
    }

    fn restoreDisplayIDIfEmpty(
        self: *SurfaceStateRequests,
        value: u32,
    ) void {
        _ = self.display_id.cmpxchgStrong(
            0,
            @as(u64, value) + 1,
            .release,
            .monotonic,
        );
    }

    fn take(self: *SurfaceStateRequests) Update {
        return .{
            .visible = decodeBool(self.visible.swap(0, .acq_rel)),
            .renderer_realized = decodeRendererRealized(
                self.renderer_realized.swap(0, .acq_rel),
            ),
            .focused = decodeBool(self.focused.swap(0, .acq_rel)),
            .display_id = decodeDisplayID(self.display_id.swap(0, .acq_rel)),
        };
    }

    fn hasPending(self: *const SurfaceStateRequests) bool {
        return self.visible.load(.acquire) != 0 or
            self.renderer_realized.load(.acquire) != 0 or
            self.focused.load(.acquire) != 0 or
            self.display_id.load(.acquire) != 0;
    }

    fn decodeBool(value: u8) ?bool {
        return switch (value) {
            0 => null,
            1 => false,
            2 => true,
            else => unreachable,
        };
    }

    fn decodeRendererRealized(value: u8) ?RendererRealizedRequest {
        return switch (value) {
            0 => null,
            1 => .unrealize,
            2 => .realize,
            3 => .rebuild,
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
    wake_pending: bool = false,
};

/// Service one finite mailbox turn for a synchronous renderer and retain a
/// follow-up turn on both success and failure. The caller renders after this
/// returns, so a continuously replenished queue cannot postpone the frame.
fn drainSynchronousMailbox(context: anytype) !void {
    defer context.scheduleRendererContinuationIfNeeded();
    _ = try context.drainMailbox();
}

fn scheduleExternalRendererContinuation(context: anytype) void {
    const generation =
        context.requestExternalRendererContinuation() orelse return;
    context.enqueueExternalRendererContinuation(generation);
}

fn retryExternalRendererContinuation(context: anytype) void {
    const generation =
        context.retryFailedExternalRendererContinuation() orelse return;
    context.enqueueExternalRendererContinuation(generation);
}

/// Owns one ticketed external-redraw delivery at a time.
///
/// The generation travels with the app-mailbox message, so a stale host
/// acknowledgment cannot mutate a newer request. All transitions are short
/// critical sections; mailbox pushes, host callbacks, and renderer work occur
/// after the mutex is released.
const ExternalRedrawDelivery = struct {
    const Phase = enum {
        queued,
        enqueue_failed,
    };

    const Request = struct {
        generation: u64,
        phase: Phase,
    };

    mutex: std.Io.Mutex = .init,
    next_generation: u64 = 0,
    active: ?Request = null,
    wake_behind_active: bool = false,

    /// Claim a ticket for a renderer wake. A wake can reuse a ticket whose
    /// enqueue failed, because the resulting frame covers both old and new
    /// terminal state. Wakes behind a queued host action remain coalesced.
    fn request(self: *ExternalRedrawDelivery) ?u64 {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (self.active) |*active| {
            if (active.phase == .enqueue_failed) {
                active.phase = .queued;
                return active.generation;
            }
            self.wake_behind_active = true;
            return null;
        }
        return self.startRequestLocked();
    }

    /// Publish a failed enqueue for this exact ticket. `Mailbox.pushObserved`
    /// invokes this before it publishes the shared capacity retry and wakes the
    /// app thread.
    fn enqueueFailed(
        self: *ExternalRedrawDelivery,
        generation: u64,
    ) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (self.active) |*active| {
            if (active.generation == generation) {
                active.phase = .enqueue_failed;
            }
        }
    }

    /// Claim only a ticket whose own enqueue failed. A capacity callback for
    /// one surface cannot duplicate a queued ticket for another surface.
    fn retryFailedEnqueue(self: *ExternalRedrawDelivery) ?u64 {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (self.active) |*active| {
            if (active.phase == .enqueue_failed) {
                active.phase = .queued;
                return active.generation;
            }
        }
        return null;
    }

    /// Record the host result for an exact ticket. A rejected action releases
    /// its own request. Return true when a newer wake had coalesced behind it,
    /// so xev schedules that later wake once without rejection spin.
    fn actionCompleted(
        self: *ExternalRedrawDelivery,
        generation: u64,
        accepted: bool,
    ) bool {
        if (accepted) return false;

        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        const active = self.active orelse return false;
        if (active.generation != generation) return false;

        const notify = self.wake_behind_active;
        self.active = null;
        self.wake_behind_active = false;
        return notify;
    }

    /// A frame start covers every request published before this critical
    /// section. A concurrent later wake either lands before the reset and is
    /// covered, or lands after it and receives a new ticket.
    fn renderStarted(self: *ExternalRedrawDelivery) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        self.active = null;
        self.wake_behind_active = false;
    }

    /// Caller holds `mutex`.
    fn startRequestLocked(self: *ExternalRedrawDelivery) u64 {
        self.next_generation +%= 1;
        if (self.next_generation == 0) self.next_generation = 1;
        self.active = .{
            .generation = self.next_generation,
            .phase = .queued,
        };
        return self.next_generation;
    }
};

const ExternalRedrawEnqueueObserver = struct {
    delivery: *ExternalRedrawDelivery,
    generation: u64,

    pub fn pushCompleted(
        self: @This(),
        queue_size: App.Mailbox.Queue.Size,
    ) void {
        if (queue_size == 0) {
            self.delivery.enqueueFailed(self.generation);
        }
    }
};

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

/// Renderer realization can allocate Metal resources and fail under memory
/// pressure. Keep the latest desired value while pacing retries so a failed
/// tab restore cannot turn the renderer wakeup into a tight loop.
const RendererRealizedRetryState = struct {
    const initial_delay_ms = 250;
    const maximum_delay_ms = 4_000;

    const Delivery = struct {
        value: RendererRealizedRequest,
        generation: u64,
    };

    const TimerRequest = struct {
        delay_ms: u64,
        generation: u64,
    };

    mutex: std.Io.Mutex = .init,
    value: ?Delivery = null,
    requested_timer_generation: ?u64 = null,
    active_timer_generation: ?u64 = null,
    delay_ms: u64 = initial_delay_ms,
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Invalidate a claimed retry before publishing newer lock-free lifecycle
    /// state. The later atomic state store either replaces an already-restored
    /// retry or is observed by its conditional restoration.
    fn published(self: *RendererRealizedRetryState) void {
        _ = self.generation.fetchAdd(1, .acq_rel);
    }

    /// Record a failed value and return the delay for a newly required timer.
    /// An already scheduled timer owns delivery of the coalesced latest value.
    fn failed(
        self: *RendererRealizedRetryState,
        value: RendererRealizedRequest,
    ) ?TimerRequest {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        return self.failedLocked(.{
            .value = value,
            .generation = self.generation.load(.acquire),
        });
    }

    /// Re-arm a timer backend failure only while its claimed lifecycle
    /// generation is still authoritative.
    fn failedIfCurrent(
        self: *RendererRealizedRetryState,
        delivery: Delivery,
    ) ?TimerRequest {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (delivery.generation != self.generation.load(.acquire)) return null;
        return self.failedLocked(delivery);
    }

    /// Caller holds `mutex`.
    fn failedLocked(
        self: *RendererRealizedRetryState,
        delivery: Delivery,
    ) ?TimerRequest {
        self.value = delivery;
        if (self.requested_timer_generation == delivery.generation) return null;

        self.requested_timer_generation = delivery.generation;
        const delay_ms = self.delay_ms;
        self.delay_ms = @min(self.delay_ms * 2, maximum_delay_ms);
        return .{ .delay_ms = delay_ms, .generation = delivery.generation };
    }

    /// A newer lifecycle publication supersedes the retry value. The timer may
    /// remain armed and becomes a no-op unless another failure coalesces into it.
    fn supersede(self: *RendererRealizedRetryState) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.value = null;
        self.requested_timer_generation = null;
    }

    /// Claim published surface state while atomically invalidating any older
    /// renderer retry. A timer callback uses the same mutex when restoring, so
    /// it cannot refill the renderer slot between its claim and invalidation.
    fn takeSurfaceState(
        self: *RendererRealizedRetryState,
        requests: *SurfaceStateRequests,
    ) SurfaceStateRequests.Update {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        const update = requests.take();
        if (update.renderer_realized != null) {
            _ = self.generation.fetchAdd(1, .acq_rel);
            self.value = null;
            self.requested_timer_generation = null;
        }
        return update;
    }

    fn resolved(self: *RendererRealizedRetryState) void {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.value = null;
        // The loop-owned timer may still be armed, but it no longer owns a
        // retry deadline. A fresh failure starts at the initial delay and
        // resets that stale timer through xev.
        self.requested_timer_generation = null;
        self.delay_ms = initial_delay_ms;
    }

    /// Claim one generation-tagged request immediately before the loop owner
    /// resets the xev timer. An obsolete handoff cannot replace a newer
    /// lifecycle deadline.
    fn timerWillArm(
        self: *RendererRealizedRetryState,
        request: TimerRequest,
    ) bool {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (request.generation != self.generation.load(.acquire)) return false;
        if (self.requested_timer_generation != request.generation) return false;
        const delivery = self.value orelse return false;
        if (delivery.generation != request.generation) return false;
        self.active_timer_generation = request.generation;
        return true;
    }

    fn fired(self: *RendererRealizedRetryState) ?Delivery {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        const timer_generation = self.active_timer_generation orelse return null;
        self.active_timer_generation = null;
        const delivery = self.value orelse return null;
        if (delivery.generation != timer_generation) return null;
        if (self.requested_timer_generation == timer_generation) {
            self.requested_timer_generation = null;
        }
        self.value = null;
        return delivery;
    }

    /// Restore a claimed retry only if no newer lifecycle publication or
    /// successful resolution has invalidated its generation.
    fn restoreIfCurrent(
        self: *RendererRealizedRetryState,
        delivery: Delivery,
        requests: *SurfaceStateRequests,
    ) bool {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (delivery.generation != self.generation.load(.acquire)) return false;
        requests.restoreRendererRealizedIfEmpty(delivery.value);
        return true;
    }
};

/// Cross-thread one-shot request to arm the realization retry timer. External
/// iOS rendering owns renderer state on its serial queue, but xev loop handles
/// must only be mutated by the renderer OS thread.
const RendererRealizedRetryTimerHandoff = struct {
    mutex: std.Io.Mutex = .init,
    request: ?RendererRealizedRetryState.TimerRequest = null,

    fn publish(
        self: *RendererRealizedRetryTimerHandoff,
        request: RendererRealizedRetryState.TimerRequest,
    ) void {
        std.debug.assert(request.delay_ms > 0);
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());

        if (self.request) |pending| {
            if (pending.generation > request.generation) return;
        }
        self.request = request;
    }

    fn take(
        self: *RendererRealizedRetryTimerHandoff,
    ) ?RendererRealizedRetryState.TimerRequest {
        self.mutex.lockUncancelable(global.io());
        defer self.mutex.unlock(global.io());
        const request = self.request;
        self.request = null;
        return request;
    }
};

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
started: std.Io.Event = .unset,

/// One-shot timer and coalesced state for fallible Metal realization retries.
/// This repurposes the renderer's otherwise unused legacy render timer, so the
/// recovery path does not add another xev handle to every terminal surface.
renderer_realized_retry_h: xev.Timer,
renderer_realized_retry_c: xev.Completion = .{},
renderer_realized_retry_reset_c: xev.Completion = .{},
renderer_realized_retry: RendererRealizedRetryState = .{},
renderer_realized_retry_timer_handoff: RendererRealizedRetryTimerHandoff = .{},

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

/// Whether the renderer currently owns a live swap chain and shaders.
/// Renderer-thread owned. Realization requests are idempotent so embedders can
/// publish authoritative visibility-derived state without mirroring queue
/// delivery.
renderer_realized: bool = true,

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

/// Ticketed external redraw delivery retained across app-mailbox pressure and
/// host action dispatch. Wake-only redraws have no renderer mailbox entry that
/// could otherwise prove a retry is needed.
external_redraw_delivery: ExternalRedrawDelivery = .{},

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

    // Paced Metal realization recovery. This was historically an unused
    // general render timer, so reusing it keeps per-surface handles flat.
    var renderer_realized_retry_h = try xev.Timer.init();
    errdefer renderer_realized_retry_h.deinit();

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
        .renderer_realized_retry_h = renderer_realized_retry_h,
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
    self.renderer_realized_retry_h.deinit();
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
    self.external_redraw_delivery.renderStarted();
    drainSynchronousMailbox(self) catch |err| {
        log.err("renderNow: error draining mailbox err={}", .{err});
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
    self.external_redraw_delivery.renderStarted();
    drainSynchronousMailbox(self) catch |err| {
        log.err("renderNowWithPresentation: error draining mailbox err={}", .{err});
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

/// Drain one finite external renderer mailbox turn.
///
/// cmux iOS fork: a public seam over the private `drainMailbox` so a producer
/// running on the iOS render serial queue (where `render_now` is the mailbox's
/// only drainer) can flush a full mailbox inline before pushing a state-carrying
/// message that must NOT be dropped (e.g. `.font_grid`, whose handler derefs the
/// old grid). Safe to call from that queue for the same reason `render_now` is:
/// `render_now` already calls `drainMailbox` on this serial queue every frame
/// (see `renderNow`). Any remainder schedules another embedder render through
/// the existing `.render` action, so this call stays bounded even if another
/// producer is active. `drainMailbox` and its handlers take no
/// `renderer_state.mutex`, so it cannot self-deadlock against a caller that
/// holds it. Delete when upstream exposes a synchronous embedder render tick.
pub fn drainMailboxNow(self: *Thread) void {
    self.enterExternalDrainMode();
    drainSynchronousMailbox(self) catch |err| {
        log.err("drainMailboxNow: error draining mailbox err={}", .{err});
        return;
    };
}

/// Publish latest-value surface lifecycle state without waiting for renderer
/// mailbox capacity. Callers must notify `wakeup` after publishing.
pub fn publishVisible(self: *Thread, value: bool) void {
    self.surface_state_requests.publishVisible(value);
}

pub fn publishRendererRealized(self: *Thread, value: bool) void {
    self.renderer_realized_retry.published();
    self.surface_state_requests.publishRendererRealized(value);
}

pub fn publishRendererRebuild(self: *Thread) void {
    self.renderer_realized_retry.published();
    self.surface_state_requests.publishRendererRebuild();
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
    // Once capacity returns, retry only a continuation whose own enqueue
    // failed. Already queued requests for other surfaces remain coalesced.
    if (self.externalDrainActive()) {
        retryExternalRendererContinuation(self);
    }

    const generation = self.visibility_regain.pendingGeneration() orelse return;
    self.visibility_retry_generation.store(generation, .release);
    self.visibility_retry.notify() catch |err| {
        log.warn("failed to notify visibility-regain retry err={}", .{err});
    };
}

/// Complete delivery of the app mailbox's `.redraw_surface` action. A rejected
/// action releases its request so a later renderer wake can enqueue again. If
/// a newer wake was coalesced behind the rejected action, wake xev once to
/// preserve that later request without retrying a permanently rejected action.
pub fn externalRenderActionCompleted(
    self: *Thread,
    generation: u64,
    accepted: bool,
) void {
    if (!self.externalDrainActive()) return;
    if (!self.external_redraw_delivery.actionCompleted(
        generation,
        accepted,
    )) return;
    self.wakeup.notify() catch |err| {
        log.warn("failed to retry external redraw after rejected action err={}", .{err});
    };
}

fn enterExternalDrainMode(self: *Thread) void {
    if (comptime builtin.os.tag != .ios) return;
    if (!self.external_drain.load(.seq_cst)) {
        self.cursor_blink_epoch_ms = std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
        self.flags.cursor_blink_visible = true;
        self.external_drain.store(true, .seq_cst);
    }
}

fn externalDrainActive(self: *const Thread) bool {
    if (comptime builtin.os.tag != .ios) return false;
    return self.external_drain.load(.seq_cst);
}

fn hasPendingRendererWork(self: *const Thread) bool {
    return self.mailbox.count(global.io()) > 0 or
        self.surface_state_requests.hasPending();
}

fn requestExternalRendererContinuation(self: *Thread) ?u64 {
    return self.external_redraw_delivery.request();
}

fn retryFailedExternalRendererContinuation(self: *Thread) ?u64 {
    return self.external_redraw_delivery.retryFailedEnqueue();
}

fn enqueueExternalRendererContinuation(
    self: *Thread,
    generation: u64,
) void {
    _ = self.app_mailbox.pushObserved(
        .{ .redraw_surface = .{
            .surface = self.surface,
            .external_ticket = .{
                .surface_id = self.surface.core().id,
                .generation = generation,
            },
        } },
        .{ .instant = {} },
        ExternalRedrawEnqueueObserver{
            .delivery = &self.external_redraw_delivery,
            .generation = generation,
        },
    );
}

/// Retain a finite follow-up turn without draining renderer state from the
/// wrong thread. Normal rendering re-notifies xev. External iOS rendering uses
/// the app mailbox's established `.render` action, whose embedder callback
/// schedules the next `render_now` invocation.
fn scheduleRendererContinuationIfNeeded(self: *Thread) void {
    if (!self.hasPendingRendererWork()) return;

    if (self.externalDrainActive()) {
        scheduleExternalRendererContinuation(self);
        return;
    }

    self.wakeup.notify() catch |err| {
        log.warn("failed to continue pending renderer work err={}", .{err});
    };
}

fn resetExternalCursorBlink(self: *Thread) void {
    self.flags.cursor_blink_visible = true;
    self.cursor_blink_epoch_ms = std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
}

fn effectiveCursorBlinkVisible(self: *Thread) bool {
    if (!self.externalDrainActive()) return self.flags.cursor_blink_visible;
    if (!self.flags.focused) return true;

    const epoch = self.cursor_blink_epoch_ms;
    if (epoch <= 0) return true;

    const now = std.Io.Timestamp.now(global.io(), .awake).toMilliseconds();
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
    self.started.set(global.io());

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

    // Process only the messages present at the start of this renderer turn.
    // Producers can refill the queue as we pop. Draining until a transient
    // empty state lets sustained terminal output monopolize the renderer loop,
    // delaying lifecycle state below and the render that follows this drain.
    // A snapshot gives both bounded latency while preserving FIFO ordering.
    var remaining = self.mailbox.count(global.io());

    while (remaining > 0) : (remaining -= 1) {
        const message = self.mailbox.pop(global.io()) orelse break;
        log.debug("mailbox message={}", .{message});
        switch (message) {
            .crash => @panic("crash request, crashing intentionally"),

            .visible => |v| self.applyVisible(&visibility, v),

            .focus => |v| try self.applyFocused(v, external_drain),

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

            .macos_display_id => |v| try self.applyDisplayID(v),

            // cmux fork: release/recreate the renderer's GPU resources (swap
            // chain / IOSurface) without freeing the surface. Safe here because
            // this runs on the renderer thread (so it never races a draw), the
            // surface is occluded when this is sent (macOS `drawFrame` early-
            // returns on `!flags.visible`), and both calls take `draw_mutex`.
            .display_realized => |v| {
                try self.applyRendererRealized(
                    RendererRealizedRequest.fromBool(v),
                );
            },
        }
    }

    // Lifecycle state is latest-value rather than ordered work. Apply it after
    // this bounded ordinary-mailbox snapshot so an older compatibility message
    // cannot overwrite a newer request, without waiting for a producer-refilled
    // queue to become transiently empty.
    const surface_state = self.renderer_realized_retry.takeSurfaceState(
        &self.surface_state_requests,
    );
    // Visibility application cannot fail, so its thread-owned state is already
    // committed if a later lifecycle operation fails. A normal wake reconciles
    // renderer visibility in `renderAfterMailboxDrain`; external iOS rendering
    // deliberately leaves visibility and frame gating to its platform owner.
    if (surface_state.visible) |value| self.applyVisible(&visibility, value);
    if (surface_state.renderer_realized) |value| {
        // Any publication is newer than a retained retry. A failed application
        // below records this value again behind the paced timer.
        self.applyRendererRealized(value) catch |err| {
            self.scheduleRendererRealizedRetry(value);
            if (surface_state.focused) |focused| {
                self.surface_state_requests.restoreFocusedIfEmpty(focused);
            }
            if (surface_state.display_id) |display_id| {
                self.surface_state_requests.restoreDisplayIDIfEmpty(display_id);
            }
            return err;
        };
        self.renderer_realized_retry.resolved();
    }
    if (surface_state.focused) |value| {
        self.applyFocused(value, external_drain) catch |err| {
            // Restore only into an empty slot. A newer publication must remain
            // authoritative over this failed request.
            self.surface_state_requests.restoreFocusedIfEmpty(value);
            if (surface_state.display_id) |display_id| {
                self.surface_state_requests.restoreDisplayIDIfEmpty(display_id);
            }
            return err;
        };
    }
    if (surface_state.display_id) |value| {
        self.applyDisplayID(value) catch |err| {
            self.surface_state_requests.restoreDisplayIDIfEmpty(value);
            return err;
        };
    }

    const wake_pending =
        self.mailbox.count(global.io()) > 0 or self.surface_state_requests.hasPending();
    if (external_drain) return .{ .wake_pending = wake_pending };

    // Hidden wakeups leave terminal dirty flags untouched. Rebuild exactly
    // once from their union before making the renderer visible again, then
    // present immediately. A full-redraw dirty bit remains authoritative
    // inside RenderState.update.
    var result = applyRendererVisibilityTransition(
        self,
        &self.visibility_regain,
        self.pendingRendererVisibilityTransition(),
    );
    result.wake_pending = wake_pending;
    return result;
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

fn applyRendererRealized(
    self: *Thread,
    request: RendererRealizedRequest,
) !void {
    if (request == .rebuild) {
        try self.applyRendererRealized(.unrealize);
        return self.applyRendererRealized(.realize);
    }

    const value = request == .realize;
    if (self.renderer_realized == value) return;

    if (value) {
        try self.renderer.displayRealized();
        self.renderer_realized = true;
        return;
    }

    // Stop presentation before releasing the swap chain. displayUnrealized
    // waits for in-flight frame leases, so no draw can retain a released
    // IOSurface after this call returns.
    self.visibility_regain.cancel();
    self.setRendererVisible(false);
    self.renderer.displayUnrealized();
    self.renderer_realized = false;
}

fn applyFocused(self: *Thread, value: bool, external_drain: bool) !void {
    if (self.flags.focused == value) return;

    // Commit the fallible renderer operation first. If it fails, the caller
    // can retain the request without the thread flag suppressing its retry.
    try self.renderer.setFocus(value);
    self.flags.focused = value;
    self.setQosClass();

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
    if (!self.renderer_realized) return false;
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
    if (!self.renderer_realized) return null;
    if (self.renderer_visible == self.flags.visible) return null;
    return self.flags.visible;
}

fn renderWakeFrame(self: *Thread) void {
    _ = renderCallback(self, undefined, undefined, {});
}

/// Trigger a draw. This will not update frame data or anything, it will
/// just trigger a draw/paint.
fn drawFrame(self: *Thread, now: bool) DrawFrameResult {
    if (!self.renderer_realized) return .skipped_invisible;

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
            .{ .redraw_surface = .{ .surface = self.surface } },
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
    t.armPendingRendererRealizedRetryTimer();
    if (t.externalDrainActive()) {
        // External mode owns renderer state on its serial queue. Convert the
        // coalesced xev wake into an unconditional embedder render request.
        // Unconditional scheduling closes the race where a producer publishes
        // after a pending-work check while this callback is still active.
        scheduleExternalRendererContinuation(t);
        return .rearm;
    }
    const regain_was_pending = t.visibility_regain.isPending();

    // When we wake up, we check the mailbox. Mailbox producers should
    // wake up our thread after publishing.
    const drain_result = t.drainMailbox() catch |err| fallback: {
        log.err("error draining mailbox err={}", .{err});
        break :fallback MailboxDrainResult{
            .wake_pending = t.mailbox.count(global.io()) > 0 or
                t.surface_state_requests.hasPending(),
        };
    };

    // Render immediately unless a successful visibility regain already did.
    renderAfterMailboxDrain(t, &t.visibility_regain, drain_result);
    if (regain_was_pending and !t.visibility_regain.isPending()) {
        t.syncDrawTimer();
    }

    // Producer notifications can coalesce with the wake currently being
    // handled. Render this finite snapshot before explicitly retaining another
    // turn. Recheck after rendering so work published during the render is
    // included rather than relying on its possibly coalesced notification.
    const wake_pending = drain_result.wake_pending or
        t.mailbox.count(global.io()) > 0 or t.surface_state_requests.hasPending();
    if (wake_pending) {
        t.wakeup.notify() catch |err| {
            log.warn("failed to continue pending renderer work err={}", .{err});
        };
    }

    // PageList mutations maintain their own compression dirty state. Checking
    // it here covers output, resize, and viewport scrolling uniformly.
    t.compression.wake(t);

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

fn scheduleRendererRealizedRetry(
    self: *Thread,
    value: RendererRealizedRequest,
) void {
    const request = self.renderer_realized_retry.failed(value) orelse return;
    self.scheduleRendererRealizedRetryTimer(request);
}

fn scheduleRendererRealizedRetryDelivery(
    self: *Thread,
    delivery: RendererRealizedRetryState.Delivery,
) void {
    const request =
        self.renderer_realized_retry.failedIfCurrent(delivery) orelse return;
    self.scheduleRendererRealizedRetryTimer(request);
}

fn scheduleRendererRealizedRetryTimer(
    self: *Thread,
    request: RendererRealizedRetryState.TimerRequest,
) void {
    if (self.externalDrainActive()) {
        self.renderer_realized_retry_timer_handoff.publish(request);
        self.wakeup.notify() catch |err| {
            log.warn(
                "failed to hand renderer realization retry to loop owner err={}",
                .{err},
            );
        };
        return;
    }
    self.armRendererRealizedRetryTimer(request);
}

fn armPendingRendererRealizedRetryTimer(self: *Thread) void {
    const request =
        self.renderer_realized_retry_timer_handoff.take() orelse return;
    self.armRendererRealizedRetryTimer(request);
}

fn armRendererRealizedRetryTimer(
    self: *Thread,
    request: RendererRealizedRetryState.TimerRequest,
) void {
    if (!self.renderer_realized_retry.timerWillArm(request)) return;
    self.renderer_realized_retry_h.reset(
        &self.loop,
        &self.renderer_realized_retry_c,
        &self.renderer_realized_retry_reset_c,
        request.delay_ms,
        Thread,
        self,
        rendererRealizedRetryCallback,
    );
}

fn rendererRealizedRetryCallback(
    self_: ?*Thread,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const self = self_ orelse return .disarm;
    _ = result catch |err| switch (err) {
        error.Canceled => {
            // `Timer.reset` cancels the previous deadline before arming the
            // replacement. The replacement still owns the retained value and
            // active latch, so this callback must not consume either.
            return .disarm;
        },
        else => {
            // Release the active-timer latch before rearming with the retained
            // latest value. Otherwise one backend timer error would suppress
            // every later renderer-realization retry.
            if (self.renderer_realized_retry.fired()) |delivery| {
                self.scheduleRendererRealizedRetryDelivery(delivery);
            }
            log.warn("error in renderer realization retry timer err={}", .{err});
            return .disarm;
        },
    };

    const delivery = self.renderer_realized_retry.fired() orelse return .disarm;
    if (!self.renderer_realized_retry.restoreIfCurrent(
        delivery,
        &self.surface_state_requests,
    )) return .disarm;
    self.wakeup.notify() catch |err| {
        log.warn("failed to notify renderer realization retry err={}", .{err});
    };
    return .disarm;
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
    if (!t.flags.visible or !t.renderer_realized) return .disarm;

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

test "synchronous renderer drains one finite batch and retains continuation" {
    const Context = struct {
        drains: usize = 0,
        continuations: usize = 0,

        fn drainMailbox(self: *@This()) !MailboxDrainResult {
            self.drains += 1;
            return .{ .wake_pending = true };
        }

        fn scheduleRendererContinuationIfNeeded(self: *@This()) void {
            self.continuations += 1;
        }
    };

    var context: Context = .{};
    try drainSynchronousMailbox(&context);
    try std.testing.expectEqual(@as(usize, 1), context.drains);
    try std.testing.expectEqual(@as(usize, 1), context.continuations);
}

test "synchronous renderer retains continuation after drain error" {
    const Context = struct {
        continuations: usize = 0,

        fn drainMailbox(_: *@This()) !MailboxDrainResult {
            return error.DrainFailed;
        }

        fn scheduleRendererContinuationIfNeeded(self: *@This()) void {
            self.continuations += 1;
        }
    };

    var context: Context = .{};
    try std.testing.expectError(
        error.DrainFailed,
        drainSynchronousMailbox(&context),
    );
    try std.testing.expectEqual(@as(usize, 1), context.continuations);
}

test "external redraw retries only the surface whose enqueue failed" {
    var queued: ExternalRedrawDelivery = .{};
    var failed: ExternalRedrawDelivery = .{};

    _ = queued.request().?;
    const failed_generation = failed.request().?;
    failed.enqueueFailed(failed_generation);

    try std.testing.expectEqual(
        @as(?u64, null),
        queued.retryFailedEnqueue(),
    );
    try std.testing.expectEqual(
        failed_generation,
        failed.retryFailedEnqueue().?,
    );
    try std.testing.expectEqual(
        @as(?u64, null),
        failed.retryFailedEnqueue(),
    );
}

test "external redraw host rejection releases and preserves later wakes" {
    var delivery: ExternalRedrawDelivery = .{};

    // A rejected action without a newer wake is released. A later wake can
    // enqueue again instead of remaining latched behind the rejected action.
    const first = delivery.request().?;
    try std.testing.expect(!delivery.actionCompleted(first, false));
    const second = delivery.request().?;

    // A wake coalesced behind an outstanding action must survive rejection.
    try std.testing.expectEqual(@as(?u64, null), delivery.request());
    try std.testing.expect(delivery.actionCompleted(second, false));
    try std.testing.expectEqual(
        @as(?u64, null),
        delivery.retryFailedEnqueue(),
    );
    const third = delivery.request().?;
    try std.testing.expect(third != second);
}

test "external render start consumes queued and coalesced wakes" {
    var delivery: ExternalRedrawDelivery = .{};
    const first = delivery.request().?;
    try std.testing.expectEqual(@as(?u64, null), delivery.request());

    delivery.renderStarted();
    const second = delivery.request().?;
    try std.testing.expect(first != second);
}

test "external redraw stale acknowledgment cannot clear a newer request" {
    var delivery: ExternalRedrawDelivery = .{};

    const first = delivery.request().?;
    delivery.renderStarted();
    const second = delivery.request().?;
    try std.testing.expect(first != second);

    try std.testing.expect(!delivery.actionCompleted(first, false));
    delivery.enqueueFailed(second);
    try std.testing.expectEqual(
        second,
        delivery.retryFailedEnqueue().?,
    );
}

test "surface lifecycle state bypasses a full renderer mailbox and keeps latest values" {
    const mailbox = try Mailbox.create(std.testing.allocator);
    defer mailbox.destroy(std.testing.allocator);

    for (0..64) |_| {
        try std.testing.expect(mailbox.push(
            global.io(),
            .{ .visible = false },
            .{ .instant = {} },
        ) != 0);
    }
    try std.testing.expectEqual(
        @as(Mailbox.Size, 0),
        mailbox.push(
            global.io(),
            .{ .visible = false },
            .{ .instant = {} },
        ),
    );

    var state: SurfaceStateRequests = .{};
    state.publishVisible(false);
    state.publishVisible(true);
    state.publishRendererRealized(false);
    state.publishRendererRealized(true);
    state.publishFocused(false);
    state.publishDisplayID(7);
    state.publishDisplayID(42);

    const update = state.take();
    try std.testing.expectEqual(true, update.visible);
    try std.testing.expectEqual(
        RendererRealizedRequest.realize,
        update.renderer_realized,
    );
    try std.testing.expectEqual(false, update.focused);
    try std.testing.expectEqual(@as(u32, 42), update.display_id);
    try std.testing.expectEqual(
        @as(Mailbox.Size, 0),
        mailbox.push(
            global.io(),
            .{ .visible = false },
            .{ .instant = {} },
        ),
    );
}

test "renderer rebuild survives a redundant realize publication" {
    var state: SurfaceStateRequests = .{};

    state.publishRendererRebuild();
    state.publishRendererRealized(true);

    const update = state.take();
    try std.testing.expectEqual(
        .rebuild,
        update.renderer_realized.?,
    );
}

test "renderer unrealize supersedes a pending rebuild" {
    var state: SurfaceStateRequests = .{};

    state.publishRendererRebuild();
    state.publishRendererRealized(false);

    const update = state.take();
    try std.testing.expectEqual(
        .unrealize,
        update.renderer_realized.?,
    );
}

test "surface lifecycle retry restoration preserves newer publications" {
    var state: SurfaceStateRequests = .{};
    try std.testing.expect(!state.hasPending());

    state.restoreFocusedIfEmpty(false);
    state.restoreRendererRealizedIfEmpty(.unrealize);
    state.restoreDisplayIDIfEmpty(7);
    try std.testing.expect(state.hasPending());
    const restored = state.take();
    try std.testing.expectEqual(false, restored.focused);
    try std.testing.expectEqual(
        RendererRealizedRequest.unrealize,
        restored.renderer_realized,
    );
    try std.testing.expectEqual(@as(u32, 7), restored.display_id);
    try std.testing.expect(!state.hasPending());

    state.publishFocused(true);
    state.publishRendererRealized(true);
    state.publishDisplayID(42);
    state.restoreFocusedIfEmpty(false);
    state.restoreRendererRealizedIfEmpty(.unrealize);
    state.restoreDisplayIDIfEmpty(7);
    const newer = state.take();
    try std.testing.expectEqual(true, newer.focused);
    try std.testing.expectEqual(
        RendererRealizedRequest.realize,
        newer.renderer_realized,
    );
    try std.testing.expectEqual(@as(u32, 42), newer.display_id);
}

test "renderer realization retries coalesce with bounded backoff" {
    const testing = std.testing;

    var retry: RendererRealizedRetryState = .{};
    const first = retry.failed(.realize).?;
    try testing.expectEqual(@as(u64, 250), first.delay_ms);
    try testing.expect(retry.failed(.unrealize) == null);
    try testing.expect(retry.timerWillArm(first));
    try testing.expectEqual(
        RendererRealizedRequest.unrealize,
        retry.fired().?.value,
    );

    const superseded = retry.failed(.realize).?;
    try testing.expectEqual(@as(u64, 500), superseded.delay_ms);
    try testing.expect(retry.timerWillArm(superseded));
    retry.supersede();
    try testing.expect(retry.fired() == null);

    const third = retry.failed(.realize).?;
    try testing.expectEqual(@as(u64, 1_000), third.delay_ms);
    try testing.expect(retry.timerWillArm(third));
    try testing.expectEqual(
        RendererRealizedRequest.realize,
        retry.fired().?.value,
    );
    // A timer backend error consumes the active latch before the callback
    // reschedules the retained value at the next paced delay.
    const backend_error = retry.failed(.realize).?;
    try testing.expectEqual(@as(u64, 2_000), backend_error.delay_ms);
    try testing.expect(retry.timerWillArm(backend_error));
    const failed_timer_delivery = retry.fired().?;
    const backend_retry = retry.failedIfCurrent(failed_timer_delivery).?;
    try testing.expectEqual(@as(u64, 4_000), backend_retry.delay_ms);
    try testing.expect(retry.timerWillArm(backend_retry));
    _ = retry.fired();
    retry.resolved();
    const resolved_retry = retry.failed(.realize).?;
    try testing.expectEqual(@as(u64, 250), resolved_retry.delay_ms);
    try testing.expect(retry.timerWillArm(resolved_retry));
    _ = retry.fired();

    retry.delay_ms = RendererRealizedRetryState.maximum_delay_ms;
    const maximum = retry.failed(.realize).?;
    try testing.expectEqual(
        @as(u64, RendererRealizedRetryState.maximum_delay_ms),
        maximum.delay_ms,
    );
    try testing.expect(retry.timerWillArm(maximum));
    _ = retry.fired();
    const capped = retry.failed(.realize).?;
    try testing.expectEqual(
        @as(u64, RendererRealizedRetryState.maximum_delay_ms),
        capped.delay_ms,
    );
    try testing.expect(retry.timerWillArm(capped));
}

test "resolved renderer realization retry resets an active deadline" {
    const testing = std.testing;

    var retry: RendererRealizedRetryState = .{};
    retry.delay_ms = RendererRealizedRetryState.maximum_delay_ms;
    const obsolete = retry.failed(.realize).?;
    try testing.expectEqual(
        @as(u64, RendererRealizedRetryState.maximum_delay_ms),
        obsolete.delay_ms,
    );
    try testing.expect(retry.timerWillArm(obsolete));

    // A successful hide can resolve the failed restore before its old timer
    // fires. The next visible restore failure must start a fresh backoff rather
    // than inheriting the remainder of the obsolete maximum deadline.
    retry.resolved();
    const fresh = retry.failed(.realize).?;
    try testing.expectEqual(@as(u64, 250), fresh.delay_ms);

    // If the old timer expires before the loop processes the reset handoff, it
    // must not claim the fresh generation's delivery.
    try testing.expect(retry.fired() == null);
    try testing.expect(retry.timerWillArm(fresh));
    try testing.expectEqual(
        RendererRealizedRequest.realize,
        retry.fired().?.value,
    );
}

test "external renderer retry timer is handed to loop owner once" {
    var retry: RendererRealizedRetryState = .{};
    var handoff: RendererRealizedRetryTimerHandoff = .{};

    retry.delay_ms = RendererRealizedRetryState.maximum_delay_ms;
    const obsolete = retry.failed(.realize).?;
    retry.resolved();
    const fresh = retry.failed(.realize).?;

    // A stale callback can publish after a fresh external failure. Preserve
    // the higher lifecycle generation regardless of publication order.
    handoff.publish(fresh);
    handoff.publish(obsolete);

    try std.testing.expectEqual(
        @as(?RendererRealizedRetryState.TimerRequest, fresh),
        handoff.take(),
    );
    try std.testing.expect(handoff.take() == null);
}

test "stale external renderer retry cannot override newer publication" {
    var retry: RendererRealizedRetryState = .{};
    var requests: SurfaceStateRequests = .{};

    const request = retry.failed(.realize).?;
    try std.testing.expect(retry.timerWillArm(request));
    const claimed = retry.fired().?;

    retry.published();
    requests.publishRendererRealized(false);
    const newer = requests.take();
    try std.testing.expectEqual(
        RendererRealizedRequest.unrealize,
        newer.renderer_realized,
    );

    try std.testing.expect(retry.failedIfCurrent(claimed) == null);
    try std.testing.expect(!retry.restoreIfCurrent(claimed, &requests));
    try std.testing.expectEqual(
        @as(?RendererRealizedRequest, null),
        requests.take().renderer_realized,
    );
}

test "claiming newer renderer request invalidates retry atomically" {
    var retry: RendererRealizedRetryState = .{};
    var requests: SurfaceStateRequests = .{};

    // Request A was claimed and is still being applied when newer request B
    // publishes. A then fails and samples B's current generation.
    retry.published();
    requests.publishRendererRealized(false);
    const request = retry.failed(.realize).?;
    try std.testing.expect(retry.timerWillArm(request));
    const stale = retry.fired().?;

    // The external queue claims B before the timer callback resumes. Claiming
    // and invalidation must be one critical section so A cannot restore into
    // the newly empty atomic slot.
    const newer = retry.takeSurfaceState(&requests);
    try std.testing.expectEqual(
        RendererRealizedRequest.unrealize,
        newer.renderer_realized,
    );
    try std.testing.expect(!retry.restoreIfCurrent(stale, &requests));
    try std.testing.expectEqual(
        @as(?RendererRealizedRequest, null),
        requests.take().renderer_realized,
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
            defer thread.state.mutex.unlock(global.io());
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
        defer state.mutex.unlock(global.io());

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
