const cimgui = @import("dcimgui");
const terminal = @import("../terminal/main.zig");
const widgets = @import("widgets.zig");

/// Render cursor information with a table already open.
pub fn renderInTable(
    color_palette: *const terminal.color.DynamicPalette,
    cursor: *const terminal.Screen.Cursor,
) void {
    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Position (x, y)");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The current cursor position in the terminal grid (0-indexed).");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("(%d, %d)", cursor.x, cursor.y);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Style");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The visual style of the cursor (block, underline, bar, etc.).");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("%s", @tagName(cursor.cursor_style).ptr);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Hyperlink");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The active OSC8 hyperlink for newly printed characters.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            if (cursor.hyperlink) |link| {
                cimgui.c.ImGui_Text("%.*s", link.uri.len, link.uri.ptr);
            } else {
                cimgui.c.ImGui_TextDisabled("(none)");
            }
        }
    }

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Foreground Color");
    cimgui.c.ImGui_SameLine();
    widgets.helpMarker("The foreground (text) color for newly printed characters.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    switch (cursor.style.fg_color) {
        .none => cimgui.c.ImGui_Text("default"),
        .palette => |idx| {
            const rgb = color_palette.current[idx];
            cimgui.c.ImGui_Text("Palette %d", idx);
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.ImGui_ColorEdit3(
                "color_fg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },

        .rgb => |rgb| {
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.ImGui_ColorEdit3(
                "color_fg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },
    }

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Background Color");
    cimgui.c.ImGui_SameLine();
    widgets.helpMarker("The background color for newly printed characters.");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    switch (cursor.style.bg_color) {
        .none => cimgui.c.ImGui_Text("default"),
        .palette => |idx| {
            const rgb = color_palette.current[idx];
            cimgui.c.ImGui_Text("Palette %d", idx);
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.ImGui_ColorEdit3(
                "color_bg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },

        .rgb => |rgb| {
            var color: [3]f32 = .{
                @as(f32, @floatFromInt(rgb.r)) / 255,
                @as(f32, @floatFromInt(rgb.g)) / 255,
                @as(f32, @floatFromInt(rgb.b)) / 255,
            };
            _ = cimgui.c.ImGui_ColorEdit3(
                "color_bg",
                &color,
                cimgui.c.ImGuiColorEditFlags_DisplayHex |
                    cimgui.c.ImGuiColorEditFlags_NoPicker |
                    cimgui.c.ImGuiColorEditFlags_NoLabel,
            );
        },
    }

    const style_flags = .{
        .{ "bold", "Text will be rendered with bold weight." },
        .{ "italic", "Text will be rendered in italic style." },
        .{ "faint", "Text will be rendered with reduced intensity." },
        .{ "blink", "Text will blink (if supported by the renderer)." },
        .{ "inverse", "Foreground and background colors are swapped." },
        .{ "invisible", "Text will be invisible (hidden)." },
        .{ "strikethrough", "Text will have a line through it." },
    };
    inline for (style_flags) |entry| entry: {
        const style = entry[0];
        const help = entry[1];
        if (!@field(cursor.style.flags, style)) break :entry;

        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text(style.ptr);
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker(help);
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            cimgui.c.ImGui_Text("true");
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Pending Wrap");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("The 'last column flag' (LCF). If set, the next character will force a soft-wrap to the next line.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            var value: bool = cursor.pending_wrap;
            _ = cimgui.c.ImGui_Checkbox("##pending_wrap", &value);
        }
    }

    {
        cimgui.c.ImGui_TableNextRow();
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(0);
            cimgui.c.ImGui_Text("Protected");
            cimgui.c.ImGui_SameLine();
            widgets.helpMarker("If enabled, new characters will have the protected attribute set, preventing erasure by certain sequences.");
        }
        {
            _ = cimgui.c.ImGui_TableSetColumnIndex(1);
            var value: bool = cursor.protected;
            _ = cimgui.c.ImGui_Checkbox("##protected", &value);
        }
    }
}
