// This is the main file for the C API. The C API is used to embed Ghostty
// within other applications. Depending on the build settings some APIs
// may not be available (i.e. embedding into macOS exposes various Metal
// support).
//
// This currently isn't supported as a general purpose embedding API. It is used
// by Ghostty's platform apps and controlled embedders, including the local Linux
// libghostty embedding path where the host owns the window and OpenGL context.

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const posix = std.posix;
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const main = @import("main_ghostty.zig");
const global = @import("global.zig");
const apprt = @import("apprt.zig");
const internal_os = @import("os/main.zig");
const windows = @import("os/windows.zig");

const InitMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *InitMutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *InitMutex) void {
        self.locked.store(false, .release);
    }
};

var init_mutex: InitMutex = .{};
var initialized = false;
var fallback_argv = [_][*:0]u8{@constCast("ghostty")};
var initialized_argv: ?InitArgv = null;

const InitArgv = struct {
    argv: [][*:0]u8,
    owned: bool,

    fn deinit(self: *InitArgv, alloc: std.mem.Allocator) void {
        if (self.owned) {
            for (self.argv) |arg| {
                const len = std.mem.len(arg);
                alloc.free(arg[0..len :0]);
            }
            alloc.free(self.argv);
        }
        self.* = .{ .argv = fallback_argv[0..], .owned = false };
    }
};

// Some comptime assertions that our C API depends on.
comptime {
    // We allow tests to reference this file because we unit test
    // some of the C API. At runtime though we should never get these
    // functions unless we are building libghostty.
    if (!builtin.is_test) {
        assert(apprt.runtime == apprt.embedded);
    }
}

/// Global options so we can log. This is identical to main.
pub const std_options = main.std_options;

comptime {
    // These structs need to be referenced so the `export` functions
    // are truly exported by the C API lib.

    // Our config API
    _ = @import("config.zig").CApi;

    // Any apprt-specific C API, mainly libghostty for apprt.embedded.
    if (@hasDecl(apprt.runtime, "CAPI")) _ = apprt.runtime.CAPI;

    // Our benchmark API. We probably want to gate this on a build
    // config in the future but for now we always just export it.
    _ = @import("benchmark/main.zig").CApi;

    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

/// ghostty_info_s
const Info = extern struct {
    mode: BuildMode,
    version: [*]const u8,
    version_len: usize,

    const BuildMode = enum(c_int) {
        debug,
        release_safe,
        release_fast,
        release_small,
    };
};

/// ghostty_string_s
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
                    .pointer => |p| {
                        if (p.size != .slice) @compileError("only slices supported");
                        if (p.child != u8) @compileError("only u8 slices supported");
                        const sentinel_ = p.sentinel();
                        if (sentinel_) |sentinel| if (sentinel != 0) @compileError("only 0 is supported for sentinels");
                        break :sentinel sentinel_ != null;
                    },
                    else => @compileError("only []const u8 and [:0]const u8"),
                }
            },
        };
    }

    pub fn deinit(self: *const String) void {
        const ptr = self.ptr orelse return;
        if (self.sentinel) {
            global.alloc().free(ptr[0..self.len :0]);
        } else {
            global.alloc().free(ptr[0..self.len]);
        }
    }
};

fn writeInitError(writer: *std.Io.Writer, err: anyerror) std.Io.Writer.Error!void {
    try writer.print("error: failed to initialize ghostty error={}\n", .{err});
}

fn reportInitError(err: anyerror) void {
    var buf: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();

    nosuspend writeInitError(&stderr.file_writer.interface, err) catch return;
    nosuspend stderr.file_writer.interface.flush() catch return;
}

/// Initialize ghostty global state.
pub export fn ghostty_init(argc: usize, argv: [*c]const [*:0]const u8) c_int {
    assert(builtin.link_libc);

    init_mutex.lock();
    defer init_mutex.unlock();

    if (initialized) return 0;

    var normalized_argv = (initArgv(std.heap.c_allocator, argc, argv) catch return 1) orelse
        return 1;

    global.init(.{
        .c = .{
            .argc = normalized_argv.argv.len,
            .argv = @ptrCast(normalized_argv.argv.ptr),
            .environ = if (std.process.Environ.Block == std.process.Environ.PosixBlock)
                // Asserting libc means that we can fast-path all POSIX blocks
                .{ .block = .{ .slice = std.c.environ[0..env_len: {
                    var len: usize = 0;
                    while (std.c.environ[len]) |_| : (len += 1) {}
                    break :env_len len;
                } :null] } }
            else
                // Anything that is not using PosixBlock is a global block for
                // purposes of initialization.
                .{ .block = .{ .use_global = true } },
        },
    }) catch |err| {
        normalized_argv.deinit(std.heap.c_allocator);
        reportInitError(err);
        return 1;
    };

    initialized_argv = normalized_argv;
    initialized = true;
    return 0;
}

