const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const global = @import("../global.zig");

pub const ResourcesDir = struct {
    /// Avoid accessing these directly, use the app() and host() methods instead.
    app_path: ?[]const u8 = null,
    host_path: ?[]const u8 = null,

    /// Free resources held. Requires the same allocator as when resourcesDir()
    /// is called.
    pub fn deinit(self: *ResourcesDir, alloc: Allocator) void {
        if (self.app_path) |p| alloc.free(p);
        if (self.host_path) |p| alloc.free(p);
    }

    /// Get the directory to the bundled resources directory accessible
    /// by the application.
    pub fn app(self: *const ResourcesDir) ?[]const u8 {
        return self.app_path;
    }

    /// Get the directory to the bundled resources directory accessible
    /// by the host environment (i.e. for sandboxed applications). The
    /// returned directory might not be accessible from the application
    /// itself.
    ///
    /// In non-sandboxed environment, this should be the same as app().
    pub fn host(self: *const ResourcesDir) ?[]const u8 {
        return self.host_path orelse self.app_path;
    }
};

/// Gets the directory to the bundled resources directory, if it
/// exists (not all platforms or packages have it). The output is
/// owned by the caller.
///
/// This is highly Ghostty-specific and can likely be generalized at
/// some point but we can cross that bridge if we ever need to.
pub fn resourcesDir(alloc: Allocator) !ResourcesDir {
    const probe_dso_before_env = selfSharedObjectProbeBeforeEnv();

    // Embedded Linux shared-library builds should resolve resources relative to
    // the loaded DSO before consulting the host process environment. The host
    // executable may be unrelated to Ghostty and may inherit stale/global
    // GHOSTTY_RESOURCES_DIR values.
    if (probe_dso_before_env) {
        if (try resourcesDirFromSelfSharedObject(alloc)) |result| return result;
    }

    // Use the GHOSTTY_RESOURCES_DIR environment variable in release builds.
    //
    // In debug builds we try using terminfo detection first instead, since
    // if debug Ghostty is launched by an older version of Ghostty, it
    // would inherit the old, stale resources of older Ghostty instead of the
    // freshly built ones under zig-out/share/ghostty.
    //
    // Note: we ALWAYS want to allocate here because the result is always
    // freed, do not try to use internal_os.getenv or posix getenv.
    if (comptime builtin.mode != .Debug) env: {
        const dir = global.environ().getAlloc(alloc, "GHOSTTY_RESOURCES_DIR") catch |err| switch (err) {
            error.EnvironmentVariableMissing => break :env,
            else => return err,
        };

        if (dir.len > 0) return .{ .app_path = dir };
    }

    // In embedded Linux shared-library builds, the host executable may live
    // outside Ghostty's install prefix. Prefer the shared object's own path
    // when available, then fall back to the executable path.
    if (!probe_dso_before_env) {
        if (try resourcesDirFromSelfSharedObject(alloc)) |result| return result;
    }

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(global.io(), &exe_buf) catch
        return .{};
    if (try resourcesDirFromPath(alloc, exe_buf[0..exe_len])) |result|
        return result;

    // If terminfo detection failed in debug builds (somehow),
    // fallback and use the provided resources dir.
    if (comptime builtin.mode == .Debug) {
        if (global.environ().getAlloc(alloc, "GHOSTTY_RESOURCES_DIR")) |dir| {
            if (dir.len > 0) return .{ .app_path = dir };
        } else |err| switch (err) {
            error.InvalidWtf8, error.EnvironmentVariableMissing => {},
            else => return err,
        }
    }

    return .{};
}

fn resourcesDirFromSelfSharedObject(alloc: Allocator) !?ResourcesDir {
    var dso_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = selfSharedObjectPath(&dso_buf) orelse return null;
    return try resourcesDirFromPath(alloc, path);
}

fn selfSharedObjectProbeBeforeEnv() bool {
    return selfSharedObjectProbeBeforeEnvFor(
        builtin.target.os.tag,
        builtin.output_mode,
        builtin.link_mode,
    );
}

fn selfSharedObjectProbeBeforeEnvFor(
    comptime os_tag: std.Target.Os.Tag,
    comptime output_mode: std.builtin.OutputMode,
    comptime link_mode: std.builtin.LinkMode,
) bool {
    return os_tag == .linux and
        output_mode == .Lib and
        link_mode == .dynamic;
}

test "Linux shared libraries probe DSO resources before release env" {
    try std.testing.expect(selfSharedObjectProbeBeforeEnvFor(
        .linux,
        .Lib,
        .dynamic,
    ));
    try std.testing.expect(!selfSharedObjectProbeBeforeEnvFor(
        .linux,
        .Exe,
        .dynamic,
    ));
    try std.testing.expect(!selfSharedObjectProbeBeforeEnvFor(
        .linux,
        .Lib,
        .static,
    ));
    try std.testing.expect(!selfSharedObjectProbeBeforeEnvFor(
        .macos,
        .Lib,
        .dynamic,
    ));
}

