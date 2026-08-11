//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gl = @import("opengl");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

const log = std.log.scoped(.opengl);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

const EmbeddedLinux = switch (apprt.runtime) {
    apprt.embedded => if (builtin.target.os.tag == .linux) apprt.embedded.Platform.Linux else void,
    else => void,
};

const EmbeddedLinuxState = if (EmbeddedLinux == void) void else ?struct {
    platform: EmbeddedLinux,
    surface: *apprt.Surface,
};

const must_draw_from_app_thread =
    if (@hasDecl(apprt.App, "must_draw_from_app_thread"))
        apprt.App.must_draw_from_app_thread
    else
        false;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// Linux embedded OpenGL host callbacks and surface metadata.
embedded_linux: EmbeddedLinuxState,

/// True when a Linux embedded frame has successfully made the host context current.
embedded_linux_context_current: bool,

/// Initializes the OpenGL renderer state. Embedded Linux must make the
/// host-owned context current before the generic renderer creates GL resources.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) !OpenGL {
    var result: OpenGL = .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .embedded_linux = embeddedLinuxState(opts.rt_surface),
        .embedded_linux_context_current = false,
    };
    errdefer result.endEmbeddedLinuxContext();
    if (comptime EmbeddedLinux != void) {
        if (result.embedded_linux) |state| {
            try result.beginEmbeddedLinuxContext(state.platform);
        }
    }
    return result;
}

pub fn deinit(self: *OpenGL) void {
    self.invalidateLastTarget();
    self.endEmbeddedLinuxContext();
    self.* = undefined;
}

pub fn deinitStart(self: *OpenGL) bool {
    self.invalidateLastTarget();
    if (comptime EmbeddedLinux == void) return true;
    const state = self.embedded_linux orelse return true;
    self.beginEmbeddedLinuxContext(state.platform) catch |err| {
        log.warn("failed to make embedded Linux OpenGL context current before deinit err={}", .{err});
        return false;
    };
    return true;
}

pub fn deinitDone(self: *OpenGL) void {
    self.endEmbeddedLinuxContext();
}

pub fn initDone(self: *OpenGL) void {
    self.endEmbeddedLinuxContext();
}

/// Transfer host-context ownership from the temporary API value used during
/// generic renderer initialization to the value stored in the renderer.
pub fn transferInitState(self: *OpenGL, target: *OpenGL) void {
    target.embedded_linux_context_current = self.embedded_linux_context_current;
    self.embedded_linux_context_current = false;
}