fn initArgv(
    alloc: std.mem.Allocator,
    argc: usize,
    argv: [*c]const [*:0]const u8,
) !?InitArgv {
    if (argc == 0) return .{ .argv = fallback_argv[0..], .owned = false };
    if (argv == null) return null;
    for (0..argc) |i| {
        if (@intFromPtr(argv[i]) == 0) return null;
    }

    const result = try alloc.alloc([*:0]u8, argc);
    var copied: usize = 0;
    errdefer {
        for (result[0..copied]) |arg| {
            const len = std.mem.len(arg);
            alloc.free(arg[0..len :0]);
        }
        alloc.free(result);
    }
    for (0..argc) |i| {
        const copy = try alloc.dupeZ(u8, std.mem.span(argv[i]));
        result[i] = copy.ptr;
        copied += 1;
    }
    return .{ .argv = result, .owned = true };
}

/// Runs an action if it is specified. If there is no action this returns
/// false. If there is an action then this doesn't return.
pub export fn ghostty_cli_try_action() void {
    const action = global.action() orelse return;
    std.log.info("executing CLI action={}", .{action});
    posix.system.exit(action.run(global.alloc()) catch |err| {
        std.log.err("CLI action failed error={}", .{err});
        posix.system.exit(1);
    });

    posix.system.exit(0);
}

/// Return metadata about Ghostty, such as version, build mode, etc.
pub export fn ghostty_info() Info {
    return .{
        .mode = switch (builtin.mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseFast => .release_fast,
            .ReleaseSmall => .release_small,
        },
        .version = build_config.version_string.ptr,
        .version_len = build_config.version_string.len,
    };
}

/// Translate a string maintained by libghostty into the current
/// application language. This will return the same string (same pointer)
/// if no translation is found, so the pointer must be stable through
/// the function call.
///
/// This should only be used for singular strings maintained by Ghostty.
pub export fn ghostty_translate(msgid: [*:0]const u8) [*:0]const u8 {
    return internal_os.i18n._(msgid);
}

/// Free a string allocated by Ghostty.
pub export fn ghostty_string_free(str: String) void {
    str.deinit();
}

/// Return the runtime resources directory resolved by Ghostty.
pub export fn ghostty_resources_dir() String {
    init_mutex.lock();
    defer init_mutex.unlock();

    if (!initialized) return .empty;

    const resources = global.resourcesDir();
    const path = resources.app() orelse return .empty;
    const copy = global.alloc().dupe(u8, path) catch |err| {
        std.log.err("failed to allocate Ghostty resources directory string err={}", .{err});
        return .empty;
    };
    return .fromSlice(copy);
}

// On Windows, Zig's _DllMainCRTStartup does not initialize the MSVC C
// runtime when targeting MSVC ABI. Without initialization, any C library
// function that depends on CRT internal state (setlocale, malloc from C
// dependencies, C++ constructors in glslang) crashes with null pointer
// dereferences. Declaring DllMain causes Zig's start.zig to call it
// during DLL_PROCESS_ATTACH/DETACH, and for MSVC we forward to the CRT
// bootstrap functions from libvcruntime and libucrt (already linked).
// For other ABIs (MinGW) the handler is a no-op since dllcrt2.obj already
// handles CRT init; we still need `DllMain` declared so that Zig's
// start.zig does not fall back to calling a non-function value.
//
// This is a workaround. Zig handles MinGW DLLs correctly (via dllcrt2.obj)
// but not MSVC. No upstream issue tracks this exact gap as of 2026-03-26.
// Closest: Codeberg ziglang/zig #30936 (reimplement crt0 code).
// Remove this DllMain when Zig handles MSVC DLL CRT init natively.
pub const DllMain = if (builtin.os.tag == .windows) struct {
    const BOOL = windows.BOOL;
    const HINSTANCE = windows.HINSTANCE;
    const DWORD = windows.DWORD;
    const LPVOID = windows.LPVOID;
    const TRUE = windows.TRUE;
    const FALSE = windows.FALSE;

    const DLL_PROCESS_ATTACH: DWORD = 1;
    const DLL_PROCESS_DETACH: DWORD = 0;

    const __vcrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__vcrt_initialize" });
    const __vcrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__vcrt_uninitialize" });
    const __acrt_initialize = @extern(*const fn () callconv(.c) c_int, .{ .name = "__acrt_initialize" });
    const __acrt_uninitialize = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "__acrt_uninitialize" });

    pub fn handler(_: HINSTANCE, fdwReason: DWORD, _: LPVOID) callconv(.winapi) BOOL {
        // Only MSVC needs to bootstrap the CRT; MinGW handles it via dllcrt2.obj.
        if (builtin.abi != .msvc) return TRUE;
        switch (fdwReason) {
            DLL_PROCESS_ATTACH => {
                if (__vcrt_initialize() < 0) return FALSE;
                if (__acrt_initialize() < 0) return FALSE;
                return TRUE;
            },
            DLL_PROCESS_DETACH => {
                _ = __acrt_uninitialize(1);
                _ = __vcrt_uninitialize(1);
                return TRUE;
            },
            else => return TRUE,
        }
    }
}.handler else void;

