const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const terminal = @import("../../terminal/main.zig");
const Terminal = terminal.Terminal;

pub const Info = struct {
    terminal: *Terminal,
};

pub fn drawInfo(data: Info) void {
    if (cimgui.c.ImGui_CollapsingHeader(
        "Help",
        cimgui.c.ImGuiTreeNodeFlags_None,
    )) {
        cimgui.c.ImGui_TextWrapped(
            "This window displays the internal state of the terminal. " ++
                "The terminal state is global to this terminal. Some state " ++
                "is specific to the active screen or other subsystems. Values " ++
                "here reflect the running state and will update as the terminal " ++
                "application modifies them via escape sequences or shell integration. " ++
                "Some can be modified directly for debugging purposes.",
        );
    }

    _ = data;
}