/// Clear any cached target that may reference GL objects owned by the
/// renderer swap chain. The generic renderer calls this before those
/// targets are resized or destroyed.
pub fn invalidateLastTarget(self: *OpenGL) void {
    self.last_target = null;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

threadlocal var embedded_linux_loader: ?EmbeddedLinux = null;
threadlocal var context_prepared = false;

fn embeddedLinuxGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const fn () callconv(.c) void {
    if (comptime EmbeddedLinux == void) return null;

    const platform = embedded_linux_loader orelse return null;
    const proc = platform.get_proc_address(platform.userdata, name) orelse return null;
    return @ptrCast(proc);
}

fn embeddedLinuxState(surface: *apprt.Surface) EmbeddedLinuxState {
    if (comptime EmbeddedLinux == void) return {};

    return switch (surface.platform) {
        .linux => |platform| .{
            .platform = platform,
            .surface = surface,
        },
        else => null,
    };
}

fn embeddedLinuxMakeCurrent(platform: EmbeddedLinux) !void {
    if (comptime EmbeddedLinux == void) return;
    if (!platform.make_current(platform.userdata)) return error.OpenGLContextUnavailable;
}

fn embeddedLinuxDoneCurrent(platform: EmbeddedLinux) void {
    if (comptime EmbeddedLinux == void) return;
    if (platform.done_current) |func| func(platform.userdata);
}

fn prepareEmbeddedLinuxContext(platform: EmbeddedLinux) !void {
    if (comptime EmbeddedLinux == void) return;
    try embeddedLinuxMakeCurrent(platform);
    defer embeddedLinuxDoneCurrent(platform);
    embedded_linux_loader = platform;
    defer embedded_linux_loader = null;
    try prepareContext(&embeddedLinuxGetProcAddress);
}

fn beginEmbeddedLinuxContext(self: *OpenGL, platform: EmbeddedLinux) !void {
    if (comptime EmbeddedLinux == void) return;
    if (self.embedded_linux_context_current) return;
    try embeddedLinuxMakeCurrent(platform);
    self.embedded_linux_context_current = true;
}

fn endEmbeddedLinuxContext(self: *OpenGL) void {
    if (comptime EmbeddedLinux == void) return;
    if (!self.embedded_linux_context_current) return;
    self.embedded_linux_context_current = false;
    const state = self.embedded_linux orelse return;
    embeddedLinuxDoneCurrent(state.platform);
}

test "embedded Linux OpenGL context callbacks are balanced" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;
        var make_current_result: bool = true;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return make_current_result;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var api: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = false,
    };

    try api.beginEmbeddedLinuxContext(platform);
    try std.testing.expect(api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);

    try api.beginEmbeddedLinuxContext(platform);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);

    api.endEmbeddedLinuxContext();
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    api.endEmbeddedLinuxContext();
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    Context.make_current_result = false;
    try std.testing.expectError(error.OpenGLContextUnavailable, api.beginEmbeddedLinuxContext(platform));
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "embedded Linux OpenGL initialization state follows moved API value" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var done_current_calls: usize = 0;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            return true;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var source: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = true,
    };
    var target = source;

    source.transferInitState(&target);
    try std.testing.expect(!source.embedded_linux_context_current);
    try std.testing.expect(target.embedded_linux_context_current);

    source.initDone();
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);
    target.initDone();
    try std.testing.expect(!target.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "embedded Linux OpenGL initDone releases initialization context" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return true;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var api: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = false,
    };

    try api.beginEmbeddedLinuxContext(platform);
    try std.testing.expect(api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);

    api.initDone();
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    api.initDone();
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "embedded Linux OpenGL deinit releases current context" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return true;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var api: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = false,
    };

    try api.beginEmbeddedLinuxContext(platform);
    api.deinit();

    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "embedded Linux OpenGL deinitStart and deinitDone bracket cleanup context" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;
        var make_current_result: bool = true;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return make_current_result;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var api: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = false,
    };

    try std.testing.expect(api.deinitStart());
    try std.testing.expect(api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);

    api.deinitDone();
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    Context.make_current_result = false;
    try std.testing.expect(!api.deinitStart());
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "embedded Linux OpenGL draw frame brackets host context" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;
        var make_current_result: bool = true;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return make_current_result;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var api: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = false,
    };

    try api.drawFrameStart();
    try std.testing.expect(api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);

    try api.drawFrameStart();
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);

    api.drawFrameEnd();
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    api.drawFrameEnd();
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    Context.make_current_result = false;
    try std.testing.expectError(error.OpenGLContextUnavailable, api.drawFrameStart());
    try std.testing.expect(!api.embedded_linux_context_current);
    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "embedded Linux OpenGL lifecycle invalidates cached target" {
    if (comptime EmbeddedLinux == void) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;
        var make_current_result: bool = true;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return make_current_result;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    const platform: EmbeddedLinux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    };
    const fake_surface: *apprt.Surface = @ptrFromInt(@alignOf(apprt.Surface));
    var api: OpenGL = .{
        .alloc = std.testing.allocator,
        .blending = .native,
        .embedded_linux = .{
            .platform = platform,
            .surface = fake_surface,
        },
        .embedded_linux_context_current = false,
    };

    api.last_target = .{
        .framebuffer = .{ .id = 11 },
        .renderbuffer = .{ .id = 12 },
        .width = 80,
        .height = 24,
    };
    try api.displayUnrealized();
    try std.testing.expect(api.last_target == null);
    try std.testing.expect(api.embedded_linux_context_current);
    api.displayUnrealizedDone();
    try std.testing.expect(!api.embedded_linux_context_current);

    api.last_target = .{
        .framebuffer = .{ .id = 21 },
        .renderbuffer = .{ .id = 22 },
        .width = 100,
        .height = 40,
    };
    Context.make_current_result = false;
    try std.testing.expect(!api.deinitStart());
    try std.testing.expect(api.last_target == null);
    try std.testing.expect(!api.embedded_linux_context_current);

    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    // GLAD's dispatch table is thread-local and shared by every renderer on
    // this thread. Loading a second context writes into that table before we
    // can validate its version and required functions, so preserve a working
    // table until the new context has passed all preparation steps.
    const previous_context: ?gl.glad.Context = if (context_prepared)
        gl.glad.context
    else
        null;
    const version = gl.glad.load(getProcAddress) catch |err| {
        if (previous_context) |previous| gl.glad.context = previous;
        return err;
    };
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer restoreContextAfterPrepareFailure(previous_context);
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);

    context_prepared = true;
}