fn resourcesDirFromPath(alloc: Allocator, start_path: []const u8) !?ResourcesDir {
    // This is the sentinel value we look for in the path to know
    // we've found the resources directory.
    const sentinels = switch (comptime builtin.target.os.tag) {
        .windows => .{"terminfo/ghostty.terminfo"},
        .macos => .{"terminfo/78/xterm-ghostty"},
        .freebsd => .{ "site-terminfo/g/ghostty", "site-terminfo/x/xterm-ghostty" },
        else => .{ "terminfo/g/ghostty", "terminfo/x/xterm-ghostty" },
    };

    var path = start_path;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (std.fs.path.dirname(path)) |dir| {
        path = dir;

        // On MacOS, we look for the app bundle path.
        if (comptime builtin.target.os.tag.isDarwin()) {
            inline for (sentinels) |sentinel| {
                if (try maybeDir(&dir_buf, dir, "Contents/Resources", sentinel)) |v| {
                    if (try ghosttyAppResourcesDir(alloc, v)) |app_path| {
                        return .{ .app_path = app_path };
                    }
                }
            }
        }

        // On all platforms (except BSD), we look for a /usr/share style path. This
        // is valid even on Mac since there is nothing that requires
        // Ghostty to be in an app bundle.
        inline for (sentinels) |sentinel| {
            if (try maybeDir(
                &dir_buf,
                dir,
                if (builtin.target.os.tag == .freebsd) "local/share" else "share",
                sentinel,
            )) |v| {
                if (try ghosttyAppResourcesDir(alloc, v)) |app_path| {
                    return .{ .app_path = app_path };
                }
            }
        }
    }

    return null;
}

fn ghosttyAppResourcesDir(alloc: Allocator, share_dir: []const u8) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/ghostty", .{share_dir});

    if (comptime builtin.target.os.tag == .linux) {
        std.Io.Dir.accessAbsolute(global.io(), path, .{}) catch return null;
    }

    return try std.fs.path.join(alloc, &.{ share_dir, "ghostty" });
}

fn selfSharedObjectPath(buf: []u8) ?[]const u8 {
    if (comptime builtin.target.os.tag != .linux or !builtin.link_libc) return null;

    var info: DlInfo = undefined;
    if (dladdr(resourcesDir, &info) == 0) return null;
    const raw = info.dli_fname orelse return null;
    const path = std.mem.span(raw);
    if (path.len == 0) return null;

    if (std.fs.path.isAbsolute(path)) {
        return std.fmt.bufPrint(buf, "{s}", .{path}) catch null;
    }

    const len = std.Io.Dir.cwd().realPathFile(global.io(), path, buf) catch
        return null;
    return buf[0..len];
}

const DlInfo = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};

extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;

/// Little helper to check if the "base/sub/suffix" directory exists and
/// if so return true. The "suffix" is just used as a way to verify a directory
/// seems roughly right.
///
/// "buf" must be large enough to fit base + sub + suffix. This is generally
/// max_path_bytes so its not a big deal.
pub fn maybeDir(
    buf: []u8,
    base: []const u8,
    sub: []const u8,
    suffix: []const u8,
) !?[]const u8 {
    const path = try std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{ base, sub, suffix });

    if (std.Io.Dir.accessAbsolute(global.io(), path, .{})) {
        const len = path.len - suffix.len - 1;
        return buf[0..len];
    } else |_| {
        // Folder doesn't exist. If a different error happens its okay
        // we just ignore it and move on.
    }

    return null;
}

test "resources dir can be resolved from zig-out library path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "zig-out/lib");
    try tmp.dir.createDirPath(std.testing.io, "zig-out/share/terminfo/g");
    try tmp.dir.createDirPath(std.testing.io, "zig-out/share/ghostty");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zig-out/share/terminfo/g/ghostty",
        .data = "",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "zig-out/lib/libghostty-internal.so",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const library_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "zig-out/lib/libghostty-internal.so" },
    );
    defer std.testing.allocator.free(library_path);

    var result = (try resourcesDirFromPath(std.testing.allocator, library_path)).?;
    defer result.deinit(std.testing.allocator);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ root, "zig-out/share/ghostty" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.app().?);
    try std.testing.expectEqualStrings(expected, result.host().?);
}

test "resources dir can be resolved from installed library prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.createDirPath(std.testing.io, "share/terminfo/g");
    try tmp.dir.createDirPath(std.testing.io, "share/ghostty");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "share/terminfo/g/ghostty",
        .data = "",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/libghostty-internal.so",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const library_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "lib/libghostty-internal.so" },
    );
    defer std.testing.allocator.free(library_path);

    var result = (try resourcesDirFromPath(std.testing.allocator, library_path)).?;
    defer result.deinit(std.testing.allocator);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ root, "share/ghostty" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result.app().?);
    try std.testing.expectEqualStrings(expected, result.host().?);
}

test "Linux resources dir ignores terminfo-only library prefix" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.createDirPath(std.testing.io, "share/terminfo/g");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "share/terminfo/g/ghostty",
        .data = "",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/libghostty-internal.so",
        .data = "",
    });

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const library_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ root, "lib/libghostty-internal.so" },
    );
    defer std.testing.allocator.free(library_path);

    try std.testing.expect(try resourcesDirFromPath(std.testing.allocator, library_path) == null);
}
