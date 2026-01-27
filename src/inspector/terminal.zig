const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const terminal = @import("../terminal/main.zig");
const Terminal = terminal.Terminal;
const widgets = @import("widgets.zig");
const modes = terminal.modes;

/// Context for our detachable collapsing headers.
const RenderContext = struct {
    window: *Window,
    terminal: *Terminal,
};

/// Window to show terminal state information.
pub const Window = struct {
    /// Window name/id.
    pub const name = "Terminal";

    /// Whether the palette window is open.
    show_palette: bool = false,

    /// Whether sections are shown in their own windows.
    show_misc_window: bool = false,
    show_layout_window: bool = false,
    show_mouse_window: bool = false,
    show_color_window: bool = false,
    show_modes_window: bool = false,

    // Render
    pub fn render(self: *Window, t: *Terminal) void {

        // Start our window. If we're collapsed we do nothing.
        defer cimgui.c.ImGui_End();
        if (!cimgui.c.ImGui_Begin(
            name,
            null,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        )) return;

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

        const ctx: RenderContext = .{ .window = self, .terminal = t };
        widgets.collapsingHeaderDetachable(
            "Misc",
            &self.show_misc_window,
            ctx,
            renderMiscContent,
        );
        widgets.collapsingHeaderDetachable(
            "Layout",
            &self.show_layout_window,
            ctx,
            renderLayoutContent,
        );
        widgets.collapsingHeaderDetachable(
            "Mouse",
            &self.show_mouse_window,
            ctx,
            renderMouseContent,
        );
        widgets.collapsingHeaderDetachable(
            "Color",
            &self.show_color_window,
            ctx,
            renderColorContent,
        );
        widgets.collapsingHeaderDetachable(
            "Modes",
            &self.show_modes_window,
            ctx,
            renderModesContent,
        );

        if (self.show_palette) {
            defer cimgui.c.ImGui_End();
            if (cimgui.c.ImGui_Begin(
                "256-Color Palette",
                &self.show_palette,
                cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
            )) {
                palette("palette", &t.colors.palette.current);
            }
        }
    }
};

fn renderMiscContent(ctx: RenderContext) void {
    const t = ctx.terminal;
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

fn renderLayoutContent(ctx: RenderContext) void {
    const t = ctx.terminal;
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

            if (changed and
                override.top < override.bottom and
                override.left < override.right)
            {
                t.scrolling_region = override;
            }
        }
    }
}

fn renderMouseContent(ctx: RenderContext) void {
    const t = ctx.terminal;
    _ = cimgui.c.ImGui_BeginTable(
        "table_mouse",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Event Mode");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The mouse event reporting mode set by the application.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(t.flags.mouse_event).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Format");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The mouse event encoding format.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(t.flags.mouse_format).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Shape");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The current mouse cursor shape set by the application.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(t.mouse_shape).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Shift Capture");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("XTSHIFTESCAPE state for capturing shift in mouse protocol.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (t.flags.mouse_shift_capture == .null) {
                cimgui.c.ImGui_TextDisabled("(unset)");
            } else {
                cimgui.c.ImGui_Text("%s", @tagName(t.flags.mouse_shift_capture).ptr);
            }
        }
    }
}

fn renderColorContent(ctx: RenderContext) void {
    const t = ctx.terminal;
    cimgui.c.ImGui_TextWrapped(
        "Color state for the terminal. Note these colors only apply " ++
            "to the palette and unstyled colors. Many modern terminal " ++
            "applications use direct RGB colors which are not reflected here.",
    );
    cimgui.c.ImGui_Separator();

    _ = cimgui.c.ImGui_BeginTable(
        "table_color",
        2,
        cimgui.c.ImGuiTableFlags_None,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Background");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Unstyled cell background color.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            _ = dynamicRGB(
                "bg_color",
                &t.colors.background,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Foreground");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Unstyled cell foreground color.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            _ = dynamicRGB(
                "fg_color",
                &t.colors.foreground,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Cursor");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Cursor coloring set by escape sequences.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            _ = dynamicRGB(
                "cursor_color",
                &t.colors.cursor,
            );
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Palette");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The 256-color palette.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (cimgui.c.ImGui_Button("View")) {
                ctx.window.show_palette = true;
            }
        }
    }
}

