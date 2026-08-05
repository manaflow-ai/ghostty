//! This is the render state that is given to a renderer.

const State = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Inspector = @import("../inspector/main.zig").Inspector;
const terminalpkg = @import("../terminal/main.zig");
const inputpkg = @import("../input.zig");
const renderer = @import("../renderer.zig");

/// The mutex that must be held while reading any of the data in the
/// members of this state. Note that the state itself is NOT protected
/// by the mutex and is NOT thread-safe, only the members values of the
/// state (i.e. the terminal, devmode, etc. values).
mutex: *std.Io.Mutex,

/// The terminal data.
terminal: *terminalpkg.Terminal,

/// The terminal inspector, if any. This will be null while the inspector
/// is not active and will be set when it is active.
inspector: ?*Inspector = null,

/// Dead key state. This will render the current dead key preedit text
/// over the cursor. This currently only ever renders a single codepoint.
/// Preedit can in theory be multiple codepoints long but that is left as
/// a future exercise.
preedit: ?Preedit = null,

/// Mouse state. This only contains state relevant to what renderers
/// need about the mouse.
mouse: Mouse = .{},

/// The number of threads currently waiting to acquire `mutex` via
/// `lockDemand`. This is not protected by the mutex; it is read by
/// hot lock/unlock loops (the IO parse thread) in `yieldToDemand` to
/// decide whether to hand the mutex off before relocking it.
demand: std.atomic.Value(u32) = .init(0),

/// Handoff generation counter. Incremented (with a futex wake) by
/// `unlockDemand` after a demanding waiter releases the mutex, so that
/// `yieldToDemand` knows the waiter had its turn.
handoff_gen: std.atomic.Value(u32) = .init(0),

/// How long `yieldToDemand` sleeps waiting for a demanding waiter to
/// take its turn before giving up. This bounds how long the IO parse
/// thread can stall if a wake is lost or the waiter is descheduled; a
/// demanding critical section (the renderer's frame snapshot) is
/// microseconds, so one millisecond is generous.
const handoff_timeout_ns = 1 * std.time.ns_per_ms;

/// Acquire `mutex` while signaling demand for it. Use this instead of
/// locking the mutex directly on threads that must not be starved by
/// a hot lock/unlock loop (the renderer's frame snapshot). Must be
/// released with `unlockDemand`; releasing with `mutex.unlock` keeps
/// the data safe but makes parked `yieldToDemand` callers wait out
/// their full timeout.
///
/// Both `std.Io.Mutex` and os_unfair_lock are unfair: a running
/// thread that unlocks and immediately relocks beats a sleeping
/// waiter every time, because the waiter must first be woken and
/// scheduled. Under sustained pty output the IO parse thread is
/// exactly such a loop, so without this signal the renderer can
/// starve for as long as the output lasts.
pub fn lockDemand(self: *State, io: std.Io) void {
    _ = self.demand.fetchAdd(1, .monotonic);
    self.mutex.lockUncancelable(io);
    const prev = self.demand.fetchSub(1, .monotonic);
    assert(prev > 0);
}

/// Release `mutex` acquired via `lockDemand` and notify hot loops
/// parked in `yieldToDemand` that the demanding waiter had its turn.
pub fn unlockDemand(self: *State, io: std.Io) void {
    self.mutex.unlock(io);
    _ = self.handoff_gen.fetchAdd(1, .monotonic);
    io.futexWake(@TypeOf(self.handoff_gen), &self.handoff_gen, 1);
}

/// Called by hot lock/unlock loops between critical sections, with
/// `mutex` NOT held: if a `lockDemand` waiter exists, sleep until it
/// has acquired and released the mutex (or the timeout passes). This
/// is the handoff that unfair mutexes never do on their own.
///
/// The orderings here are all monotonic because these atomics are a
/// scheduling heuristic, not a synchronization boundary: the mutex
/// itself orders the protected data, and the timeout bounds any
/// staleness.
pub fn yieldToDemand(self: *State, io: std.Io) void {
    if (self.demand.load(.monotonic) == 0) return;

    // Snapshot the generation before rechecking demand: if the waiter
    // acquires and releases between our check and the wait below, the
    // generation no longer matches and timedWait returns immediately.
    const gen = self.handoff_gen.load(.monotonic);
    if (self.demand.load(.monotonic) == 0) return;
    io.futexWaitTimeout(
        @TypeOf(self.handoff_gen),
        &self.handoff_gen,
        .init(gen),
        .{ .duration = .{ .raw = .fromNanoseconds(handoff_timeout_ns), .clock = .awake } },
    ) catch {};
}

