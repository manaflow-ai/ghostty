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
