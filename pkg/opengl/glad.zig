const std = @import("std");
const c = @import("c.zig").c;

pub const Context = c.GladGLContext;

/// This is the current context. Set this var manually prior to calling
/// any of this package's functions. I know its nasty to have a global but
/// this makes it match OpenGL API styles where it also operates on a
/// threadlocal global.
pub threadlocal var context: Context = undefined;

/// Initialize Glad. This is guaranteed to succeed if no errors are returned.
/// The getProcAddress param is an anytype so that we can accept multiple
/// forms of the function depending on what we're interfacing with.
pub fn load(getProcAddress: anytype) !c_int {
    const GlProc = *const fn () callconv(.c) void;
    const GlfwFnValue = fn ([*:0]const u8) callconv(.c) ?GlProc;
    const GlfwFn = *const fn ([*:0]const u8) callconv(.c) ?GlProc;

    // gladLoadGLContext only fills the function table. It does not initialize
    // glad_loader_handle, which is consumed by gladLoaderUnloadGLContext.
    // Embedded surfaces can move one GL context across threads and reload this
    // thread-local value during teardown, so carrying Zig's undefined-memory
    // poison into that field would make unload attempt to close a bogus handle.
    context = std.mem.zeroes(Context);

    const res = switch (@TypeOf(getProcAddress)) {
        // glfw
        GlfwFn => c.gladLoadGLContext(&context, @ptrCast(getProcAddress)),

        // A bare function declaration needs its address taken before it can
        // be passed through C's function-pointer ABI. This is the form used
        // by the embedded renderer's callback trampoline.
        GlfwFnValue => c.gladLoadGLContext(&context, @ptrCast(&getProcAddress)),

        // null proc address means that we are just loading the globally
        // pointed gl functions
        @TypeOf(null) => c.gladLoaderLoadGLContext(&context),

        // try as-is. If this introduces a compiler error, then add a new case.
        else => c.gladLoadGLContext(&context, @ptrCast(getProcAddress)),
    };
    if (res == 0) return error.GLInitFailed;
    return res;
}

pub fn unload() void {
    c.gladLoaderUnloadGLContext(&context);
    context = undefined;
}

pub fn versionMajor(res: c_uint) c_uint {
    return c.GLAD_VERSION_MAJOR(res);
}

pub fn versionMinor(res: c_uint) c_uint {
    return c.GLAD_VERSION_MINOR(res);
}
