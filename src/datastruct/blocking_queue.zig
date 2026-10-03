//! Blocking queue implementation aimed primarily for message passing
//! between threads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compat_thread = @import("../lib/compat/thread.zig");

/// Returns a blocking queue implementation for type T.
///
/// This is tailor made for ghostty usage so it isn't meant to be maximally
/// generic, but I'm happy to make it more generic over time. Traits of this
/// queue that are specific to our usage:
///
///   - Fixed size. We expect our queue to quickly drain and also not be
///     too large so we prefer a fixed size queue for now.
///   - No blocking pop. We use an external event loop mechanism such as
///     eventfd to notify our waiter that there is no data available so
///     we don't need to implement a blocking pop.
///   - Drain function. Most queues usually pop one at a time. We have
///     a mechanism for draining since on every IO loop our TTY drains
///     the full queue so we can get rid of the overhead of a ton of
///     locks and bounds checking and do a one-time drain.
///
/// Queues may have multiple producers and a single consumer. At the time of
/// writing this, the blocking queue implementation
/// is purposely naive to build something quickly, but we should benchmark
/// and make this more optimized as necessary.
pub fn BlockingQueue(
    comptime T: type,
    comptime capacity: usize,
) type {
    return struct {
        const Self = @This();

        // The type we use for queue size types. We can optimize this
        // in the future to be the correct bit-size for our preallocated
        // size for this queue.
        pub const Size = u32;

        // The bounds of this queue. We recast this to Size so we can do math.
        const bounds: Size = @intCast(capacity);

        /// Specifies the timeout for an operation.
        pub const Timeout = union(enum) {
            /// Fail instantly (non-blocking).
            instant: void,

            /// Wait for capacity or producer cancellation.
            forever: void,

            /// Nanoseconds
            ns: u64,
        };

        /// Our data. The values are undefined until they are written.
        data: [bounds]T = undefined,

        /// The next location to write (next empty loc) and next location
        /// to read (next non-empty loc). The number of written elements.
        write: Size = 0,
        read: Size = 0,
        len: Size = 0,

        /// The big mutex that must be held to read/write.
        mutex: std.Io.Mutex = .init,

        /// A CV for being notified when the queue is no longer full. This is
        /// used for writing. Note we DON'T have a CV for waiting on the
        /// queue not being EMPTY because we use external notifiers for that.
        cond_not_full: std.Io.Condition = .init,
        not_full_waiters: usize = 0,

        /// Allocate the blocking queue on the heap.
        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            errdefer alloc.destroy(ptr);

            ptr.* = .{
                .data = undefined,
                .len = 0,
                .write = 0,
                .read = 0,
                .mutex = .init,
                .cond_not_full = .init,
                .not_full_waiters = 0,
            };

            return ptr;
        }

        /// Free all the resources for this queue. This should only be
        /// called once all producers and consumers have quit.
        pub fn destroy(self: *Self, alloc: Allocator) void {
            self.* = undefined;
            alloc.destroy(self);
        }

        /// Push a value to the queue. This returns the total size of the
        /// queue (unread items) after the push. A return value of zero
        /// means that the push failed.
        pub fn push(self: *Self, io: std.Io, value: T, timeout: Timeout) Size {
            return self.pushCancelable(io, value, timeout, null);
        }

        /// Like push, but rejects writes once this producer is canceled.
        /// The flag must only be changed through cancelPushes on this queue.
        /// Failed pushes leave ownership of the value with the caller.
        pub fn pushCancelable(
            self: *Self,
            io: std.Io,
            value: T,
            timeout: Timeout,
            canceled: ?*const bool,
        ) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // Keep one deadline across wakeups from other producers.
            const deadline: std.Io.Timeout = switch (timeout) {
                .ns => |ns| (std.Io.Timeout{ .duration = .{
                    .raw = .fromNanoseconds(ns),
                    .clock = .awake,
                } }).toDeadline(io),
                else => .none,
            };

            while (true) {
                if (canceled) |flag| if (flag.*) return 0;
                if (!self.full()) break;

                switch (timeout) {
                    // If we're not waiting, then we failed to write.
                    .instant => return 0,

                    .forever => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        self.cond_not_full.waitUncancelable(io, &self.mutex);
                    },

                    .ns => {
                        self.not_full_waiters += 1;
                        defer self.not_full_waiters -= 1;
                        compat_thread.waitTimeout(
                            &self.cond_not_full,
                            io,
                            &self.mutex,
                            deadline,
                        ) catch return 0;
                    },
                }
            }

            // Add our data and update our accounting
            self.data[self.write] = value;
            self.write += 1;
            if (self.write >= bounds) self.write -= bounds;
            self.len += 1;

            return self.len;
        }

        /// Cancel one producer without closing the shared queue. Holding the
        /// queue mutex makes setting the flag and waking blocked pushes atomic
        /// with respect to checking the flag and entering the condition wait.
        pub fn cancelPushes(self: *Self, io: std.Io, canceled: *bool) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            canceled.* = true;
            self.cond_not_full.broadcast(io);
        }

        /// Pop a value from the queue without blocking.
        pub fn pop(self: *Self, io: std.Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            // If we're empty we have nothing
            if (self.len == 0) return null;

            // Get the index we're going to read data from and do some
            // accounting. We don't copy the value here to avoid copying twice.
            const n = self.read;
            self.read += 1;
            if (self.read >= bounds) self.read -= bounds;
            self.len -= 1;

            // If we have consumers waiting on a full queue, notify.
            if (self.not_full_waiters > 0) self.cond_not_full.signal(io);

            return self.data[n];
        }

        /// Return the number of values currently queued.
        ///
        /// Consumers can use this to bound one processing turn to a snapshot
        /// of the queue. Producers may add more values after this returns, but
        /// a single-consumer queue retains at least this many values until that
        /// consumer pops them.
        pub fn count(self: *Self, io: std.Io) Size {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            return self.len;
        }

        /// Pop all values from the queue. This will hold the big mutex
        /// until `deinit` is called on the return value. This is used if
        /// you know you're going to "pop" and utilize all the values
        /// quickly to avoid many locks, bounds checks, and cv signals.
        pub fn drain(self: *Self, io: std.Io) DrainIterator {
            self.mutex.lockUncancelable(io);
            return .{ .queue = self };
        }

        pub const DrainIterator = struct {
            queue: *Self,

            pub fn next(self: *DrainIterator) ?T {
                if (self.queue.len == 0) return null;

                // Read and account
                const n = self.queue.read;
                self.queue.read += 1;
                if (self.queue.read >= bounds) self.queue.read -= bounds;
                self.queue.len -= 1;

                return self.queue.data[n];
            }

            pub fn deinit(self: *DrainIterator, io: std.Io) void {
                // If we have consumers waiting on a full queue, notify.
                if (self.queue.not_full_waiters > 0) self.queue.cond_not_full.broadcast(io);

                // Unlock
                self.queue.mutex.unlock(io);
            }
        };

        /// Returns true if the queue is full. This is not public because
        /// it requires the lock to be held.
        inline fn full(self: *Self) bool {
            return self.len == bounds;
        }
    };
}