fn restoreContextAfterPrepareFailure(previous: ?gl.glad.Context) void {
    if (previous) |context| {
        gl.glad.context = context;
    } else {
        gl.glad.unload();
    }
}

test "OpenGL preparation failure restores prior thread dispatch table" {
    const previous_prepared = context_prepared;
    var previous_thread_context: gl.glad.Context = undefined;
    if (previous_prepared) previous_thread_context = gl.glad.context;
    defer {
        context_prepared = previous_prepared;
        gl.glad.context = if (previous_prepared) previous_thread_context else undefined;
    }

    var working: gl.glad.Context = std.mem.zeroes(gl.glad.Context);
    working.VERSION_4_3 = 1;
    gl.glad.context = std.mem.zeroes(gl.glad.Context);

    restoreContextAfterPrepareFailure(working);

    try std.testing.expectEqual(@as(c_int, 1), gl.glad.context.VERSION_4_3);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        // GTK uses global OpenGL context so we load from null.
        apprt.gtk,
        => try prepareContext(null),

        apprt.embedded => {
            if (comptime EmbeddedLinux != void) {
                switch (surface.platform) {
                    .linux => |platform| try prepareEmbeddedLinuxContext(platform),
                    else => return error.UnsupportedEmbeddedOpenGLPlatform,
                }
            }
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = surface;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK doesn't support threaded OpenGL operations as far as I can
            // tell, so we use the renderer thread to setup all the state
            // but then do the actual draws and texture syncs and all that
            // on the main thread. As such, we don't do anything here.
        },

        apprt.embedded => {
            if (comptime must_draw_from_app_thread) return;

            if (comptime EmbeddedLinux != void) {
                if (self.embedded_linux) |state| {
                    embeddedLinuxMakeCurrent(state.platform) catch |err| {
                        log.warn("failed to make embedded Linux OpenGL context current on thread enter err={}", .{err});
                    };
                }
            }
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // We don't need to do any unloading for GTK because we may
            // be sharing the global bindings with other windows.
        },

        apprt.embedded => {
            if (comptime EmbeddedLinux != void and !must_draw_from_app_thread) {
                if (self.embedded_linux) |state| embeddedLinuxDoneCurrent(state.platform);
            }
        },
    }
}

pub fn displayRealized(self: *OpenGL) !void {
    self.invalidateLastTarget();

    switch (apprt.runtime) {
        apprt.gtk => try prepareContext(null),

        apprt.embedded => {
            if (comptime EmbeddedLinux != void) {
                const state = self.embedded_linux orelse return;
                try self.beginEmbeddedLinuxContext(state.platform);
                errdefer self.endEmbeddedLinuxContext();
                embedded_linux_loader = state.platform;
                defer embedded_linux_loader = null;
                try prepareContext(&embeddedLinuxGetProcAddress);
            }
        },

        else => @compileError("unsupported app runtime for OpenGL displayRealized"),
    }
}

pub fn displayRealizedDone(self: *OpenGL) void {
    self.endEmbeddedLinuxContext();
}

pub fn displayUnrealized(self: *OpenGL) !void {
    self.invalidateLastTarget();

    if (comptime EmbeddedLinux == void) return;

    const state = self.embedded_linux orelse return;
    try self.beginEmbeddedLinuxContext(state.platform);
}

