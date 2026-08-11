//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The renderer is closely tied to the windowing system which usually
//! has to prepare the window for the given renderer using system-specific
//! APIs. The renderers in this package assume that the renderer is already
//! setup (OpenGL has a context, Vulkan has a surface, etc.)

const build_config = @import("build_config.zig");

const cursor = @import("renderer/cursor.zig");
const instrumentation = @import("renderer/instrumentation.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const shadertoy = @import("renderer/shadertoy.zig");
pub const Backend = @import("renderer/backend.zig").Backend;
pub const GenericRenderer = @import("renderer/generic.zig").Renderer;
pub const Metal = @import("renderer/Metal.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const WebGL = @import("renderer/WebGL.zig");
pub const Options = @import("renderer/Options.zig");
pub const Overlay = @import("renderer/Overlay.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const CursorStyle = cursor.Style;
pub const Instrumentation = instrumentation.Instrumentation;
pub const InstrumentationCallback = instrumentation.Callback;
pub const InstrumentationEvent = instrumentation.Event;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;
pub const lib = @import("lib/main.zig");

/// Completion attached to one forced embedder render. Graphics backends that
/// support it invoke the callback only after the exact frame is presented to
/// the platform layer.
pub const FramePresentation = struct {
    callback: *const fn (?*anyopaque, u64) callconv(.c) void,
    userdata: ?*anyopaque,
    token: u64,
    delivery_gate: ?*const fn (?*anyopaque) callconv(.c) void = null,
    delivery_gate_userdata: ?*anyopaque = null,

    /// Deliver only after the backend-specific gate confirms the renderer has
    /// left its draw critical section.
    pub fn deliver(self: FramePresentation) void {
        if (self.delivery_gate) |gate| gate(self.delivery_gate_userdata);
        self.callback(self.userdata, self.token);
    }
};

test "frame presentation waits for its delivery gate" {
    const testing = @import("std").testing;
    const TestState = struct {
        events: [2]u8 = @splat(0),
        len: usize = 0,

        fn append(self: *@This(), event: u8) void {
            self.events[self.len] = event;
            self.len += 1;
        }

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(1);
        }

        fn callback(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(2);
        }
    };

    var state: TestState = .{};
    const presentation: FramePresentation = .{
        .callback = &TestState.callback,
        .userdata = &state,
        .token = 42,
        .delivery_gate = &TestState.gate,
        .delivery_gate_userdata = &state,
    };
    presentation.deliver();
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, state.events[0..state.len]);
}

test "forced draw transfers synchronous presentation to its caller" {
    const testing = @import("std").testing;
    const draw_fn = @typeInfo(@TypeOf(Renderer.drawFrameWithPresentation)).@"fn";
    const result = draw_fn.return_type.?;
    const payload = @typeInfo(result).error_union.payload;
    try testing.expect(payload == ?FramePresentation);
}

/// The implementation to use for the renderer. This is comptime chosen
/// so that every build has exactly one renderer implementation.
pub const Renderer = switch (build_config.renderer) {
    .metal => GenericRenderer(Metal),
    .opengl => GenericRenderer(OpenGL),
    .webgl => WebGL,
};

/// The health status of a renderer. These must be shared across all
/// renderers even if some states aren't reachable so that our API users
/// can use the same enum for all renderers.
pub const Health = enum(c_int) {
    healthy,
    unhealthy,

    test "ghostty.h Health" {
        try lib.checkGhosttyHEnum(Health, "GHOSTTY_RENDERER_HEALTH_");
    }
};

test {
    // Our comptime-chosen renderer
    _ = Renderer;
    // Backend completion contracts must remain covered even when the build's
    // selected renderer is Metal.
    _ = OpenGL.Frame;

    _ = cursor;
    _ = instrumentation;
    _ = message;
    _ = shadertoy;
    _ = size;
    _ = Thread;
    _ = State;
}
