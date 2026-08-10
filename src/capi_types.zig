//! Value types shared by Ghostty's independent C ABI roots.

const std = @import("std");

/// C-compatible owned byte string returned by the full embedding API.
pub const String = extern struct {
    ptr: ?[*]const u8,
    len: usize,
    sentinel: bool,

    pub const empty: String = .{
        .ptr = null,
        .len = 0,
        .sentinel = false,
    };

    pub fn fromSlice(slice: anytype) String {
        return .{
            .ptr = slice.ptr,
            .len = slice.len,
            .sentinel = sentinel: {
                const info = @typeInfo(@TypeOf(slice));
                switch (info) {
                    .pointer => |pointer| {
                        if (pointer.size != .slice)
                            @compileError("only slices supported");
                        if (pointer.child != u8)
                            @compileError("only u8 slices supported");
                        const value = pointer.sentinel();
                        if (value) |byte| if (byte != 0)
                            @compileError("only 0 is supported for sentinels");
                        break :sentinel value != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }

    pub fn deinit(self: *const String, alloc: std.mem.Allocator) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            alloc.free(ptr[0..self.len :0]);
        } else {
            alloc.free(ptr[0..self.len]);
        }
    }
};
