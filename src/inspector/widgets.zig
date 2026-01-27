const cimgui = @import("dcimgui");

/// Draws a "(?)" disabled text marker that shows some help text
/// on hover.
pub fn helpMarker(text: [:0]const u8) void {
    cimgui.c.ImGui_TextDisabled("(?)");
    if (!cimgui.c.ImGui_BeginItemTooltip()) return;
    defer cimgui.c.ImGui_EndTooltip();

    cimgui.c.ImGui_PushTextWrapPos(cimgui.c.ImGui_GetFontSize() * 35.0);
    defer cimgui.c.ImGui_PopTextWrapPos();

    cimgui.c.ImGui_TextUnformatted(text.ptr);
}

/// Render a collapsing header that can be detached into its own window.
/// When detached, renders as a separate window with a close button.
/// When attached, renders as a collapsing header with a pop-out button.
pub fn collapsingHeaderDetachable(
    label: [:0]const u8,
    show: *bool,
    ctx: anytype,
    comptime contentFn: fn (@TypeOf(ctx)) void,
) void {
    cimgui.c.ImGui_PushID(label);
    defer cimgui.c.ImGui_PopID();

    if (show.*) {
        defer cimgui.c.ImGui_End();
        if (cimgui.c.ImGui_Begin(
            label,
            show,
            cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
        )) contentFn(ctx);
        return;
    }

    cimgui.c.ImGui_SetNextItemAllowOverlap();
    const is_open = cimgui.c.ImGui_CollapsingHeader(
        label,
        cimgui.c.ImGuiTreeNodeFlags_DefaultOpen,
    );

    // Place pop-out button inside the header bar
    const header_max = cimgui.c.ImGui_GetItemRectMax();
    const header_min = cimgui.c.ImGui_GetItemRectMin();
    const frame_height = cimgui.c.ImGui_GetFrameHeight();
    const button_size = frame_height - 4;
    const padding = 4;

    cimgui.c.ImGui_SameLine();
    cimgui.c.ImGui_SetCursorScreenPos(.{
        .x = header_max.x - button_size - padding,
        .y = header_min.y + 2,
    });
    cimgui.c.ImGui_PushStyleVarImVec2(
        cimgui.c.ImGuiStyleVar_FramePadding,
        .{ .x = 0, .y = 0 },
    );
    if (cimgui.c.ImGui_ButtonEx(
        ">>##detach",
        .{ .x = button_size, .y = button_size },
    )) {
        show.* = true;
    }
    cimgui.c.ImGui_PopStyleVar();
    if (cimgui.c.ImGui_IsItemHovered(cimgui.c.ImGuiHoveredFlags_DelayShort)) {
        cimgui.c.ImGui_SetTooltip("Pop out into separate window");
    }

    if (is_open) contentFn(ctx);
}