pub const Mouse = struct {
    /// The point on the viewport where the mouse currently is. We use
    /// viewport points to avoid the complexity of mapping the mouse to
    /// the renderer state.
    point: ?terminalpkg.point.Coordinate = null,

    /// The mods that are currently active for the last mouse event.
    /// This could really just be mods in general and we probably will
    /// move it out of mouse state at some point.
    mods: inputpkg.Mods = .{},

    // cmux fork: (B) ExternalHover — a lock-protected, mouse-move-driven
    // identity distinct from `point`/`mods` above. `point` only tracks
    // cells where *native* hover found a link and resets whenever it
    // doesn't (see `Surface.cursorPosCallback`); the embedding host needs
    // every in-bounds cell regardless of native hover's own outcome.

    /// Updated on every in-bounds mouse event, independent of whether
    /// native link hover resolved anything this event. `null` outside the
    /// viewport.
    pointer_cell: ?terminalpkg.point.Coordinate = null,

    /// (B) flicker fix §3 — renamed from `hover_input_epoch`: role
    /// narrowed to normalized-mods and hover-eligibility ABA guarding
    /// only. A plain in-bounds cell change no longer bumps this —
    /// `ExternalHover.validateOrInvalidate`'s range-containment check
    /// decides in-range validity, and `Surface.cursorPosCallback`'s
    /// input-time `invalidateIfPointerLeftRanges` call decides range/
    /// viewport exit immediately, rather than waiting for this epoch to
    /// go stale on the next render frame (which could miss an
    /// A->outside->A sequence coalesced within a single frame).
    hover_context_epoch: u64 = 0,

    /// Whether link hover (native or external) is currently permitted.
    /// Computed by the input path under this same mutex; the renderer
    /// thread never reads `Surface.mouse` directly to derive this.
    hover_eligible: bool = true,

    /// The embedding host's resolved hover override, when active. See
    /// `renderer/link.zig`'s `ExternalHover` doc for the full contract.
    external_hover: renderer.link.ExternalHover = .{},

    /// The last `(token, active)` pair delivered to the apprt via an
    /// `ExternalHoverTransition` snapshot. Compared each render frame
    /// against the current `external_hover` state to detect a change
    /// worth notifying; read/written only from the render loop under this
    /// mutex, never touched by the input path.
    external_hover_last_delivered_token: renderer.link.HoverActivationToken = .zero,
    external_hover_last_delivered_active: bool = false,

    /// At most one not-yet-delivered transition. Set by the render loop
    /// under this mutex; fetched-and-cleared by
    /// `Thread.notifyExternalHoverTransition` under a brief, separate
    /// acquisition of this same mutex (mirroring the existing
    /// `notifySelectionChanged` precedent) — the actual apprt call always
    /// happens after that acquisition ends, never while holding it.
    external_hover_pending_transition: ?renderer.link.ExternalHoverTransition = null,

    /// (B) wiring review Blocking 5 — the ack reducer's own record of
    /// what the apprt has actually confirmed, per final-spec's ack
    /// semantics table. Distinct from `external_hover_last_delivered_*`
    /// above, which only tracks what this thread last HANDED to the
    /// apprt, not what it acked. Read/written only by
    /// `Thread.notifyExternalHoverTransition`'s ack reducer, under a
    /// brief separate mutex acquisition — never inside the render loop's
    /// own critical section.
    external_hover_ack_last_published: renderer.link.HoverActivationToken = .zero,
    /// An `inactive` transition whose ack came back false/error, staged
    /// for exactly one bounded retry. Never an unconditional resend loop:
    /// `external_hover_ack_retry_attempted` bounds this to one attempt
    /// per token.
    external_hover_ack_pending_retry: ?renderer.link.ExternalHoverTransition = null,
    /// Whether the current `external_hover_ack_pending_retry` token has
    /// already had its one retry attempt. Reset only when a genuinely new
    /// transition (not a retry) is fetched.
    external_hover_ack_retry_attempted: bool = false,

    /// (B) flicker fix (review-flicker-fix-confirm.md §1) — the pure
    /// state transition `Surface.cursorPosCallback` applies to
    /// `pointer_cell`/`external_hover` for one cursor position update.
    /// Extracted onto `Mouse` itself (a plain struct with no apprt/config
    /// dependency) specifically so it's unit-testable without a live
    /// `Surface` — there is no lightweight `Surface` test fixture in this
    /// codebase, and building one is out of scope for a correctness fix.
    ///
    /// - `new_pointer_cell`: the real, non-clamped in-viewport cell, or
    ///   `null` for a viewport-exit event. Callers MUST pass `null` for
    ///   viewport exit — never `posToViewport`'s result for a negative
    ///   position, which clamps to `(0, 0)` rather than signaling
    ///   out-of-bounds. Passing that clamped value through unconditionally
    ///   was the pre-existing bug review-flicker-fix-confirm.md §1 found:
    ///   a viewport-exit event would silently look like a legitimate move
    ///   to cell `(0, 0)`, which could then wrongly re-validate an active
    ///   override whose ranges happen to include it.
    ///
    /// Always updates `pointer_cell`, then destructively invalidates
    /// `external_hover` immediately if it's active and `new_pointer_cell`
    /// is outside its ranges (or `null`) — see
    /// `link.ExternalHover.invalidateIfPointerLeftRanges`'s doc for why
    /// this can't wait for the next render frame.
    ///
    /// - Returns whether an active override was just invalidated, so the
    ///   caller can conditionally mark the hover row dirty and queue a
    ///   render.
    pub fn updateExternalHoverPointerCell(
        self: *Mouse,
        new_pointer_cell: ?terminalpkg.point.Coordinate,
    ) bool {
        self.pointer_cell = new_pointer_cell;
        return self.external_hover.invalidateIfPointerLeftRanges(new_pointer_cell);
    }
};

