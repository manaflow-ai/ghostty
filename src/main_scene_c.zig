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
    var result: std.Io.VTable = undefined;
    const threaded = std.Io.Threaded.global_single_threaded.io().vtable;
    const failing = std.Io.failing.vtable;
    for (std.meta.fields(std.Io.VTable)) |field| {
        const process_owning = std.mem.eql(u8, field.name, "processReplace") or
            std.mem.eql(u8, field.name, "processReplacePath") or
            std.mem.eql(u8, field.name, "processSpawn") or
            std.mem.eql(u8, field.name, "processSpawnPath") or
            std.mem.eql(u8, field.name, "childWait") or
            std.mem.eql(u8, field.name, "childKill");
        @field(result, field.name) = if (process_owning)
            @field(failing.*, field.name)
        else
            @field(threaded.*, field.name);
    }
    break :vtable result;
};

fn sceneIo() std.Io {
    return .{
        .userdata = std.Io.Threaded.global_single_threaded,
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