test "basic push and pop" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Should have no values
    try testing.expect(q.pop(io) == null);

    // Push until we're full
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(io, 2, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 3), q.push(io, 3, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 4), q.push(io, 4, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 5, .{ .instant = {} }));

    // Pop!
    try testing.expect(q.pop(io).? == 1);
    try testing.expect(q.pop(io).? == 2);
    try testing.expect(q.pop(io).? == 3);
    try testing.expect(q.pop(io).? == 4);
    try testing.expect(q.pop(io) == null);

    // Drain does nothing
    var it = q.drain(io);
    try testing.expect(it.next() == null);
    it.deinit(io);

    // Verify we can still push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
}

test "count snapshots one bounded consumer turn" {
    const testing = std.testing;
    const Q = BlockingQueue(u64, 4);
    const q = try Q.create(testing.allocator);
    defer q.destroy(testing.allocator);

    try testing.expectEqual(@as(Q.Size, 1), q.push(testing.io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 2), q.push(testing.io, 2, .{ .instant = {} }));

    var remaining = q.count(testing.io);
    try testing.expectEqual(@as(Q.Size, 3), q.push(testing.io, 3, .{ .instant = {} }));
    while (remaining > 0) : (remaining -= 1) {
        _ = q.pop(testing.io).?;
    }

    try testing.expectEqual(@as(u64, 3), q.pop(testing.io).?);
    try testing.expectEqual(@as(Q.Size, 0), q.count(testing.io));
}

