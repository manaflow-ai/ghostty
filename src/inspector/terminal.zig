const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const widgets = @import("widgets.zig");

/// Window to show terminal state information.
pub const Window = struct {
    /// Window name/id.
    pub const name = "Terminal";

    // Render
    pub fn render(self: *Window, t: *Terminal) void {
        _ = self;

        // Start our window. If we're collapsed we do nothing.
        defer cimgui.c.ImGui_End();
        if (!cimgui.c.ImGui_Begin(
            name,
            null,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        )) return;

        if (cimgui.c.ImGui_CollapsingHeader(
            "General",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            _ = cimgui.c.ImGui_BeginTable(
                "table_general",
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

        if (cimgui.c.ImGui_CollapsingHeader(
            "Layout",
            cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
        )) {
            _ = cimgui.c.ImGui_BeginTable(
                "table_layout",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Grid");
                    cimgui.c.ImGui_SameLine();
                    widgets.helpMarker("The size of the terminal grid in columns and rows.");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%dc x %dr",
                        t.cols,
                        t.rows,
                    );
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Pixels");
                    cimgui.c.ImGui_SameLine();
                    widgets.helpMarker("The size of the terminal grid in pixels.");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%dw x %dh",
                        t.width_px,
                        t.height_px,
                    );
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Scroll Region");
                    cimgui.c.ImGui_SameLine();
                    widgets.helpMarker("The scrolling region boundaries (top, bottom, left, right).");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_PushItemWidth(cimgui.c.ImGui_CalcTextSize("00000").x);
                    defer cimgui.c.ImGui_PopItemWidth();

                    var override = t.scrolling_region;
                    var changed = false;

                    cimgui.c.ImGui_AlignTextToFramePadding();
                    cimgui.c.ImGui_Text("T:");
                    cimgui.c.ImGui_SameLine();
                    if (cimgui.c.ImGui_InputScalar(
                        "##scroll_top",
                        cimgui.c.ImGuiDataType_U16,
                        &override.top,
                    )) {
                        override.top = @min(override.top, t.rows -| 1);
                        changed = true;
                    }

                    cimgui.c.ImGui_SameLine();
                    cimgui.c.ImGui_Text("B:");
                    cimgui.c.ImGui_SameLine();
                    if (cimgui.c.ImGui_InputScalar(
                        "##scroll_bottom",
                        cimgui.c.ImGuiDataType_U16,
                        &override.bottom,
                    )) {
                        override.bottom = @min(override.bottom, t.rows -| 1);
                        changed = true;
                    }

                    cimgui.c.ImGui_SameLine();
                    cimgui.c.ImGui_Text("L:");
                    cimgui.c.ImGui_SameLine();
                    if (cimgui.c.ImGui_InputScalar(
                        "##scroll_left",
                        cimgui.c.ImGuiDataType_U16,
                        &override.left,
                    )) {
                        override.left = @min(override.left, t.cols -| 1);
                        changed = true;
                    }

                    cimgui.c.ImGui_SameLine();
                    cimgui.c.ImGui_Text("R:");
                    cimgui.c.ImGui_SameLine();
                    if (cimgui.c.ImGui_InputScalar(
                        "##scroll_right",
                        cimgui.c.ImGuiDataType_U16,
                        &override.right,
                    )) {
                        override.right = @min(override.right, t.cols -| 1);
                        changed = true;
                    }

                    // If we modified it then update our scrolling region
                    // directly.
                    if (changed and
                        override.top < override.bottom and
                        override.left < override.right)
                    {
                        t.scrolling_region = override;
                    }
                }
            }
        } // cursor
    }
};
