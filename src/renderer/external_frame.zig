/// The external presenter either drops its borrowed frame immediately or
/// acquires a Ghostty-owned lease that must later be released by token.
pub const Disposition = enum(c_int) {
    drop = 0,
    acquire = 1,
};

/// The color space attached to the exported IOSurface.
pub const ColorSpace = enum(c_int) {
    display_p3 = 0,
};

/// One completed Metal frame offered to an external compositor.
pub const Frame = extern struct {
    iosurface: *anyopaque,
    frame_token: u64,
    host_context: u64,
    width_px: u32,
    height_px: u32,
    color_space: ColorSpace,
};

test "external Metal frame C ABI" {
    const std = @import("std");
    const lib = @import("../lib/main.zig");
    const c = @import("ghostty.h");

    try lib.checkGhosttyHEnum(
        Disposition,
        "GHOSTTY_METAL_EXTERNAL_FRAME_",
    );
    try lib.checkGhosttyHEnum(
        ColorSpace,
        "GHOSTTY_METAL_EXTERNAL_COLOR_SPACE_",
    );
    try std.testing.expectEqual(
        @sizeOf(Frame),
        @sizeOf(c.ghostty_metal_external_frame_s),
    );
    inline for (.{
        "iosurface",
        "frame_token",
        "host_context",
        "width_px",
        "height_px",
        "color_space",
    }) |field| {
        try std.testing.expectEqual(
            @offsetOf(Frame, field),
            @offsetOf(c.ghostty_metal_external_frame_s, field),
        );
    }
}
