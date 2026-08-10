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

        io: std.Io = std.Io.failing,
        mutex: std.Io.Mutex = .init,
        available: std.Io.Semaphore = .{ .permits = slot_count },
        slots: [slot_count]Slot = [_]Slot{.{}} ** slot_count,
        next_token: Token = 0,
        /// Start each search after the last acquired slot so a serial producer
        /// still rotates IOSurfaces and forces Core Animation to recomposite.
        next_slot: usize = 0,
        defunct: bool = false,

        /// Acquire one exact free slot. A null timeout waits indefinitely.
        pub fn acquire(
            self: *Self,
            timeout_ns: ?u64,
        ) error{ Defunct, Timeout }!Lease {
            try self.waitAvailable(timeout_ns);
            errdefer self.available.post(self.io);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

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
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

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

            self.mutex.lockUncancelable(self.io);
            const slot = self.findLocked(token) orelse {
                self.mutex.unlock(self.io);
                return false;
            };
            switch (slot.state) {
                .gpu => {
                    if (host_acquired) {
                        self.mutex.unlock(self.io);
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
                    self.mutex.unlock(self.io);
                    return false;
                },
            }
            self.mutex.unlock(self.io);

            if (post) self.available.post(self.io);
            return true;
        }

        /// Release a frame acquired by an external presentation callback.
        /// Duplicate, stale, unknown, and not-yet-presented tokens return false.
        pub fn releaseHost(self: *Self, token: Token) bool {
            var post = false;

            self.mutex.lockUncancelable(self.io);
            const slot = self.findLocked(token) orelse {
                self.mutex.unlock(self.io);
                return false;
            };
            switch (slot.state) {
                .presenting => {
                    if (slot.release_pending) {
                        self.mutex.unlock(self.io);
                        return false;
                    }
                    slot.release_pending = true;
                },
                .host => {
                    slot.* = .{};
                    post = true;
                },
                else => {
                    self.mutex.unlock(self.io);
                    return false;
                },
            }
            self.mutex.unlock(self.io);

            if (post) self.available.post(self.io);
            return true;
        }

        /// Prevent new acquisitions. Existing GPU and host owners may still
        /// finish so teardown can safely wait for their exact slots.
        pub fn beginDeinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.defunct = true;
        }

        /// Consume one free slot for teardown and return its exact index.
        pub fn takeForDeinit(
            self: *Self,
            timeout_ns: ?u64,
        ) error{Timeout}!std.math.IntFittingRange(0, slot_count - 1) {
            try self.waitAvailable(timeout_ns);

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state != .free) continue;
                slot.state = .deinit;
                return @intCast(index);
            }

            // Every permit corresponds to exactly one `.free` slot.
            unreachable;
        }

        fn waitAvailable(self: *Self, timeout_ns: ?u64) error{Timeout}!void {
            const timeout = timeout_ns orelse {
                self.available.waitUncancelable(self.io);
                return;
            };
            const deadline = std.Io.Timestamp.now(self.io, .awake).addDuration(
                .fromNanoseconds(@intCast(timeout)),
            );

            while (!self.tryWaitAvailable()) {
                if (std.Io.Timestamp.now(self.io, .awake).toNanoseconds() >=
                    deadline.toNanoseconds()) return error.Timeout;
                std.Io.sleep(
                    self.io,
                    .fromMilliseconds(1),
                    .awake,
                ) catch return error.Timeout;
            }
        }

        fn tryWaitAvailable(self: *Self) bool {
            self.available.mutex.lockUncancelable(self.io);
            defer self.available.mutex.unlock(self.io);

            if (self.available.permits == 0) return false;
            self.available.permits -= 1;
            if (self.available.permits > 0) {
                self.available.cond.signal(self.io);
            }
            return true;
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
    var pool: LeasePool = .{ .io = std.testing.io };

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

test "frame lease pool rotates slots for serial frames" {
    const LeasePool = Pool(3);
    var pool: LeasePool = .{ .io = std.testing.io };

    var slots: [4]LeasePool.Lease = undefined;
    for (&slots) |*lease| {
        lease.* = try pool.acquire(null);
        try std.testing.expect(pool.finish(lease.token, false));
    }

    try std.testing.expectEqual(@as(usize, 0), slots[0].slot);
    try std.testing.expectEqual(@as(usize, 1), slots[1].slot);
    try std.testing.expectEqual(@as(usize, 2), slots[2].slot);
    try std.testing.expectEqual(@as(usize, 0), slots[3].slot);
}

test "frame lease pool accepts release racing the presentation callback" {
    const LeasePool = Pool(1);
    var pool: LeasePool = .{ .io = std.testing.io };

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
    var pool: LeasePool = .{ .io = std.testing.io };
    const lease = try pool.acquire(null);

    try std.testing.expect(!pool.releaseHost(lease.token));
    try std.testing.expect(!pool.releaseHost(0));
    try std.testing.expect(!pool.releaseHost(999));
    try std.testing.expect(pool.finish(lease.token, false));
}

test "frame lease pool teardown consumes exact slots" {
    const LeasePool = Pool(2);
    var pool: LeasePool = .{ .io = std.testing.io };

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
