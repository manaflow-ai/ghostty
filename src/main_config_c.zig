//! Standalone config resolution entrypoint for daemon processes.

const std = @import("std");
const builtin = @import("builtin");
const state = &@import("config_runtime.zig").state;
const internal_os = @import("os/main.zig");

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

var initialized = false;

comptime {
    _ = @import("config/StandaloneCApi.zig");
}

/// Initialize only allocator, argv, and resource discovery required by config.
pub export fn ghostty_config_init(argc: usize, argv: [*][*:0]u8) c_int {
    if (initialized) return 0;
    std.os.argv = argv[0..argc];
    state.* = .{
        .alloc = std.heap.c_allocator,
        .resources_dir = internal_os.resourcesDir(std.heap.c_allocator) catch |err| {
            std.log.err("failed to locate config resources err={}", .{err});
            return 1;
        },
    };
    initialized = true;
    return 0;
}