test "ghostty_string_s empty string" {
    const testing = std.testing;
    const empty_string = String.empty;
    defer empty_string.deinit();

    try testing.expect(empty_string.len == 0);
    try testing.expect(empty_string.sentinel == false);
}

test "ghostty_string_s c string" {
    const testing = std.testing;

    const slice: [:0]const u8 = "hello";
    const allocated_slice = try testing.allocator.dupeZ(u8, slice);
    const c_null_string = String.fromSlice(allocated_slice);
    defer c_null_string.deinit();

    try testing.expect(allocated_slice[5] == 0);
    try testing.expect(@TypeOf(slice) == [:0]const u8);
    try testing.expect(@TypeOf(allocated_slice) == [:0]u8);
    try testing.expect(c_null_string.len == 5);
    try testing.expect(c_null_string.sentinel == true);
}

test "ghostty_string_s zig string" {
    const testing = std.testing;

    const slice: []const u8 = "hello";
    const allocated_slice = try testing.allocator.dupe(u8, slice);
    const zig_string = String.fromSlice(allocated_slice);
    defer zig_string.deinit();

    try testing.expect(@TypeOf(slice) == []const u8);
    try testing.expect(@TypeOf(allocated_slice) == []u8);
    try testing.expect(zig_string.len == 5);
    try testing.expect(zig_string.sentinel == false);
}

test "C API initialization errors do not require global state" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writeInitError(&writer, error.InvalidArg0);

    try std.testing.expectEqualStrings(
        "error: failed to initialize ghostty error=error.InvalidArg0\n",
        writer.buffered(),
    );
}
test "ghostty_resources_dir ABI" {
    const c = @import("ghostty.h");
    const testing = std.testing;

    try testing.expect(@hasDecl(c, "ghostty_resources_dir"));
    const function = @typeInfo(@TypeOf(c.ghostty_resources_dir)).@"fn";
    try testing.expectEqual(@as(usize, 0), function.params.len);
    try testing.expect(function.return_type.? == c.ghostty_string_s);
}

test "ghostty_resources_dir is empty before initialization" {
    const testing = std.testing;

    const was_initialized = initialized;
    initialized = false;
    defer initialized = was_initialized;

    const dir = ghostty_resources_dir();
    try testing.expectEqual(String.empty.ptr, dir.ptr);
    try testing.expectEqual(String.empty.len, dir.len);
    try testing.expectEqual(String.empty.sentinel, dir.sentinel);
}

test "ghostty_init returns success after initialization" {
    const testing = std.testing;

    const was_initialized = initialized;
    initialized = true;
    defer initialized = was_initialized;

    const arg0: [*:0]const u8 = "cmux";
    var argv = [_][*:0]const u8{arg0};
    try testing.expectEqual(
        @as(c_int, 0),
        ghostty_init(argv.len, argv[0..].ptr),
    );
}

test "ghostty_init argv normalization handles empty and null C vectors" {
    const testing = std.testing;

    const arg0: [*:0]const u8 = "cmux";
    var argv = [_][*:0]const u8{arg0};
    var provided = (try initArgv(testing.allocator, argv.len, argv[0..].ptr)).?;
    defer provided.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), provided.argv.len);
    try testing.expectEqualStrings("cmux", std.mem.sliceTo(provided.argv[0], 0));

    var fallback = (try initArgv(testing.allocator, 0, null)).?;
    defer fallback.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), fallback.argv.len);
    try testing.expectEqualStrings("ghostty", std.mem.sliceTo(fallback.argv[0], 0));

    try testing.expect(try initArgv(testing.allocator, 1, null) == null);

    var null_entry_words = [_]usize{0};
    const null_entry_argv: [*c]const [*:0]const u8 = @ptrCast(null_entry_words[0..].ptr);
    try testing.expect(try initArgv(testing.allocator, null_entry_words.len, null_entry_argv) == null);
}

test "ghostty_init argv normalization owns provided strings" {
    const testing = std.testing;

    var arg0 = [_]u8{ 'c', 'm', 'u', 'x', 0 };
    var arg1 = [_]u8{ '-', '-', 'v', 'e', 'r', 's', 'i', 'o', 'n', 0 };
    var argv = [_][*:0]const u8{
        arg0[0 .. arg0.len - 1 :0].ptr,
        arg1[0 .. arg1.len - 1 :0].ptr,
    };
    var provided = (try initArgv(testing.allocator, argv.len, argv[0..].ptr)).?;
    defer provided.deinit(testing.allocator);

    arg0[0] = 'X';
    arg1[2] = 'X';
    try testing.expectEqualStrings("cmux", std.mem.span(provided.argv[0]));
    try testing.expectEqualStrings("--version", std.mem.span(provided.argv[1]));
}
