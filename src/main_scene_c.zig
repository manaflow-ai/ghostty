//! Scene-only C entrypoint for cmux renderer worker processes.
//!
//! The export root deliberately omits the embedded apprt, app, surface,
//! terminal parser, termio, PTY, benchmark, process-census, and CLI APIs.

const std = @import("std");
const builtin = @import("builtin");
const state = &@import("scene_runtime.zig").state;
const glslang = @import("glslang");
const oni = @import("oniguruma");
const internal_os = @import("os/main.zig");

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },
};

var initialized = false;

const scene_io_vtable: std.Io.VTable = vtable: {
    var result = std.Io.Threaded.global_single_threaded.io().vtable.*;
    result.processReplace = std.Io.failingProcessReplace;
    result.processReplacePath = std.Io.failingProcessReplacePath;
    result.processSpawn = std.Io.failingProcessSpawn;
    result.processSpawnPath = std.Io.failingProcessSpawnPath;
    result.childWait = std.Io.unreachableChildWait;
    result.childKill = std.Io.unreachableChildKill;
    break :vtable result;
};

fn sceneIo() std.Io {
    const threaded = std.Io.Threaded.global_single_threaded.io();
    return .{
        .userdata = threaded.userdata,
        .vtable = &scene_io_vtable,
    };
}

comptime {
    _ = @import("config/SceneCApi.zig");
    _ = @import("renderer/scene/CApi.zig");
}

/// Initialize only the process-global facilities required for scene rendering.
pub export fn ghostty_scene_init(argc: usize, argv: [*][*:0]u8) c_int {
    if (initialized) return 0;
    _ = argc;
    _ = argv;

    // Scene rendering needs one process allocator and a safe empty resources
    // directory for config finalization.
    state.* = .{
        .alloc = std.heap.c_allocator,
        .io = sceneIo(),
        .resources_dir = .{},
    };

    internal_os.ensureLocale() catch |err| {
        std.log.err("failed to initialize scene renderer locale err={}", .{err});
        return 1;
    };
    glslang.init() catch |err| {
        std.log.err("failed to initialize scene renderer shaders err={}", .{err});
        return 1;
    };
    oni.init(&.{oni.Encoding.utf8}) catch |err| {
        std.log.err("failed to initialize scene renderer regex engine err={}", .{err});
        return 1;
    };

    initialized = true;
    return 0;
}

test {
    _ = @import("config/SceneCApi.zig");
    _ = @import("renderer/scene/CApi.zig");
}
