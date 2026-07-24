const std = @import("std");

/// A token identifies one exact swap-chain slot for one acquisition of that
/// slot. Tokens are never zero, and a token becomes invalid as soon as its
/// slot is returned to the pool.
pub const Token = u64;

/// Thread-safe ownership tracking for a fixed-size renderer swap chain.
///
/// GPU completion callbacks and external compositors can finish frames in a
/// different order than the renderer submitted them. A counting semaphore by
/// itself only tracks how many slots are free; this pool additionally tracks
/// which exact slot is free so an out-of-order host release cannot cause the
/// renderer to reuse an IOSurface that is still being displayed.
pub fn Pool(comptime slot_count: usize) type {
    if (slot_count == 0) @compileError("a frame lease pool needs at least one slot");

    return struct {
        const Self = @This();

        pub const Lease = struct {
            slot: std.math.IntFittingRange(0, slot_count - 1),
            token: Token,
        };

        const SlotState = enum {
            free,
            gpu,
            presenting,
            host,
            deinit,
        };

        const Slot = struct {
            state: SlotState = .free,
            token: Token = 0,

            /// A host can release on another thread before its presentation
            /// callback has returned. Remember that release until the callback
            /// disposition is known so the permit is posted exactly once.
            release_pending: bool = false,
        };

        mutex: std.Thread.Mutex = .{},
        available: std.Thread.Semaphore = .{ .permits = slot_count },
        slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
        next_token: Token = 0,
        defunct: bool = false,
        /// Round-robin start for the next acquire. A fully serial producer
        /// (iOS `render_now`: each frame completes before the next acquire)
        /// always finds slot 0 free, so a first-free scan hands out the SAME
        /// IOSurface every frame - and Core Animation dedupes same-object
        /// `contents` assignments, leaving presented pixels frozen while the
        /// GPU keeps drawing into the surface. Rotating the start guarantees
        /// consecutive frames present distinct surfaces, like a pipelined
        /// producer does naturally.
        next_slot: usize = 0,

        /// Acquire one exact free slot. A null timeout waits indefinitely.
        pub fn acquire(
            self: *Self,
            timeout_ns: ?u64,
        ) error{ Defunct, Timeout }!Lease {
            if (timeout_ns) |timeout| {
                try self.available.timedWait(timeout);
            } else {
                self.available.wait();
            }
            errdefer self.available.post();

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.defunct) return error.Defunct;

            for (0..self.slots.len) |offset| {
                const index = (self.next_slot + offset) % self.slots.len;
                const slot = &self.slots[index];
                if (slot.state != .free) continue;

                const token = self.freshTokenLocked();
                slot.* = .{
                    .state = .gpu,
                    .token = token,
                };
                self.next_slot = (index + 1) % self.slots.len;
                return .{
                    .slot = @intCast(index),
                    .token = token,
                };
            }

            // Every permit corresponds to exactly one `.free` slot.
            unreachable;
        }

        /// Transition a GPU-complete frame before invoking a leased external
        /// presentation callback. This must happen before the callback because
        /// another process may release the token while the callback is running.
        pub fn beginPresentation(self: *Self, token: Token) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const slot = self.findLocked(token) orelse return false;
            if (slot.state != .gpu) return false;
            slot.state = .presenting;
            return true;
        }

        /// Finish GPU completion and callback dispatch. `host_acquired` is the
        /// callback disposition. Returns false for an unknown token or invalid
        /// transition; successful calls either transfer the exact slot to the
        /// host or return its permit to the renderer.
        pub fn finish(self: *Self, token: Token, host_acquired: bool) bool {
            var post = false;

            self.mutex.lock();
            const slot = self.findLocked(token) orelse {
                self.mutex.unlock();
                return false;
            };
            switch (slot.state) {
                .gpu => {
                    if (host_acquired) {
                        self.mutex.unlock();
                        return false;
                    }
                    slot.* = .{};
                    post = true;
                },
                .presenting => {
                    if (host_acquired and !slot.release_pending) {
                        slot.state = .host;
                    } else {
                        slot.* = .{};
                        post = true;
                    }
                },
                else => {
                    self.mutex.unlock();
                    return false;
                },
            }
            self.mutex.unlock();

            if (post) self.available.post();
            return true;
        }

        /// Release a frame acquired by an external presentation callback.
        /// Duplicate, stale, unknown, and not-yet-presented tokens return false.
        pub fn releaseHost(self: *Self, token: Token) bool {
            var post = false;

            self.mutex.lock();
            const slot = self.findLocked(token) orelse {
                self.mutex.unlock();
                return false;
            };
            switch (slot.state) {
                .presenting => {
                    if (slot.release_pending) {
                        self.mutex.unlock();
                        return false;
                    }
                    slot.release_pending = true;
                },
                .host => {
                    slot.* = .{};
                    post = true;
                },
                else => {
                    self.mutex.unlock();
                    return false;
                },
            }
            self.mutex.unlock();

            if (post) self.available.post();
            return true;
        }

        /// Prevent new acquisitions. Existing GPU and host owners may still
        /// finish so teardown can safely wait for their exact slots.
        pub fn beginDeinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.defunct = true;
        }

        /// Consume one free slot for teardown and return its exact index.
        pub fn takeForDeinit(
            self: *Self,
            timeout_ns: ?u64,
        ) error{Timeout}!std.math.IntFittingRange(0, slot_count - 1) {
            if (timeout_ns) |timeout| {
                try self.available.timedWait(timeout);
            } else {
                self.available.wait();
            }

            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state != .free) continue;
                slot.state = .deinit;
                return @intCast(index);
            }

            // Every permit corresponds to exactly one `.free` slot.
            unreachable;
        }

        fn findLocked(self: *Self, token: Token) ?*Slot {
            if (token == 0) return null;
            for (&self.slots) |*slot| {
                if (slot.token == token and slot.state != .free and
                    slot.state != .deinit) return slot;
            }
            return null;
        }

        fn freshTokenLocked(self: *Self) Token {
            while (true) {
                self.next_token +%= 1;
                if (self.next_token == 0) continue;
                if (self.findLocked(self.next_token) == null) return self.next_token;
            }
        }
    };
}

