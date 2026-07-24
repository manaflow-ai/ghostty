const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

/// A ref-counted gate between backend completion handlers and renderer-owned
/// state. The renderer owns one reference. Every armed asynchronous completion
/// owns another, so a permanently stalled command can outlive renderer teardown
/// without retaining or dereferencing the renderer itself.
pub fn Lifetime(comptime Context: type) type {
    return struct {
        const Self = @This();

        alloc: Allocator,
        refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
        mutex: std.Thread.Mutex = .{},
        context: ?*Context = null,
        invalidated: bool = false,

        pub const Live = struct {
            owner: *Self,
            context: *Context,

            pub fn deinit(self: *Live) void {
                self.owner.mutex.unlock();
            }
        };

        pub fn create(alloc: Allocator) Allocator.Error!*Self {
            const self = try alloc.create(Self);
            self.* = .{ .alloc = alloc };
            return self;
        }

        /// Bind only after the containing renderer reaches its stable address.
        pub fn bind(self: *Self, context: *Context) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            assert(!self.invalidated);
            assert(self.context == null or self.context == context);
            self.context = context;
        }

        /// Returns a live context while keeping teardown excluded. Callers must
        /// hold the returned lease across every renderer/target dereference.
        pub fn acquire(self: *Self) ?Live {
            self.mutex.lock();
            if (self.invalidated or self.context == null) {
                self.mutex.unlock();
                return null;
            }

            return .{
                .owner = self,
                .context = self.context.?,
            };
        }

        /// Prevent new completion work and wait for any active lease to leave.
        pub fn invalidate(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.invalidated = true;
            self.context = null;
        }

        pub fn retain(self: *Self) void {
            const previous = self.refs.fetchAdd(1, .seq_cst);
            assert(previous > 0);
        }

        pub fn release(self: *Self) void {
            const previous = self.refs.fetchSub(1, .seq_cst);
            assert(previous > 0);
            if (previous == 1) {
                const alloc = self.alloc;
                alloc.destroy(self);
            }
        }
    };
}

/// Owns one completion lifetime per swap-chain generation. Rotation must
/// allocate a distinct lifetime because old copied blocks retain the previous
/// pointer and may execute after a replacement swap chain becomes live.
pub fn Generation(comptime Context: type) type {
    return struct {
        const Self = @This();
        const ContextLifetime = Lifetime(Context);

        alloc: Allocator,
        current: ?*ContextLifetime,

        pub fn init(alloc: Allocator) Allocator.Error!Self {
            return .{
                .alloc = alloc,
                .current = try ContextLifetime.create(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            self.finish();
        }

        pub fn lifetime(self: *const Self) *ContextLifetime {
            return self.current orelse unreachable;
        }

        pub fn bind(self: *Self, context: *Context) void {
            self.lifetime().bind(context);
        }

        /// Invalidate and drop the generation owner's reference. Copied
        /// completion blocks keep the old allocation alive until they run.
        pub fn finish(self: *Self) void {
            const current = self.current orelse return;
            current.invalidate();
            self.current = null;
            current.release();
        }

        pub fn restart(
            self: *Self,
            context: *Context,
        ) Allocator.Error!void {
            assert(self.current == null);
            const current = try ContextLifetime.create(self.alloc);
            current.bind(context);
            self.current = current;
        }
    };
}
