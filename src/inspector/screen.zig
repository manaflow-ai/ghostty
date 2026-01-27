const std = @import("std");
const cimgui = @import("dcimgui");
const terminal = @import("../terminal/main.zig");
const inspector = @import("main.zig");
const units = @import("units.zig");

/// Window to show screen information.
pub const Window = struct {
    /// Window name/id.
    pub const name = "Screen";

    pub const FrameData = struct {
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
    };

    /// Render with custom label and close button.
    pub fn render(
        self: *Window,
        label: [:0]const u8,
        open: *bool,
        data: FrameData,
    ) void {
        defer cimgui.c.ImGui_End();
        if (!cimgui.c.ImGui_Begin(
            label,
            open,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        )) return;

        self.renderContent(data);
    }

    fn renderContent(self: *Window, data: FrameData) void {
        _ = self;
        const screen = data.screen;

        // Show warning if viewing an inactive screen
        if (data.key != data.active_key) {
            cimgui.c.ImGui_TextColored(
                .{ .x = 1.0, .y = 0.8, .z = 0.0, .w = 1.0 },
                "⚠ Viewing inactive screen",
            );
            cimgui.c.ImGui_Separator();
        }

        if (cimgui.c.ImGui_CollapsingHeader(
            "Cursor",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) {
            {
                _ = cimgui.c.ImGui_BeginTable(
                    "table_cursor",
                    2,
                    cimgui.c.ImGuiTableFlags_None,
                );
                defer cimgui.c.ImGui_EndTable();
                inspector.cursor.renderInTable(
                    data.color_palette,
                    &screen.cursor,
                );
            } // table

            cimgui.c.ImGui_TextDisabled("(Any styles not shown are not currently set)");
        } // cursor

        if (cimgui.c.ImGui_CollapsingHeader(
            "Keyboard",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) {
            {
                _ = cimgui.c.ImGui_BeginTable(
                    "table_keyboard",
                    2,
                    cimgui.c.ImGuiTableFlags_None,
                );
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
                                if (data.modify_other_keys_2) "true".ptr else "false".ptr,
                            );
                        }
                    }
                } // keyboard mode info
            } // table
        } // keyboard

        if (cimgui.c.ImGui_CollapsingHeader(
            "Kitty Graphics",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) kitty_gfx: {
            if (!screen.kitty_images.enabled()) {
                cimgui.c.ImGui_TextDisabled("(Kitty graphics are disabled)");
                break :kitty_gfx;
            }

            {
                _ = cimgui.c.ImGui_BeginTable(
                    "##kitty_graphics",
                    2,
                    cimgui.c.ImGuiTableFlags_None,
                );
                defer cimgui.c.ImGui_EndTable();

                const kitty_images = &screen.kitty_images;

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Memory Usage");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_bytes, units.toKibiBytes(kitty_images.total_bytes));
                    }
                }

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Memory Limit");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_limit, units.toKibiBytes(kitty_images.total_limit));
                    }
                }

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Image Count");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%d", kitty_images.images.count());
                    }
                }

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Placement Count");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%d", kitty_images.placements.count());
                    }
                }

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Image Loading");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%s", if (kitty_images.loading != null) "true".ptr else "false".ptr);
                    }
                }
            } // table
        } // kitty graphics

        if (cimgui.c.ImGui_CollapsingHeader(
            "Internal Terminal State",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) {
            const pages = &screen.pages;

            {
                _ = cimgui.c.ImGui_BeginTable(
                    "##terminal_state",
                    2,
                    cimgui.c.ImGuiTableFlags_None,
                );
                defer cimgui.c.ImGui_EndTable();

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Memory Usage");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.page_size, units.toKibiBytes(pages.page_size));
                    }
                }

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Memory Limit");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.maxSize(), units.toKibiBytes(pages.maxSize()));
                    }
                }

                {
                    cimgui.c.ImGui_TableNextRow();
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                        cimgui.c.ImGui_Text("Viewport Location");
                    }
                    {
                        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                        cimgui.c.ImGui_Text("%s", @tagName(pages.viewport).ptr);
                    }
                }
            } // table
            //
            if (cimgui.c.ImGui_CollapsingHeader(
                "Active Page",
                cimgui.c.ImGuiTreeNodeFlags_None,
            )) {
                inspector.page.render(&pages.pages.last.?.data);
            }
        } // terminal state
    }
};