/// The pre-edit state. See Surface.preeditCallback for more information.
pub const Preedit = struct {
    /// The codepoints to render as preedit text.
    codepoints: []const Codepoint = &.{},

    /// A single codepoint to render as preedit text.
    pub const Codepoint = struct {
        codepoint: u21,
        wide: bool = false,
    };

    /// Deinit this preedit that was cre
    pub fn deinit(self: *const Preedit, alloc: Allocator) void {
        alloc.free(self.codepoints);
    }

    /// Allocate a copy of this preedit in the given allocator..
    pub fn clone(self: *const Preedit, alloc: Allocator) !Preedit {
        return .{
            .codepoints = try alloc.dupe(Codepoint, self.codepoints),
        };
    }

    /// The width in cells of all codepoints in the preedit.
    pub fn width(self: *const Preedit) usize {
        var result: usize = 0;
        for (self.codepoints) |cp| {
            result += if (cp.wide) 2 else 1;
        }

        return result;
    }

    /// Range returns the start and end x position of the preedit text
    /// along with any codepoint offset necessary to fit the preedit
    /// into the available space.
    pub fn range(
        self: *const Preedit,
        start: terminalpkg.size.CellCountInt,
        max: terminalpkg.size.CellCountInt,
    ) struct {
        start: terminalpkg.size.CellCountInt,
        end: terminalpkg.size.CellCountInt,
        cp_offset: usize,
    } {
        // If our width is greater than the number of cells we have
        // then we need to adjust our codepoint start to a point where
        // our width would be less than the number of cells we have.
        const w, const cp_offset = width: {
            // max is inclusive, so we need to add 1 to it.
            const max_width = max - start + 1;

            // Rebuild our width in reverse order. This is because we want
            // to offset by the end cells, not the start cells (if we have to).
            var w: terminalpkg.size.CellCountInt = 0;
            for (0..self.codepoints.len) |i| {
                const reverse_i = self.codepoints.len - i - 1;
                const cp = self.codepoints[reverse_i];
                w += if (cp.wide) 2 else 1;
                if (w > max_width) {
                    break :width .{ w, reverse_i };
                }
            }

            // Width fit in the max width so no offset necessary.
            break :width .{ w, 0 };
        };

        // If our preedit goes off the end of the screen, we adjust it so
        // that it shifts left.
        const end = if (w > 0) start + (w - 1) else start;
        const start_offset = if (end > max) end - max else 0;
        return .{
            .start = start -| start_offset,
            .end = end -| start_offset,
            .cp_offset = cp_offset,
        };
    }
};

const test_hangul_ga: u21 = 0xAC00; // U+AC00 HANGUL SYLLABLE GA

test "preedit range covers exact cell width" {
    const testing = std.testing;

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = 'a' }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }

    {
        const p: Preedit = .{
            .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
        };
        const range = p.range(2, 9);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 2), range.start);
        try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 3), range.end);
        try testing.expectEqual(@as(usize, 0), range.cp_offset);
    }
}