pub fn displayUnrealizedDone(self: *OpenGL) void {
    self.endEmbeddedLinuxContext();
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *OpenGL) !void {
    if (comptime EmbeddedLinux == void) return;

    const state = self.embedded_linux orelse return;
    try self.beginEmbeddedLinuxContext(state.platform);
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    self.endEmbeddedLinuxContext();
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    if (comptime EmbeddedLinux != void) {
        if (self.embedded_linux) |state| {
            const size = try state.surface.getSize();
            try gl.viewport(0, 0, @intCast(size.width), @intCast(size.height));
            return .{
                .width = size.width,
                .height = size.height,
            };
        }
    }

    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
    });
}

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    var ops: PresentationOps = .{};
    return presentWithOps(self, target, &ops);
}

const PresentationOps = struct {
    fn disableSRGB(_: *@This()) !void {
        return gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    }

    fn bindRead(_: *@This(), target: Target) !gl.Framebuffer.Binding {
        return target.framebuffer.bind(.read);
    }

    fn blit(_: *@This(), target: Target) void {
        gl.glad.context.BlitFramebuffer.?(
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            gl.c.GL_COLOR_BUFFER_BIT,
            gl.c.GL_NEAREST,
        );
    }

    fn captureBlitResult(_: *@This()) gl.errors.Error!void {
        return gl.errors.getError();
    }

    fn unbindRead(_: *@This(), binding: gl.Framebuffer.Binding) void {
        binding.unbind();
    }

    fn restoreSRGB(_: *@This()) !void {
        return gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
    }

    fn restoreSRGBUnchecked(_: *@This()) void {
        gl.glad.context.Enable.?(gl.c.GL_FRAMEBUFFER_SRGB);
    }
};

/// Blit a target while preserving both the presentation result and the state
/// restoration result. This is generic so the error-ordering contract can be
/// tested without a live OpenGL context.
fn presentWithOps(
    self: anytype,
    target: anytype,
    ops: anytype,
) !void {
    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear.
    ops.disableSRGB() catch |err| {
        // Do not run a checked cleanup here because it could drain an error
        // that belongs to the failed operation we are returning.
        ops.restoreSRGBUnchecked();
        return err;
    };

    // Bind the target for reading. A setup failure still restores the default
    // framebuffer's sRGB state without consuming the original error.
    const binding = ops.bindRead(target) catch |err| {
        ops.restoreSRGBUnchecked();
        return err;
    };

    // Capture the blit result before either cleanup operation can call
    // glGetError and consume it.
    ops.blit(target);
    const blit_result = ops.captureBlitResult();

    // Always restore the read framebuffer binding and sRGB state. The checked
    // sRGB restore also reports any error raised by the unchecked unbind.
    ops.unbindRead(binding);
    const restore_result = ops.restoreSRGB();

    // Both cleanup operations have run before either stored result propagates.
    try blit_result;
    try restore_result;

    // Repeat only a fully validated, state-restored presentation.
    self.last_target = target;
}

/// Block until every command for the presented frame has completed.
pub fn finishFrame(_: *OpenGL) void {
    gl.finish();
}

/// Inspect the GL error state only after the presentation fence completes.
pub fn frameHealth(_: *OpenGL) rendererpkg.Health {
    return if (gl.errors.getError()) .healthy else |_| .unhealthy;
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    if (self.last_target) |target| try self.present(target);
}

