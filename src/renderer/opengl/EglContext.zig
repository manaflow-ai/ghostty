//! cmux fork: a surfaceless (offscreen) EGL context for libghostty's OpenGL
//! renderer on the embedded `offscreen` platform (no native window). The
//! renderer draws into its own FBO and the embedder receives a CPU readback or
//! an exported dmabuf; no window or default framebuffer is involved. Works with
//! software Mesa (llvmpipe), so no GPU is required for CPU readback.
//!
//! The context is desktop OpenGL 4.3 core on EGL_PLATFORM_SURFACELESS_MESA, so
//! it needs Mesa's EGL. ANGLE (OpenGL ES only) cannot provide it.
//!
//! Bindings are declared `extern` (no EGL headers) so this cross-compiles from
//! any host. On Linux the final binary links `-lEGL`. On Windows Mesa's
//! libEGL.dll is loaded at runtime (see loadMesaEgl).

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.egl_offscreen);

// On Windows, EGL is provided by an isolated Mesa libEGL.dll loaded at runtime
// (so it never collides with chrome's ANGLE libEGL and lets libghostty link as a
// self-contained DLL). Elsewhere the egl* symbols are linked directly (-lEGL).
const is_windows = builtin.os.tag == .windows;

pub const EGLDisplay = ?*anyopaque;
pub const EGLConfig = ?*anyopaque;
pub const EGLContext = ?*anyopaque;
pub const EGLSurface = ?*anyopaque;
const EGLint = i32;
const EGLenum = c_uint;
const EGLBoolean = c_uint;
const EGLAttrib = isize;

/// Matches glad's expected getProcAddress shape (see pkg/opengl/glad.zig).
const GlProc = *const fn () callconv(.c) void;

const EGL_NO_DISPLAY: EGLDisplay = null;
const EGL_NO_CONTEXT: EGLContext = null;
const EGL_NO_SURFACE: EGLSurface = null;
const EGL_DEFAULT_DISPLAY: ?*anyopaque = null;

const EGL_TRUE: EGLBoolean = 1;
const EGL_NONE: EGLint = 0x3038;
const EGL_PLATFORM_SURFACELESS_MESA: EGLenum = 0x31DD;
const EGL_OPENGL_API: EGLenum = 0x30A2;

// Config attributes.
const EGL_SURFACE_TYPE: EGLint = 0x3033;
const EGL_PBUFFER_BIT: EGLint = 0x0001;
const EGL_RENDERABLE_TYPE: EGLint = 0x3040;
const EGL_OPENGL_BIT: EGLint = 0x0008;
const EGL_RED_SIZE: EGLint = 0x3024;
const EGL_GREEN_SIZE: EGLint = 0x3023;
const EGL_BLUE_SIZE: EGLint = 0x3022;
const EGL_ALPHA_SIZE: EGLint = 0x3021;

// Context attributes.
const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK: EGLint = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: EGLint = 0x00000001;

// Function-pointer types for the EGL entry points we use.
const FnGetPlatformDisplay = *const fn (EGLenum, ?*anyopaque, ?[*]const EGLAttrib) callconv(.c) EGLDisplay;
const FnInitialize = *const fn (EGLDisplay, ?*EGLint, ?*EGLint) callconv(.c) EGLBoolean;
const FnTerminate = *const fn (EGLDisplay) callconv(.c) EGLBoolean;
const FnBindAPI = *const fn (EGLenum) callconv(.c) EGLBoolean;
const FnChooseConfig = *const fn (EGLDisplay, [*]const EGLint, ?[*]EGLConfig, EGLint, *EGLint) callconv(.c) EGLBoolean;
const FnCreateContext = *const fn (EGLDisplay, EGLConfig, EGLContext, [*]const EGLint) callconv(.c) EGLContext;
const FnDestroyContext = *const fn (EGLDisplay, EGLContext) callconv(.c) EGLBoolean;
const FnMakeCurrent = *const fn (EGLDisplay, EGLSurface, EGLSurface, EGLContext) callconv(.c) EGLBoolean;
const FnGetError = *const fn () callconv(.c) EGLint;
const FnGetProcAddress = *const fn ([*:0]const u8) callconv(.c) ?GlProc;

const EglApi = struct {
    getPlatformDisplay: FnGetPlatformDisplay,
    initialize: FnInitialize,
    terminate: FnTerminate,
    bindAPI: FnBindAPI,
    chooseConfig: FnChooseConfig,
    createContext: FnCreateContext,
    destroyContext: FnDestroyContext,
    makeCurrent: FnMakeCurrent,
    getError: FnGetError,
    getProcAddress: FnGetProcAddress,
};

