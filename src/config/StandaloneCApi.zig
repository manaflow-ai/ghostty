//! Configuration-only C ABI for daemon processes.
//!
//! This root owns file discovery, recursive config loading, finalization, and
//! canonical serialization. It intentionally exports no CLI, app, surface,
//! PTY, terminal VT parser, process launcher, or rendering API.

const std = @import("std");
const state = &@import("../config_runtime.zig").state;
const String = @import("../capi_types.zig").String;
const Config = @import("Config.zig");
const serialize = @import("serialize.zig");

const log = std.log.scoped(.config_c_api);

pub const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

/// Create a new config initialized with Ghostty's macOS defaults.
pub export fn ghostty_config_new() ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating standalone config err={}", .{err});
        return null;
    };
    result.* = Config.default(state.alloc) catch |err| {
        log.err("error creating standalone config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };
    return result;
}

/// Destroy a standalone config.
pub export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |value| {
        value.deinit();
        state.alloc.destroy(value);
    }
}

/// Load the canonical Ghostty user config locations.
pub export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(state.alloc) catch |err| {
        log.err("error loading default config files err={}", .{err});
    };
}

/// Load one explicit absolute config path.
pub export fn ghostty_config_load_file(
    self: *Config,
    path: [*:0]const u8,
) void {
    const path_slice = std.mem.span(path);
    self.loadFile(state.alloc, path_slice) catch |err| {
        log.err(
            "error loading config file path={s} err={}",
            .{ path_slice, err },
        );
    };
}

/// Load config bytes with a synthetic absolute source path.
pub export fn ghostty_config_load_string(
    self: *Config,
    contents: [*]const u8,
    contents_len: usize,
    path: [*:0]const u8,
) void {
    const path_slice = std.mem.span(path);
    self.loadString(
        state.alloc,
        contents[0..contents_len],
        path_slice,
    ) catch |err| {
        log.err(
            "error loading config string path={s} err={}",
            .{ path_slice, err },
        );
    };
}

/// Recursively load every config-file directive collected so far.
pub export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(state.alloc) catch |err| {
        log.err("error loading recursive config files err={}", .{err});
    };
}

/// Resolve themes and all derived/default config values.
pub export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing standalone config err={}", .{err});
    };
}

/// Return the number of accumulated diagnostics.
pub export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

/// Return one accumulated diagnostic, or an empty value for an invalid index.
pub export fn ghostty_config_get_diagnostic(
    self: *Config,
    idx: u32,
) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

/// Return an independently owned, canonical config snapshot.
pub export fn ghostty_config_serialize(self: ?*const Config) String {
    const config = self orelse return .empty;
    const bytes = serialize.canonical(state.alloc, config) catch |err| {
        log.err("error serializing standalone config err={}", .{err});
        return .empty;
    };
    return .fromSlice(bytes);
}

/// Free an owned string returned by this ConfigKit instance.
pub export fn ghostty_string_free(value: String) void {
    value.deinit(state.alloc);
}