test "preedit range shifts left at right edge" {
    const testing = std.testing;

    const p: Preedit = .{
        .codepoints = &.{.{ .codepoint = test_hangul_ga, .wide = true }},
    };
    const range = p.range(9, 9);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 8), range.start);
    try testing.expectEqual(@as(terminalpkg.size.CellCountInt, 9), range.end);
    try testing.expectEqual(@as(usize, 0), range.cp_offset);
}

// impl-flicker-fix — review-flicker-fix-confirm.md §1 / §5 items 3-4.
// `Mouse` is a plain struct (no apprt/config dependency), so
// `updateExternalHoverPointerCell` is testable directly without a live
// `Surface` — there is no lightweight `Surface` test fixture in this
// codebase to build a "Surface-level" test against otherwise, but this
// exercises the exact same pure state transition `cursorPosCallback`
// calls into, real state transitions end to end (not source-shape
// assertions).

test "Mouse.updateExternalHoverPointerCell invalidates on gap cells, out-of-range cells, and viewport exit" {
    const testing = std.testing;
    var mouse: Mouse = .{};
    const token: renderer.link.HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: renderer.link.PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };

    // Two ranges on the same row with a gap between them: [0, 2) and
    // [5, 7). A cell in the gap is in-scope (same row) but in neither
    // range.
    try testing.expect(mouse.external_hover.set(token, physical, 0, .{ .x = 0, .y = 0 }, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
        .{ .row = 0, .start_column = 5, .end_column = 7 },
    }));
    mouse.pointer_cell = .{ .x = 0, .y = 0 };
    try testing.expect(mouse.updateExternalHoverPointerCell(.{ .x = 3, .y = 0 }));
    try testing.expect(!mouse.external_hover.active());

    // Re-set, then move to a cell on a DIFFERENT row than any range —
    // out of scope entirely, not just a gap.
    try testing.expect(mouse.external_hover.set(token, physical, 0, .{ .x = 0, .y = 0 }, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }));
    try testing.expect(mouse.updateExternalHoverPointerCell(.{ .x = 0, .y = 9 }));
    try testing.expect(!mouse.external_hover.active());

    // Re-set, then leave the viewport entirely (`null`).
    try testing.expect(mouse.external_hover.set(token, physical, 0, .{ .x = 0, .y = 0 }, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }));
    try testing.expect(mouse.updateExternalHoverPointerCell(null));
    try testing.expect(!mouse.external_hover.active());
    try testing.expect(mouse.pointer_cell == null);

    // review-flicker-fix-confirm.md §1's negative-position `(0, 0)` clamp
    // finding: even if a LATER call wrongly passed `(0, 0)` as though it
    // were a real in-viewport cell inside what USED to be the active
    // override's own ranges, invalidation is one-way (see `ExternalHover`'s
    // ABA doc) — there is nothing left to resurrect. This is exactly what
    // `Surface.cursorPosCallback`'s `is_out_of_viewport` guard prevents by
    // never passing `posToViewport`'s clamped result through as
    // `new_pointer_cell` for a negative position in the first place.
    try testing.expect(!mouse.updateExternalHoverPointerCell(.{ .x = 0, .y = 0 }));
    try testing.expect(!mouse.external_hover.active());
}

test "Mouse.updateExternalHoverPointerCell closes the A->outside->A ABA case through input processing alone" {
    const testing = std.testing;
    var mouse: Mouse = .{};
    const token: renderer.link.HoverActivationToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const physical: renderer.link.PhysicalSnapshotToken = .{ .bits = .{ 1, 1, 1, 1 } };
    const cell_a: terminalpkg.point.Coordinate = .{ .x = 0, .y = 0 };
    const outside: terminalpkg.point.Coordinate = .{ .x = 9, .y = 9 };

    try testing.expect(mouse.external_hover.set(token, physical, 0, cell_a, 0, 1, &.{
        .{ .row = 0, .start_column = 0, .end_column = 2 },
    }));
    mouse.pointer_cell = cell_a;

    // A -> outside -> A, entirely through input processing (this method)
    // — no render frame (no call to `validateOrInvalidate`) ever observes
    // any of this, the exact coalescing hazard review-flicker-fix-confirm.md
    // §1 requires closing at input time instead.
    try testing.expect(mouse.updateExternalHoverPointerCell(outside));
    try testing.expect(!mouse.external_hover.active());
    _ = mouse.updateExternalHoverPointerCell(cell_a);

    // The old override must NOT be active again just because the pointer
    // coincidentally returned to its original cell — only a fresh `set`
    // can reactivate it.
    try testing.expect(!mouse.external_hover.active());
}