test "frame lease pool reuses the exact out-of-order released slot" {
    const LeasePool = Pool(3);
    var pool: LeasePool = .{};

    const first = try pool.acquire(null);
    const second = try pool.acquire(null);
    const third = try pool.acquire(null);

    try std.testing.expect(pool.beginPresentation(first.token));
    try std.testing.expect(pool.finish(first.token, true));
    try std.testing.expect(pool.beginPresentation(second.token));
    try std.testing.expect(pool.finish(second.token, true));
    try std.testing.expect(pool.beginPresentation(third.token));
    try std.testing.expect(pool.finish(third.token, true));

    try std.testing.expect(pool.releaseHost(second.token));
    try std.testing.expect(!pool.releaseHost(second.token));

    const replacement = try pool.acquire(null);
    try std.testing.expectEqual(second.slot, replacement.slot);
    try std.testing.expect(replacement.token != second.token);

    try std.testing.expect(pool.finish(replacement.token, false));
    try std.testing.expect(pool.releaseHost(first.token));
    try std.testing.expect(pool.releaseHost(third.token));
}

test "frame lease pool accepts release racing the presentation callback" {
    const LeasePool = Pool(1);
    var pool: LeasePool = .{};

    const lease = try pool.acquire(null);
    try std.testing.expect(pool.beginPresentation(lease.token));
    try std.testing.expect(pool.releaseHost(lease.token));
    try std.testing.expect(!pool.releaseHost(lease.token));

    // The callback subsequently says acquire, but the early release wins and
    // makes this exact slot immediately available once callback dispatch ends.
    try std.testing.expect(pool.finish(lease.token, true));
    const replacement = try pool.acquire(null);
    try std.testing.expectEqual(lease.slot, replacement.slot);
    try std.testing.expect(replacement.token != lease.token);
    try std.testing.expect(!pool.releaseHost(lease.token));
    try std.testing.expect(pool.finish(replacement.token, false));
}

test "frame lease pool rejects host release before presentation" {
    const LeasePool = Pool(1);
    var pool: LeasePool = .{};
    const lease = try pool.acquire(null);

    try std.testing.expect(!pool.releaseHost(lease.token));
    try std.testing.expect(!pool.releaseHost(0));
    try std.testing.expect(!pool.releaseHost(999));
    try std.testing.expect(pool.finish(lease.token, false));
}

test "frame lease pool teardown consumes exact slots" {
    const LeasePool = Pool(2);
    var pool: LeasePool = .{};

    const gpu_done = try pool.acquire(null);
    const host_owned = try pool.acquire(null);
    try std.testing.expect(pool.finish(gpu_done.token, false));
    try std.testing.expect(pool.beginPresentation(host_owned.token));
    try std.testing.expect(pool.finish(host_owned.token, true));

    pool.beginDeinit();
    try std.testing.expectEqual(
        gpu_done.slot,
        try pool.takeForDeinit(null),
    );
    try std.testing.expect(pool.releaseHost(host_owned.token));
    try std.testing.expectEqual(
        host_owned.slot,
        try pool.takeForDeinit(null),
    );
    try std.testing.expect(!pool.releaseHost(host_owned.token));
}
