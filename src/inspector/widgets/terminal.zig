const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const terminal = @import("../../terminal/main.zig");
const Terminal = terminal.Terminal;

pub const Info = struct {
    misc_header: widgets.DetachableHeader,

    pub const empty: Info = .{
        .misc_header = .{},
    };

    const misc_header_label = "Misc";

    /// Draw the terminal info window.
    pub fn draw(
        self: *Info,
        open: bool,
        t: *Terminal,
    ) void {
        // Draw our open state if we're open.
        if (open) self.drawOpen(t);

        // Draw our detached state that draws regardless of if
        // we're open or not.
        if (self.misc_header.window(misc_header_label)) |visible| {
            defer self.misc_header.windowEnd();
            if (visible) miscTable(t);
        }
    }

    fn drawOpen(self: *Info, t: *Terminal) void {
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

        if (self.misc_header.header(misc_header_label)) miscTable(t);
    }
};

pub fn miscTable(t: *Terminal) void {
    _ = cimgui.c.ImGui_BeginTable(
        "table_misc",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Working Directory");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The current working directory reported by the shell.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (t.pwd.items.len > 0) {
                cimgui.c.ImGui_Text(
                    "%.*s",
                    t.pwd.items.len,
                    t.pwd.items.ptr,
                );
            } else {
                cimgui.c.ImGui_TextDisabled("(none)");
            }
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Focused");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Whether the terminal itself is currently focused.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            var value: bool = t.flags.focused;
            _ = cimgui.c.ImGui_Checkbox("##focused", &value);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Previous Char");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The previously printed character, used only for the REP sequence.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (t.previous_char) |c| {
                cimgui.c.ImGui_Text("U+%04X", @as(u32, c));
            } else {
                cimgui.c.ImGui_TextDisabled("(none)");
            }
        }
    }
}
