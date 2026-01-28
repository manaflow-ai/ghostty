const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const units = @import("../units.zig");
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
            "Cursor",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) {
            cursorTable(&screen.cursor);
            cimgui.c.ImGui_Separator();
            cursorStyle(&screen.cursor, &data.color_palette.current);
        }

        if (cimgui.c.ImGui_CollapsingHeader(
            "Keyboard",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) keyboardTable(
            screen,
            data.modify_other_keys_2,
        );

        if (cimgui.c.ImGui_CollapsingHeader(
            "Kitty Graphics",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) kittyGraphicsTable(&screen.kitty_images);

        if (cimgui.c.ImGui_CollapsingHeader(
            "Internal Terminal State",
            cimgui.c.ImGuiTreeNodeFlags_None,
        )) internalStateTable(&screen.pages);
    }
};

/// Render cursor state with a table of cursor-specific fields.
pub fn cursorTable(
    cursor: *const terminal.Screen.Cursor,
) void {
    if (!cimgui.c.ImGui_BeginTable(
        "table_cursor",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
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

/// Render cursor style information using the shared style table.
pub fn cursorStyle(cursor: *const terminal.Screen.Cursor, palette: ?*const terminal.color.Palette) void {
    widgets.style.table(cursor.style, palette);
}

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

/// Render kitty graphics information table.
pub fn kittyGraphicsTable(
    kitty_images: *const terminal.kitty.graphics.ImageStorage,
) void {
    if (!kitty_images.enabled()) {
        cimgui.c.ImGui_TextDisabled("(Kitty graphics are disabled)");
        return;
    }

    if (!cimgui.c.ImGui_BeginTable(
        "##kitty_graphics",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Usage");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_bytes, units.toKibiBytes(kitty_images.total_bytes));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Limit");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", kitty_images.total_limit, units.toKibiBytes(kitty_images.total_limit));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Image Count");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d", kitty_images.images.count());

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Placement Count");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d", kitty_images.placements.count());

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Image Loading");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%s", if (kitty_images.loading != null) "true".ptr else "false".ptr);
}

/// Render internal terminal state table.
pub fn internalStateTable(
    pages: *const terminal.PageList,
) void {
    if (!cimgui.c.ImGui_BeginTable(
        "##terminal_state",
        2,
        cimgui.c.ImGuiTableFlags_None,
    )) return;
    defer cimgui.c.ImGui_EndTable();

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Usage");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.page_size, units.toKibiBytes(pages.page_size));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Memory Limit");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%d bytes (%d KiB)", pages.maxSize(), units.toKibiBytes(pages.maxSize()));

    cimgui.c.ImGui_TableNextRow();
    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
    cimgui.c.ImGui_Text("Viewport Location");
    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
    cimgui.c.ImGui_Text("%s", @tagName(pages.viewport).ptr);
}
