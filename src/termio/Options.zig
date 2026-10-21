//! The options that are used to configure a terminal IO implementation.

const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const Config = @import("../config.zig").Config;
const termio = @import("../termio.zig");

/// All size metrics for the terminal.
size: renderer.Size,

/// The full app configuration. This is only available during initialization.
/// The memory it points to is NOT stable after the init call so any values
/// in here must be copied.
full_config: *const Config,

/// The derived configuration for this termio implementation.
config: termio.Termio.DerivedConfig,

/// The surface's current runtime scheme. This is independent of whether the
/// configuration contains any theme-conditional settings.
color_scheme: @import("../config.zig").ConditionalState.Theme,

/// The backend for termio that implements where reads/writes are sourced.
backend: termio.Backend,

/// Drop replies generated while parsing terminal output. This is used by
/// mirror renderers when another terminal core owns the PTY protocol.
suppress_terminal_responses: bool = false,

/// The mailbox for the terminal. This is how messages are delivered.
/// If you're using termio.Thread this MUST be "mailbox".
mailbox: termio.Mailbox,

/// The render state. The IO implementation can modify anything here. The
/// surface thread will setup the initial "terminal" pointer but the IO impl
/// is free to change that if that is useful (i.e. doing some sort of dual
/// terminal implementation.)
renderer_state: *renderer.State,

/// The renderer thread's own wakeup handle (not a copy). This hints to the
/// renderer that a repaint should happen. A pointer because libxev's IOCP
/// `Async` (Windows) keeps its waiter inside the struct: a copy made before
/// the renderer thread starts waiting never wakes it, so PTY output did not
/// redraw a terminal there until something else (focus, resize, cursor
/// blink) woke its renderer. The eventfd and kqueue backends share a handle
/// between copies, which hid this elsewhere.
renderer_wakeup: *xev.Async,

/// The mailbox for renderer messages.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for sending the surface messages.
surface_mailbox: apprt.surface.Mailbox,

/// Optional PTY-output tee installed before the IO thread starts.
pty_tee_cb: ?termio.Termio.PtyTeeCallback = null,

/// Userdata passed to pty_tee_cb.
pty_tee_userdata: ?*anyopaque = null,

test "renderer_wakeup wakes the renderer's own Async" {
    const std = @import("std");
    // termio must hold the renderer thread's Async itself: a by-value copy
    // made before the thread waits never wakes it on the IOCP backend.
    try std.testing.expect(@typeInfo(@FieldType(@This(), "renderer_wakeup")) == .pointer);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    var wakeup = try xev.Async.init();
    defer wakeup.deinit();
    var c: xev.Completion = .{};
    var woke = false;
    wakeup.wait(&loop, &c, bool, &woke, (struct {
        fn callback(ud: ?*bool, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
            r catch return .disarm;
            ud.?.* = true;
            return .disarm;
        }
    }).callback);
    const handle: @FieldType(@This(), "renderer_wakeup") = &wakeup;
    try handle.notify();
    try loop.run(.until_done);
    try std.testing.expect(woke);
}