// ---- Windows: isolated Mesa libEGL loading (kept out of non-Windows link) ----
const WinHMODULE = *opaque {};
extern "kernel32" fn GetModuleFileNameW(hModule: ?WinHMODULE, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW(lpLibFileName: [*:0]const u16, hFile: ?*anyopaque, dwFlags: u32) callconv(.winapi) ?WinHMODULE;
extern "kernel32" fn GetProcAddress(hModule: WinHMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
const WinGetProcAddress = GetProcAddress;

fn loadMesaEgl() ?WinHMODULE {
    const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x00000008;
    var buf: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, @intCast(buf.len));
    if (n > 0 and n < buf.len) {
        var dir_len: usize = 0;
        var i: usize = @intCast(n);
        while (i > 0) : (i -= 1) {
            if (buf[i - 1] == '\\') {
                dir_len = i;
                break;
            }
        }
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral("cmux_mesa\\libEGL.dll");
        if (dir_len + suffix.len + 1 < buf.len) {
            @memcpy(buf[dir_len .. dir_len + suffix.len], suffix);
            buf[dir_len + suffix.len] = 0;
            if (LoadLibraryExW(@ptrCast(&buf), null, LOAD_WITH_ALTERED_SEARCH_PATH)) |h| return h;
        }
    }
    // Fallback: plain libEGL.dll on the default search path (app dir).
    const fallback = std.unicode.utf8ToUtf16LeStringLiteral("libEGL.dll");
    return LoadLibraryExW(fallback, null, 0);
}

fn loadApi() !EglApi {
    if (comptime is_windows) {
        // Load MESA's libEGL from an isolated "cmux_mesa\" dir next to the exe,
        // so it (and its gallium deps) never collide with chrome's own ANGLE
        // libEGL.dll in the app dir. LOAD_WITH_ALTERED_SEARCH_PATH makes the
        // DLL's dependencies resolve from that same dir. Falls back to a plain
        // "libEGL.dll" (app-dir) for standalone hosts.
        const hmod = loadMesaEgl() orelse {
            log.err("failed to load Mesa libEGL.dll (cmux_mesa\\ or app dir)", .{});
            return error.EglLibraryNotFound;
        };
        const L = struct {
            fn get(m: WinHMODULE, comptime T: type, comptime n: [:0]const u8) !T {
                return @ptrCast(WinGetProcAddress(m, n) orelse {
                    log.err("libEGL.dll is missing " ++ n, .{});
                    return error.EglSymbolNotFound;
                });
            }
        };
        return .{
            .getPlatformDisplay = try L.get(hmod, FnGetPlatformDisplay, "eglGetPlatformDisplay"),
            .initialize = try L.get(hmod, FnInitialize, "eglInitialize"),
            .terminate = try L.get(hmod, FnTerminate, "eglTerminate"),
            .bindAPI = try L.get(hmod, FnBindAPI, "eglBindAPI"),
            .chooseConfig = try L.get(hmod, FnChooseConfig, "eglChooseConfig"),
            .createContext = try L.get(hmod, FnCreateContext, "eglCreateContext"),
            .destroyContext = try L.get(hmod, FnDestroyContext, "eglDestroyContext"),
            .makeCurrent = try L.get(hmod, FnMakeCurrent, "eglMakeCurrent"),
            .getError = try L.get(hmod, FnGetError, "eglGetError"),
            .getProcAddress = try L.get(hmod, FnGetProcAddress, "eglGetProcAddress"),
        };
    } else {
        return .{
            .getPlatformDisplay = @extern(FnGetPlatformDisplay, .{ .name = "eglGetPlatformDisplay" }),
            .initialize = @extern(FnInitialize, .{ .name = "eglInitialize" }),
            .terminate = @extern(FnTerminate, .{ .name = "eglTerminate" }),
            .bindAPI = @extern(FnBindAPI, .{ .name = "eglBindAPI" }),
            .chooseConfig = @extern(FnChooseConfig, .{ .name = "eglChooseConfig" }),
            .createContext = @extern(FnCreateContext, .{ .name = "eglCreateContext" }),
            .destroyContext = @extern(FnDestroyContext, .{ .name = "eglDestroyContext" }),
            .makeCurrent = @extern(FnMakeCurrent, .{ .name = "eglMakeCurrent" }),
            .getError = @extern(FnGetError, .{ .name = "eglGetError" }),
            .getProcAddress = @extern(FnGetProcAddress, .{ .name = "eglGetProcAddress" }),
        };
    }
}

var g_api: ?EglApi = null;

/// Resolve the EGL entry points. Called by EglContext.init before any other
/// EGL call; later calls reuse the result. Only the drawing (app) thread
/// touches EGL, so this needs no lock.
fn loadApiOnce() !void {
    if (g_api == null) g_api = try loadApi();
}

fn api() *const EglApi {
    return &(g_api.?);
}

// Same-named wrappers so the rest of this file (and OpenGL.zig's reference to
// `eglGetProcAddress`) is unchanged.
fn eglGetPlatformDisplay(platform: EGLenum, native_display: ?*anyopaque, attrib_list: ?[*]const EGLAttrib) callconv(.c) EGLDisplay {
    return api().getPlatformDisplay(platform, native_display, attrib_list);
}
fn eglInitialize(dpy: EGLDisplay, major: ?*EGLint, minor: ?*EGLint) callconv(.c) EGLBoolean {
    return api().initialize(dpy, major, minor);
}
fn eglTerminate(dpy: EGLDisplay) callconv(.c) EGLBoolean {
    return api().terminate(dpy);
}
fn eglBindAPI(a: EGLenum) callconv(.c) EGLBoolean {
    return api().bindAPI(a);
}
fn eglChooseConfig(dpy: EGLDisplay, attrib_list: [*]const EGLint, configs: ?[*]EGLConfig, config_size: EGLint, num_config: *EGLint) callconv(.c) EGLBoolean {
    return api().chooseConfig(dpy, attrib_list, configs, config_size, num_config);
}
fn eglCreateContext(dpy: EGLDisplay, config: EGLConfig, share_context: EGLContext, attrib_list: [*]const EGLint) callconv(.c) EGLContext {
    return api().createContext(dpy, config, share_context, attrib_list);
}
fn eglDestroyContext(dpy: EGLDisplay, ctx: EGLContext) callconv(.c) EGLBoolean {
    return api().destroyContext(dpy, ctx);
}
fn eglMakeCurrent(dpy: EGLDisplay, draw: EGLSurface, read: EGLSurface, ctx: EGLContext) callconv(.c) EGLBoolean {
    return api().makeCurrent(dpy, draw, read, ctx);
}
fn eglGetError() callconv(.c) EGLint {
    return api().getError();
}

/// Passed to glad to load GL function pointers from this EGL context.
pub fn eglGetProcAddress(procname: [*:0]const u8) callconv(.c) ?GlProc {
    return api().getProcAddress(procname);
}

// ---- dmabuf export (EGL_KHR_image_base + EGL_MESA_image_dma_buf_export) ----
//
// These are extension entry points, loaded at runtime via eglGetProcAddress
// (they are not guaranteed in libEGL's link surface). Only single-plane RGBA
// export is handled (the renderer's offscreen target is RGBA8). This requires a
// real GPU driver / Mesa with a DRM render node; software llvmpipe does NOT
// export dmabufs (Rung 2 uses CPU readback instead).

const EGLImageKHR = ?*anyopaque;
const EGLClientBuffer = ?*anyopaque;
const EGL_NO_IMAGE_KHR: EGLImageKHR = null;
const EGL_GL_TEXTURE_2D_KHR: EGLenum = 0x30B1;

const PFNeglCreateImageKHR = *const fn (
    EGLDisplay,
    EGLContext,
    EGLenum,
    EGLClientBuffer,
    ?[*]const EGLint,
) callconv(.c) EGLImageKHR;
const PFNeglDestroyImageKHR = *const fn (EGLDisplay, EGLImageKHR) callconv(.c) EGLBoolean;
const PFNeglExportDMABUFImageQueryMESA = *const fn (
    EGLDisplay,
    EGLImageKHR,
    *EGLint, // fourcc
    *EGLint, // num_planes
    ?[*]u64, // modifiers
) callconv(.c) EGLBoolean;
const PFNeglExportDMABUFImageMESA = *const fn (
    EGLDisplay,
    EGLImageKHR,
    ?[*]EGLint, // fds
    ?[*]EGLint, // strides
    ?[*]EGLint, // offsets
) callconv(.c) EGLBoolean;

/// A handle to a single-plane dmabuf-backed frame. ABI-stable (C layout) so it
/// can be handed to the embedder's frame callback verbatim. `fd` is owned by
/// the receiver and must be `close()`d. `modifier` is split into hi/lo halves
/// to keep the struct's C alignment trivial.
pub const DmabufFrame = extern struct {
    fd: i32 = -1,
    fourcc: u32 = 0,
    num_planes: u32 = 0,
    stride: u32 = 0,
    offset: u32 = 0,
    modifier_hi: u32 = 0,
    modifier_lo: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const EglContext = struct {
    dpy: EGLDisplay = EGL_NO_DISPLAY,
    ctx: EGLContext = EGL_NO_CONTEXT,

    // dmabuf export entry points, lazily loaded on first export.
    createImage: ?PFNeglCreateImageKHR = null,
    destroyImage: ?PFNeglDestroyImageKHR = null,
    exportQuery: ?PFNeglExportDMABUFImageQueryMESA = null,
    exportImage: ?PFNeglExportDMABUFImageMESA = null,
    dmabuf_loaded: bool = false,

    pub fn init() !EglContext {
        try loadApiOnce();
        const dpy = eglGetPlatformDisplay(
            EGL_PLATFORM_SURFACELESS_MESA,
            EGL_DEFAULT_DISPLAY,
            null,
        );
        if (dpy == EGL_NO_DISPLAY) {
            log.err("eglGetPlatformDisplay(surfaceless) failed", .{});
            return error.EglNoDisplay;
        }
        if (eglInitialize(dpy, null, null) != EGL_TRUE) {
            log.err("eglInitialize failed err=0x{x}", .{eglGetError()});
            return error.EglInitFailed;
        }
        errdefer _ = eglTerminate(dpy);

        if (eglBindAPI(EGL_OPENGL_API) != EGL_TRUE) {
            log.err("eglBindAPI(OpenGL) failed err=0x{x}", .{eglGetError()});
            return error.EglBindApiFailed;
        }

        const config_attribs = [_]EGLint{
            EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      8,
            EGL_NONE,
        };
        var config: EGLConfig = null;
        var num_config: EGLint = 0;
        if (eglChooseConfig(
            dpy,
            &config_attribs,
            @ptrCast(&config),
            1,
            &num_config,
        ) != EGL_TRUE or num_config < 1) {
            log.err("eglChooseConfig failed err=0x{x}", .{eglGetError()});
            return error.EglChooseConfigFailed;
        }

        // Request a 4.3 core context to match the renderer's MIN_VERSION.
        const context_attribs = [_]EGLint{
            EGL_CONTEXT_MAJOR_VERSION,        4,
            EGL_CONTEXT_MINOR_VERSION,        3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK,  EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE,
        };
        const ctx = eglCreateContext(dpy, config, EGL_NO_CONTEXT, &context_attribs);
        if (ctx == EGL_NO_CONTEXT) {
            log.err("eglCreateContext failed err=0x{x}", .{eglGetError()});
            return error.EglCreateContextFailed;
        }

        log.info("offscreen EGL context created (surfaceless)", .{});
        return .{ .dpy = dpy, .ctx = ctx };
    }

    /// Make this context current on the calling thread, with no draw/read
    /// surface (surfaceless; the renderer binds its own FBO). Requires the
    /// widely-supported EGL_KHR_surfaceless_context extension.
    pub fn makeCurrent(self: EglContext) !void {
        if (eglMakeCurrent(self.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, self.ctx) != EGL_TRUE) {
            log.err("eglMakeCurrent failed err=0x{x}", .{eglGetError()});
            return error.EglMakeCurrentFailed;
        }
    }

    pub fn clearCurrent(self: EglContext) void {
        _ = eglMakeCurrent(self.dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }

    fn loadDmabufProcs(self: *EglContext) !void {
        if (self.dmabuf_loaded) return;
        self.createImage = @ptrCast(eglGetProcAddress("eglCreateImageKHR") orelse {
            log.err("eglCreateImageKHR unavailable (no EGL_KHR_image_base)", .{});
            return error.EglNoDmabufExport;
        });
        self.destroyImage = @ptrCast(eglGetProcAddress("eglDestroyImageKHR") orelse
            return error.EglNoDmabufExport);
        self.exportQuery = @ptrCast(eglGetProcAddress("eglExportDMABUFImageQueryMESA") orelse {
            log.err("eglExportDMABUFImageQueryMESA unavailable (no EGL_MESA_image_dma_buf_export)", .{});
            return error.EglNoDmabufExport;
        });
        self.exportImage = @ptrCast(eglGetProcAddress("eglExportDMABUFImageMESA") orelse
            return error.EglNoDmabufExport);
        self.dmabuf_loaded = true;
    }

    /// Export a GL 2D texture (the offscreen render target) as a single-plane
    /// dmabuf. The returned `fd` is owned by the caller and must be closed.
    /// Requires a GPU/Mesa driver supporting EGL_MESA_image_dma_buf_export.
    pub fn exportTexture(self: *EglContext, texid: u32, width: u32, height: u32) !DmabufFrame {
        try self.loadDmabufProcs();

        const attribs = [_]EGLint{EGL_NONE};
        const client: EGLClientBuffer = @ptrFromInt(@as(usize, texid));
        const image = self.createImage.?(
            self.dpy,
            self.ctx,
            EGL_GL_TEXTURE_2D_KHR,
            client,
            &attribs,
        );
        if (image == EGL_NO_IMAGE_KHR) {
            log.err("eglCreateImageKHR failed err=0x{x}", .{eglGetError()});
            return error.EglCreateImageFailed;
        }
        defer _ = self.destroyImage.?(self.dpy, image);

        var fourcc: EGLint = 0;
        var num_planes: EGLint = 0;
        var modifiers: [4]u64 = .{ 0, 0, 0, 0 };
        if (self.exportQuery.?(self.dpy, image, &fourcc, &num_planes, &modifiers) != EGL_TRUE) {
            log.err("eglExportDMABUFImageQueryMESA failed err=0x{x}", .{eglGetError()});
            return error.EglExportQueryFailed;
        }

        var fds: [4]EGLint = .{ -1, -1, -1, -1 };
        var strides: [4]EGLint = .{ 0, 0, 0, 0 };
        var offsets: [4]EGLint = .{ 0, 0, 0, 0 };
        if (self.exportImage.?(self.dpy, image, &fds, &strides, &offsets) != EGL_TRUE) {
            log.err("eglExportDMABUFImageMESA failed err=0x{x}", .{eglGetError()});
            return error.EglExportFailed;
        }

        // Only a single-plane layout fits DmabufFrame. Close every exported
        // fd before failing so the caller can fall back without a leak.
        const fd = try takeSinglePlaneFd(num_planes, &fds);
        return .{
            .fd = fd,
            .fourcc = @bitCast(fourcc),
            .num_planes = @intCast(num_planes),
            .stride = @bitCast(strides[0]),
            .offset = @bitCast(offsets[0]),
            .modifier_hi = @truncate(modifiers[0] >> 32),
            .modifier_lo = @truncate(modifiers[0] & 0xFFFFFFFF),
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *EglContext) void {
        if (self.ctx != EGL_NO_CONTEXT) _ = eglDestroyContext(self.dpy, self.ctx);
        if (self.dpy != EGL_NO_DISPLAY) _ = eglTerminate(self.dpy);
        self.* = .{};
    }
};

/// Return the single exported plane fd, or close every valid fd and fail when
/// the export is not exactly one plane with a valid fd. On success the caller
/// owns the returned fd.
fn takeSinglePlaneFd(num_planes: EGLint, fds: *const [4]EGLint) !i32 {
    if (num_planes == 1 and fds[0] >= 0) {
        for (fds[1..]) |fd| if (fd >= 0) closeFd(fd);
        return fds[0];
    }
    for (fds) |fd| if (fd >= 0) closeFd(fd);
    log.warn("dmabuf export is not single-plane num_planes={}", .{num_planes});
    return error.EglExportUnsupportedLayout;
}

fn closeFd(fd: EGLint) void {
    if (comptime is_windows) return;
    _ = std.posix.system.close(fd);
}

test "dmabuf export keeps one plane and closes every other fd" {
    if (comptime is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const posix = std.posix;

    const isOpen = struct {
        fn f(fd: posix.fd_t) bool {
            return posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0)) != -1;
        }
    }.f;

    var p1: [2]posix.fd_t = undefined;
    var p2: [2]posix.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), posix.system.pipe(&p1));
    try testing.expectEqual(@as(c_int, 0), posix.system.pipe(&p2));

    // Multi-plane: every fd is closed and the export is rejected.
    var multi: [4]EGLint = .{ p1[0], p1[1], -1, -1 };
    try testing.expectError(
        error.EglExportUnsupportedLayout,
        takeSinglePlaneFd(2, &multi),
    );
    try testing.expect(!isOpen(p1[0]));
    try testing.expect(!isOpen(p1[1]));

    // Invalid fd: rejected without touching anything else.
    var invalid: [4]EGLint = .{ -1, -1, -1, -1 };
    try testing.expectError(
        error.EglExportUnsupportedLayout,
        takeSinglePlaneFd(1, &invalid),
    );

    // Single plane: plane 0 is returned open; stray extra fds are closed.
    var single: [4]EGLint = .{ p2[0], p2[1], -1, -1 };
    const fd = try takeSinglePlaneFd(1, &single);
    try testing.expectEqual(p2[0], fd);
    try testing.expect(isOpen(p2[0]));
    try testing.expect(!isOpen(p2[1]));
    _ = posix.system.close(p2[0]);
}
