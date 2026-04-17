const std = @import("std");
const Allocator = std.mem.Allocator;

const internal_os = @import("../os/main.zig");
const apprt = @import("../apprt.zig");
pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Always return false as there is no apprt to communicate with.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        return false;
    }
};
pub const Surface = struct {
    pub fn getContentScale(_: *const Surface) !apprt.ContentScale {
        return .{ .x = 1, .y = 1 };
    }

    pub fn supportsClipboard(_: *const Surface, _: apprt.Clipboard) bool {
        return false;
    }

    pub fn setClipboard(
        _: *const Surface,
        _: apprt.Clipboard,
        _: []const apprt.ClipboardContent,
        _: bool,
    ) !void {}
};
