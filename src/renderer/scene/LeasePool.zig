//! Exact, out-of-order-safe ownership state for exported render targets.

const std = @import("std");
const Export = @import("Export.zig");

pub fn LeasePool(comptime slot_count: usize) type {
    if (slot_count < 3) @compileError("scene export requires at least three slots");

    return struct {
        const Self = @This();

        pub const Error = error{
            NoAvailableSlot,
            InvalidSlot,
            InvalidTransition,
            LeaseMismatch,
        };

        const Rendering = struct {
            metadata: ?Export.FrameMetadata,
        };

        const State = union(enum) {
            available,
            rendering: Rendering,
            leased: Export.FrameLease,
        };

        states: [slot_count]State = @splat(.available),
        mutex: std.Thread.Mutex = .{},

        /// Select any available slot. This deliberately does not use a cyclic
        /// index because host releases may arrive out of order.
        pub fn acquire(
            self: *Self,
            metadata: ?Export.FrameMetadata,
        ) Error!usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.states, 0..) |*state, index| switch (state.*) {
                .available => {
                    state.* = .{ .rendering = .{ .metadata = metadata } };
                    return index;
                },
                .rendering, .leased => {},
            };
            return error.NoAvailableSlot;
        }

        /// Complete GPU ownership. Ordinary in-process frames become
        /// available immediately. Export frames become immutable leases.
        pub fn gpuComplete(
            self: *Self,
            index: usize,
            healthy: bool,
            iosurface_id: u32,
            width: u32,
            height: u32,
        ) Error!?Export.FrameLease {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (index >= slot_count) return error.InvalidSlot;
            const rendering = switch (self.states[index]) {
                .rendering => |value| value,
                else => return error.InvalidTransition,
            };
            if (!healthy or rendering.metadata == null) {
                self.states[index] = .available;
                return null;
            }
            if (iosurface_id == 0 or width == 0 or height == 0)
                return error.InvalidTransition;
            const lease: Export.FrameLease = .{
                .metadata = rendering.metadata.?,
                .iosurface_id = iosurface_id,
                .width = width,
                .height = height,
            };
            self.states[index] = .{ .leased = lease };
            return lease;
        }

        pub fn cancel(self: *Self, index: usize) Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (index >= slot_count) return error.InvalidSlot;
            switch (self.states[index]) {
                .rendering => self.states[index] = .available,
                else => return error.InvalidTransition,
            }
        }

        pub fn release(
            self: *Self,
            lease: Export.FrameLease,
        ) Error!usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (&self.states, 0..) |*state, index| switch (state.*) {
                .leased => |current| {
                    if (std.meta.eql(current, lease)) {
                        state.* = .available;
                        return index;
                    }
                },
                .available, .rendering => {},
            };
            return error.LeaseMismatch;
        }

        pub fn slotForLease(
            self: *Self,
            lease: Export.FrameLease,
        ) Error!usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.states, 0..) |state, index| switch (state) {
                .leased => |current| if (std.meta.eql(current, lease))
                    return index,
                .available, .rendering => {},
            };
            return error.LeaseMismatch;
        }

        pub fn allAvailable(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.states) |state| switch (state) {
                .available => {},
                .rendering, .leased => return false,
            };
            return true;
        }

        pub fn availableCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            var count: usize = 0;
            for (self.states) |state| {
                if (state == .available) count += 1;
            }
            return count;
        }
    };
}

const test_metadata: Export.FrameMetadata = .{
    .renderer_epoch = 7,
    .terminal_id = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .terminal_epoch = 3,
    .content_sequence = 11,
    .presentation_id = .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .presentation_generation = 5,
    .presentation_sequence = 13,
    .frame_sequence = 17,
};

test "lease pool reuses whichever slot is released out of order" {
    var pool: LeasePool(3) = .{};
    const a = try pool.acquire(test_metadata);
    var b_metadata = test_metadata;
    b_metadata.frame_sequence += 1;
    const b = try pool.acquire(b_metadata);
    var c_metadata = b_metadata;
    c_metadata.frame_sequence += 1;
    const c = try pool.acquire(c_metadata);
    try std.testing.expectError(
        error.NoAvailableSlot,
        pool.acquire(c_metadata),
    );

    const lease_a = (try pool.gpuComplete(a, true, 101, 640, 480)).?;
    const lease_b = (try pool.gpuComplete(b, true, 102, 640, 480)).?;
    const lease_c = (try pool.gpuComplete(c, true, 103, 640, 480)).?;
    try std.testing.expectEqual(@as(usize, 0), pool.availableCount());

    _ = try pool.release(lease_b);
    const reused = try pool.acquire(b_metadata);
    try std.testing.expectEqual(b, reused);
    try std.testing.expectError(error.LeaseMismatch, pool.release(lease_b));
    try pool.cancel(reused);
    _ = try pool.release(lease_c);
    _ = try pool.release(lease_a);
    try std.testing.expect(pool.allAvailable());
}

test "lease pool rejects every inexact release fence" {
    var pool: LeasePool(3) = .{};
    const index = try pool.acquire(test_metadata);
    const lease = (try pool.gpuComplete(index, true, 55, 10, 20)).?;
    inline for (.{
        "renderer_epoch",
        "terminal_epoch",
        "content_sequence",
        "presentation_generation",
        "presentation_sequence",
        "frame_sequence",
    }) |field| {
        var wrong = lease;
        @field(wrong.metadata, field) += 1;
        try std.testing.expectError(error.LeaseMismatch, pool.release(wrong));
    }
    var wrong_surface = lease;
    wrong_surface.iosurface_id += 1;
    try std.testing.expectError(
        error.LeaseMismatch,
        pool.release(wrong_surface),
    );
    _ = try pool.release(lease);
}

test "unhealthy and ordinary frames never become leases" {
    var pool: LeasePool(3) = .{};
    const ordinary = try pool.acquire(null);
    try std.testing.expect((try pool.gpuComplete(
        ordinary,
        true,
        1,
        1,
        1,
    )) == null);
    const failed = try pool.acquire(test_metadata);
    try std.testing.expect((try pool.gpuComplete(
        failed,
        false,
        1,
        1,
        1,
    )) == null);
    try std.testing.expect(pool.allAvailable());
}
