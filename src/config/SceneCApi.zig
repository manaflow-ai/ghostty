//! Minimal configuration C ABI for the standalone semantic-scene renderer.
//!
//! This intentionally excludes file discovery, CLI loading, editing, key
//! lookup, serialization, and every embedded application or surface API.

const std = @import("std");
const state = &@import("../scene_runtime.zig").state;
const Config = @import("Config.zig");

const log = std.log.scoped(.scene_config_c_api);

pub const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

/// Create a config initialized with Ghostty's renderer defaults.
pub export fn ghostty_config_new() ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating scene renderer config err={}", .{err});
        return null;
    };
    result.* = Config.default(state.alloc) catch |err| {
        log.err("error creating scene renderer config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };
    return result;
}

/// Destroy a scene renderer config.
pub export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |value| {
        value.deinit();
        state.alloc.destroy(value);
    }
}

/// Load a daemon-resolved config snapshot from memory.
pub export fn ghostty_config_load_string(
    self: *Config,
    contents: [*]const u8,
    contents_len: usize,
    path: [*:0]const u8,
) void {
    const contents_slice = contents[0..contents_len];
    const path_slice = std.mem.span(path);
    self.loadString(state.alloc, contents_slice, path_slice) catch |err| {
        log.err(
            "error loading scene renderer config path={s} err={}",
            .{ path_slice, err },
        );
    };
}

/// Finalize derived renderer values after loading the snapshot.
pub export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing scene renderer config err={}", .{err});
    };
}

/// Return the number of config diagnostics.
pub export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

/// Return one config diagnostic, or an empty diagnostic for an invalid index.
pub export fn ghostty_config_get_diagnostic(
    self: *Config,
    idx: u32,
) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}