/// Render a DynamicRGB color.
///
/// Note: this currently can't be modified but we plan to allow that
/// and return a boolean letting you know if anything was modified.
fn dynamicRGB(
    label: [:0]const u8,
    rgb: *terminal.color.DynamicRGB,
) bool {
    _ = cimgui.c.ImGui_BeginTable(
        label,
        if (rgb.override != null) 2 else 1,
        cimgui.c.ImGuiTableFlags_SizingFixedFit,
    );
    defer cimgui.c.ImGui_EndTable();

    if (rgb.override != null) cimgui.c.ImGui_TableSetupColumn(
        "##label",
        cimgui.c.ImGuiTableColumnFlags_WidthFixed,
    );
    cimgui.c.ImGui_TableSetupColumn(
        "##value",
        cimgui.c.ImGuiTableColumnFlags_WidthStretch,
    );

    if (rgb.override) |c| {
        cimgui.c.ImGui_TableNextRow();
        _ = cimgui.c.ImGui_TableSetColumnIndex(0);
        cimgui.c.ImGui_Text("override:");
        cimgui.c.ImGui_SameLine();
        widgets.helpMarker("Overridden color set by escape sequences.");

        _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        var col = [3]f32{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
        };
        _ = cimgui.c.ImGui_ColorEdit3(
            "##override",
            &col,
            cimgui.c.ImGuiColorEditFlags_None,
        );
    }

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    if (rgb.default) |c| {
        if (rgb.override != null) {
            cimgui.c.ImGui_Text("default:");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("Default color from configuration.");

            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
        }

        var col = [3]f32{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
        };
        _ = cimgui.c.ImGui_ColorEdit3(
            "##default",
            &col,
            cimgui.c.ImGuiColorEditFlags_None,
        );
    } else {
        cimgui.c.ImGui_TextDisabled("(unset)");
    }

    return false;
}

/// Render a color palette as a 16x16 grid of color buttons.
fn palette(
    label: [:0]const u8,
    pal: *const terminal.color.Palette,
) void {
    cimgui.c.ImGui_PushID(label);
    defer cimgui.c.ImGui_PopID();

    for (0..16) |row| {
        for (0..16) |col| {
            const idx = row * 16 + col;
            const rgb = pal[idx];
            var col_arr = [3]f32{
                @as(f32, @floatFromInt(rgb.r)) / 255.0,
                @as(f32, @floatFromInt(rgb.g)) / 255.0,
                @as(f32, @floatFromInt(rgb.b)) / 255.0,
            };

            if (col > 0) cimgui.c.ImGui_SameLine();

            cimgui.c.ImGui_PushIDInt(@intCast(idx));
            _ = cimgui.c.ImGui_ColorEdit3(
                "##color",
                &col_arr,
                cimgui.c.ImGuiColorEditFlags_NoInputs,
            );
            if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
                cimgui.c.ImGui_SetTooltip(
                    "%d: #%02X%02X%02X",
                    idx,
                    rgb.r,
                    rgb.g,
                    rgb.b,
                );
            }
            cimgui.c.ImGui_PopID();
        }
    }
}

fn renderModesContent(ctx: RenderContext) void {
    const t = ctx.terminal;

    _ = cimgui.c.ImGui_BeginTable(
        "table_modes",
        3,
        cimgui.c.ImGuiTableFlags_SizingFixedFit |
            cimgui.c.ImGuiTableFlags_RowBg,
    );
    defer cimgui.c.ImGui_EndTable();

    {
        cimgui.c.ImGui_TableSetupColumn("", cimgui.c.ImGuiTableColumnFlags_NoResize);
        cimgui.c.ImGui_TableSetupColumn("Number", cimgui.c.ImGuiTableColumnFlags_PreferSortAscending);
        cimgui.c.ImGui_TableSetupColumn("Name", cimgui.c.ImGuiTableColumnFlags_WidthStretch);
        cimgui.c.ImGui_TableHeadersRow();
    }

    inline for (@typeInfo(terminal.Mode).@"enum".fields) |field| {
        @setEvalBranchQuota(6000);
        const tag: modes.ModeTag = @bitCast(@as(modes.ModeTag.Backing, field.value));

        cimgui.c.ImGui_TableNextRow();
        cimgui.c.ImGui_PushIDInt(@intCast(field.value));
        defer cimgui.c.ImGui_PopID();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            var value: bool = t.modes.get(@field(terminal.Mode, field.name));
            _ = cimgui.c.ImGui_Checkbox("##checkbox", &value);
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text(
                "%s%d",
                if (tag.ansi) "" else "?",
                @as(u32, @intCast(tag.value)),
            );
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(2);
            const name = std.fmt.comptimePrint("{s}", .{field.name});
            cimgui.c.ImGui_Text("%s", name.ptr);
        }
    }
}
