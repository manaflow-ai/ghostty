//! Minimal process state shared by the scene-only C ABI.

const std = @import("std");
const internal_os = @import("os/main.zig");

pub var state: State = undefined;

pub const State = struct {
    alloc: std.mem.Allocator,
    resources_dir: internal_os.ResourcesDir = .{},
};