test "OpenGL presentation preserves blit errors through state restoration" {
    const testing = std.testing;
    const Failure = error{
        BlitFailed,
        BindFailed,
        RestoreFailed,
    };
    const Event = enum {
        disable_srgb,
        bind_read,
        blit,
        capture_blit,
        unbind_read,
        restore_srgb,
        restore_srgb_unchecked,
    };
    const MockTarget = struct { id: u8 };
    const State = struct {
        events: [8]Event = undefined,
        len: usize = 0,
        fail_bind: bool = false,
        fail_blit: bool = false,
        fail_restore: bool = false,
        pending_error: ?Failure = null,

        fn append(self: *@This(), event: Event) void {
            self.events[self.len] = event;
            self.len += 1;
        }
    };
    const MockRenderer = struct {
        last_target: ?MockTarget = null,
    };
    const MockOps = struct {
        state: *State,

        fn disableSRGB(self: *@This()) Failure!void {
            self.state.append(.disable_srgb);
        }

        fn bindRead(self: *@This(), target: MockTarget) Failure!u8 {
            self.state.append(.bind_read);
            if (self.state.fail_bind) return error.BindFailed;
            return target.id;
        }

        fn blit(self: *@This(), _: MockTarget) void {
            self.state.append(.blit);
            if (self.state.fail_blit) {
                self.state.pending_error = error.BlitFailed;
            }
        }

        fn captureBlitResult(self: *@This()) Failure!void {
            self.state.append(.capture_blit);
            if (self.state.pending_error) |err| {
                self.state.pending_error = null;
                return err;
            }
        }

        fn unbindRead(self: *@This(), _: u8) void {
            self.state.append(.unbind_read);
        }

        fn restoreSRGB(self: *@This()) Failure!void {
            self.state.append(.restore_srgb);
            // The pre-fix checked restore consumes a pending blit error.
            if (self.state.pending_error) |err| {
                self.state.pending_error = null;
                return err;
            }
            if (self.state.fail_restore) return error.RestoreFailed;
        }

        fn restoreSRGBUnchecked(self: *@This()) void {
            self.state.append(.restore_srgb_unchecked);
        }
    };
    const Harness = struct {
        fn present(
            renderer: *MockRenderer,
            target: MockTarget,
            ops: *MockOps,
        ) Failure!void {
            if (@hasDecl(OpenGL, "presentWithOps")) {
                return OpenGL.presentWithOps(renderer, target, ops);
            }

            // Exercise the pre-fix defer order: last_target is committed,
            // then unbind runs, then checked restore drains and logs the blit
            // error while the caller incorrectly observes success.
            try ops.disableSRGB();
            const binding = ops.bindRead(target) catch |err| {
                ops.restoreSRGBUnchecked();
                return err;
            };
            ops.blit(target);
            renderer.last_target = target;
            ops.unbindRead(binding);
            ops.restoreSRGB() catch {};
        }
    };

    const target: MockTarget = .{ .id = 7 };
    var state: State = .{ .fail_blit = true };
    var renderer: MockRenderer = .{};
    var ops: MockOps = .{ .state = &state };
    const blit_result = Harness.present(&renderer, target, &ops);
    const blit_token: ?u64 = if (blit_result) |_| 42 else |_| null;
    try testing.expectEqual(null, blit_token);
    try testing.expectError(error.BlitFailed, blit_result);
    try testing.expectEqual(null, renderer.last_target);
    try testing.expectEqualSlices(Event, &.{
        .disable_srgb,
        .bind_read,
        .blit,
        .capture_blit,
        .unbind_read,
        .restore_srgb,
    }, state.events[0..state.len]);

    state = .{ .fail_restore = true };
    renderer = .{};
    ops = .{ .state = &state };
    const restore_result = Harness.present(&renderer, target, &ops);
    const restore_token: ?u64 = if (restore_result) |_| 42 else |_| null;
    try testing.expectEqual(null, restore_token);
    try testing.expectError(error.RestoreFailed, restore_result);
    try testing.expectEqual(null, renderer.last_target);

    state = .{ .fail_bind = true };
    renderer = .{};
    ops = .{ .state = &state };
    try testing.expectError(
        error.BindFailed,
        Harness.present(&renderer, target, &ops),
    );
    try testing.expectEqualSlices(Event, &.{
        .disable_srgb,
        .bind_read,
        .restore_srgb_unchecked,
    }, state.events[0..state.len]);
    try testing.expectEqual(null, renderer.last_target);
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target, null);
}

/// Begin a frame whose successful presentation acknowledges an opaque token.
pub inline fn beginFrameWithPresentation(
    self: *const OpenGL,
    renderer: *Renderer,
    target: *Target,
    presentation: rendererpkg.FramePresentation,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target, presentation);
}
