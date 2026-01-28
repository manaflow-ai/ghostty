const std = @import("std");
const cimgui = @import("dcimgui");
const terminal = @import("../terminal/main.zig");
const inspector = @import("main.zig");
const style = @import("widgets/style.zig");
const units = @import("units.zig");
const widgets = @import("widgets.zig");

/// Window to show screen information.
pub const Window = struct {
    /// Window name/id.
    pub const name = "Screen";

    /// Grid position inputs for cell inspection.
    grid_pos_x: c_int = 0,
    grid_pos_y: c_int = 0,

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
            cursorTable(
                &screen.cursor,
                &data.color_palette.current,
            );
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
            "Grid",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) {
            self.renderGrid(data);
        } // grid

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

    /// Render the grid section.
    fn renderGrid(self: *Window, data: FrameData) void {
        const screen = data.screen;
        const pages = &screen.pages;

        // Clamp values to valid range
        const max_x: c_int = @intCast(pages.cols -| 1);
        const max_y: c_int = @intCast(pages.rows -| 1);
        self.grid_pos_x = std.math.clamp(self.grid_pos_x, 0, max_x);
        self.grid_pos_y = std.math.clamp(self.grid_pos_y, 0, max_y);

        // Position inputs - calculate width to split available space evenly
        const imgui_style = cimgui.c.ImGui_GetStyle();
        const avail_width = cimgui.c.ImGui_GetContentRegionAvail().x;
        const item_spacing = imgui_style.*.ItemSpacing.x;
        const label_width = cimgui.c.ImGui_CalcTextSize("x").x + imgui_style.*.ItemInnerSpacing.x;
        const item_width = (avail_width - item_spacing - label_width * 2.0) / 2.0;

        cimgui.c.ImGui_PushItemWidth(item_width);
        _ = cimgui.c.ImGui_DragIntEx("x", &self.grid_pos_x, 1.0, 0, max_x, "%d", cimgui.c.ImGuiSliderFlags_None);
        cimgui.c.ImGui_SameLine();
        _ = cimgui.c.ImGui_DragIntEx("y", &self.grid_pos_y, 1.0, 0, max_y, "%d", cimgui.c.ImGuiSliderFlags_None);
        cimgui.c.ImGui_PopItemWidth();

        cimgui.c.ImGui_Separator();

        const pin = pages.pin(.{ .viewport = .{
            .x = @intCast(self.grid_pos_x),
            .y = @intCast(self.grid_pos_y),
        } }) orelse {
            cimgui.c.ImGui_TextColored(
                .{ .x = 1.0, .y = 0.4, .z = 0.4, .w = 1.0 },
                "Invalid position",
            );
            return;
        };

        const row_and_cell = pin.rowAndCell();
        const cell = row_and_cell.cell;
        const st = pin.style(cell);

        {
            _ = cimgui.c.ImGui_BeginTable(
                "##grid_cell_table",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            // Codepoint
            {
                cimgui.c.ImGui_TableNextRow();
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Codepoint");
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                const cp = cell.codepoint();
                if (cp == 0) {
                    cimgui.c.ImGui_Text("(empty)");
                } else {
                    cimgui.c.ImGui_Text("U+%X", @as(c_uint, cp));
                }
            }

            // Grapheme extras
            if (cell.hasGrapheme()) {
                if (pin.grapheme(cell)) |cps| {
                    cimgui.c.ImGui_TableNextRow();
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Grapheme");
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    for (cps) |cp| {
                        cimgui.c.ImGui_Text("U+%X", @as(c_uint, cp));
                    }
                }
            }

            // Width property
            {
                cimgui.c.ImGui_TableNextRow();
                _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                cimgui.c.ImGui_Text("Width");
                _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                cimgui.c.ImGui_Text("%s", @tagName(cell.wide).ptr);
            }
        }

        cimgui.c.ImGui_Separator();
        style.table(st, &data.color_palette.current);
    }
};

pub fn cursorTable(
    cursor: *const terminal.Screen.Cursor,
    palette: ?*const terminal.color.Palette,
) void {
    {
        _ = cimgui.c.ImGui_BeginTable(
            "table_cursor",
            2,
            cimgui.c.ImGuiTableFlags_None,
        );
        defer cimgui.c.ImGui_EndTable();

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Position (x, y)");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("The current cursor position in the terminal grid (0-indexed).");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        cimgui.c.ImGui_Text("(%d, %d)", cursor.x, cursor.y);

        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("Hyperlink");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("The active OSC8 hyperlink for newly printed characters.");
        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        if (cursor.hyperlink) |link| {
            cimgui.c.ImGui_Text("%.*s", link.uri.len, link.uri.ptr);
        } else {
            cimgui.c.ImGui_TextDisabled("(none)");
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Pending Wrap");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The 'last column flag' (LCF). If set, the next character will force a soft-wrap to the next line.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            var value: bool = cursor.pending_wrap;
            _ = cimgui.c.ImGui_Checkbox("##pending_wrap", &value);
        }

        {
            cimgui.c.ImGui_TableNextRow();
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Protected");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("If enabled, new characters will have the protected attribute set, preventing erasure by certain sequences.");
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            var value: bool = cursor.protected;
            _ = cimgui.c.ImGui_Checkbox("##protected", &value);
        }
    }

    cimgui.c.ImGui_Separator();

    style.table(cursor.style, palette);
}
