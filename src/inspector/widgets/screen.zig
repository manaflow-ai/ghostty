const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const terminal = @import("../../terminal/main.zig");

/// Screen information inspector widget.
pub const Info = struct {
    pub const empty: Info = .{};

    /// Draw the screen info contents.
    pub fn draw(self: *Info, open: bool, data: struct {
        /// The screen that we're inspecting.
        screen: *const terminal.Screen,

        /// Which screen key we're viewing.
        key: terminal.ScreenSet.Key,

        /// Which screen is active (primary or alternate).
        active_key: terminal.ScreenSet.Key,

        /// Whether xterm modify other keys mode 2 is enabled.
        modify_other_keys_2: bool,

        /// Color palette for cursor color resolution.
        color_palette: *const terminal.color.DynamicPalette,
    }) void {
        _ = self;
        const screen = data.screen;

        // The remainder is the open state
        if (!open) return;

        // Show warning if viewing an inactive screen
        if (data.key != data.active_key) {
            cimgui.c.ImGui_TextColored(
                .{ .x = 1.0, .y = 0.8, .z = 0.0, .w = 1.0 },
                "⚠ Viewing inactive screen",
            );
            cimgui.c.ImGui_Separator();
        }

        if (cimgui.c.ImGui_CollapsingHeader(
            "Keyboard",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) keyboardTable(
            screen,
            data.modify_other_keys_2,
        );
    }
};

/// Render keyboard information with a table.
fn keyboardTable(
    screen: *const terminal.Screen,
    modify_other_keys_2: bool,
) void {
    if (!cimgui.c.ImGui_BeginTable(
        "table_keyboard",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    const kitty_flags = screen.kitty_keyboard.current();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Mode");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            const mode = if (kitty_flags.int() != 0) "kitty" else "legacy";
            cimgui.c.ImGui_Text("%s", mode.ptr);
        }
    }

    if (kitty_flags.int() != 0) {
        const Flags = @TypeOf(kitty_flags);
        inline for (@typeInfo(Flags).@"struct".fields) |field| {
            {
                const value = @field(kitty_flags, field.name);

                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    const field_name = std.fmt.comptimePrint("{s}", .{field.name});
                    cimgui.c.ImGui_Text("%s", field_name.ptr);
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%s",
                        if (value) "true".ptr else "false".ptr,
                    );
                }
            }
        }
    } else {
        {
            cimgui.c.ImGui_TableNextRow();
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Xterm modify keys");
            }
            {
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text(
                    "%s",
                    if (modify_other_keys_2) "true".ptr else "false".ptr,
                );
            }
        }
    } // keyboard mode info

}
