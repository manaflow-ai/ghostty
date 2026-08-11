//! Optional, content-free renderer activity instrumentation for embedders.

pub const Event = enum(c_int) {
    update_frame_begin = 0,
    update_frame_end = 1,
    draw_frame_begin = 2,
    draw_frame_end = 3,
};

pub const Callback = *const fn (
    userdata: ?*anyopaque,
    event: Event,
) callconv(.c) void;

pub const Instrumentation = struct {
    callback: ?Callback = null,
    userdata: ?*anyopaque = null,

    /// Emits only the activity kind and embedder-owned identity. Terminal
    /// state and content never cross this seam.
    pub inline fn emit(self: *const Instrumentation, event: Event) void {
        const callback = self.callback orelse return;
        callback(self.userdata, event);
    }
};

test "ghostty.h renderer instrumentation event" {
    const lib = @import("../lib/main.zig");
    try lib.checkGhosttyHEnum(Event, "GHOSTTY_RENDERER_EVENT_");
}