test "timed push" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    const Q = BlockingQueue(u64, 1);
    const q = try Q.create(alloc);
    defer q.destroy(alloc);

    // Push
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .{ .instant = {} }));
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .instant = {} }));

    // Timed push should fail
    try testing.expectEqual(@as(Q.Size, 0), q.push(io, 2, .{ .ns = 1000 }));
}

test "cancel blocked producer without dropping another producer's message" {
    const testing = std.testing;
    const io = testing.io;
    const Q = BlockingQueue(u64, 1);
    const Producer = struct {
        queue: *Q,
        value: u64,
        canceled: bool = false,
        result: Q.Size = undefined,
        done: std.Io.Event = .unset,

        fn run(self: *@This()) void {
            self.result = self.queue.pushCancelable(testing.io, self.value, .forever, &self.canceled);
            self.done.set(testing.io);
        }

        fn cleanup(self: *@This()) void {
            // Keep a broken cancelPushes implementation from hanging the test
            // runner while joining a producer after an assertion fails.
            self.queue.mutex.lockUncancelable(testing.io);
            defer self.queue.mutex.unlock(testing.io);
            self.canceled = true;
            self.queue.cond_not_full.broadcast(testing.io);
        }
    };

    var q: Q = .{};
    try testing.expectEqual(@as(Q.Size, 1), q.push(io, 1, .instant));
    var closing: Producer = .{ .queue = &q, .value = 2 };
    var surviving: Producer = .{ .queue = &q, .value = 3 };
    const closing_thread = try std.Thread.spawn(.{}, Producer.run, .{&closing});
    defer closing_thread.join();
    defer closing.cleanup();
    const surviving_thread = try std.Thread.spawn(.{}, Producer.run, .{&surviving});
    defer surviving_thread.join();
    defer surviving.cleanup();

    // Observe both threads inside the queue wait, rather than relying on a
    // sleep to guess whether shutdown raced ahead of either producer.
    const start: std.Io.Timestamp = .now(io, .awake);
    while (true) {
        q.mutex.lockUncancelable(io);
        const waiters = q.not_full_waiters;
        q.mutex.unlock(io);
        if (waiters == 2) break;
        if (start.untilNow(io, .awake).toMilliseconds() > 2000)
            return error.ProducersDidNotBlock;
        try std.Thread.yield();
    }

    q.cancelPushes(io, &closing.canceled);
    try closing.done.waitTimeout(io, .{ .duration = .{
        .raw = .fromSeconds(2),
        .clock = .awake,
    } });
    try testing.expectEqual(@as(Q.Size, 0), closing.result);
    try testing.expectEqual(@as(u64, 1), q.pop(io).?);

    try surviving.done.waitTimeout(io, .{ .duration = .{
        .raw = .fromSeconds(2),
        .clock = .awake,
    } });
    try testing.expectEqual(@as(Q.Size, 1), surviving.result);
    try testing.expectEqual(@as(u64, 3), q.pop(io).?);

    // A later send from the closed surface must fail even with free capacity.
    try testing.expectEqual(@as(Q.Size, 0), q.pushCancelable(io, 4, .forever, &closing.canceled));
    try testing.expectEqual(@as(Q.Size, 1), q.pushCancelable(io, 5, .forever, &surviving.canceled));
    try testing.expectEqual(@as(u64, 5), q.pop(io).?);
}
