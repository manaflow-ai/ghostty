const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const widgets = @import("../widgets.zig");
const terminal = @import("../../terminal/main.zig");
const Surface = @import("../../Surface.zig");

/// This is discovered via the hardcoded string in the ImGui demo window.
const window_imgui_demo = "Dear ImGui Demo";
const window_terminal = "Terminal";

pub const Inspector = struct {
    /// The surface being inspected.
    surface: *const Surface,

    pub fn draw(self: *Inspector) void {
        // Create our dockspace first. If we had to setup our dockspace,
        // then it is a first render.
        const dockspace_id = cimgui.c.ImGui_GetID("Main Dockspace");
        const first_render = createDockSpace(dockspace_id);

        // In debug we show the ImGui demo window so we can easily view
        // available widgets and such.
        if (comptime builtin.mode == .Debug) {
            var show: bool = true; // Always show it
            cimgui.c.ImGui_ShowDemoWindow(&show);
        }

        // Draw everything that requires the terminal state mutex.
        {
            self.surface.renderer_state.mutex.lock();
            defer self.surface.renderer_state.mutex.unlock();
            const t = self.surface.renderer_state.terminal;
            drawTerminalWindow(.{ .terminal = t });
        }

        if (first_render) {
            // On first render, setup our initial focus state. We only
            // do this on first render so that we can let the user change
            // focus afterward without it snapping back.
            cimgui.c.ImGui_SetWindowFocusStr(window_terminal);
        }
    }

    /// Create the global dock space for the inspector. A dock space
    /// is a special area where windows can be docked into. The global
    /// dock space fills the entire main viewport.
    ///
    /// Returns true if this was the first time the dock space was created.
    fn createDockSpace(dockspace_id: cimgui.c.ImGuiID) bool {
        const viewport: *cimgui.c.ImGuiViewport = cimgui.c.ImGui_GetMainViewport();

        // Initial Docking setup
        const setup = cimgui.ImGui_DockBuilderGetNode(dockspace_id) == null;
        if (setup) {
            // Register our dockspace node
            assert(cimgui.ImGui_DockBuilderAddNodeEx(
                dockspace_id,
                cimgui.ImGuiDockNodeFlagsPrivate.DockSpace,
            ) == dockspace_id);

            // Ensure it is the full size of the viewport
            cimgui.ImGui_DockBuilderSetNodeSize(
                dockspace_id,
                viewport.Size,
            );

            // We only initialize one central docking point now but
            // this is the point we'd pre-split and so on for the initial
            // layout.
            const dock_id_main: cimgui.c.ImGuiID = dockspace_id;
            cimgui.ImGui_DockBuilderDockWindow(window_terminal, dock_id_main);
            cimgui.ImGui_DockBuilderDockWindow(window_imgui_demo, dock_id_main);
            cimgui.ImGui_DockBuilderFinish(dockspace_id);
        }

        // Put the dockspace over the viewport.
        assert(cimgui.c.ImGui_DockSpaceOverViewportEx(
            dockspace_id,
            viewport,
            cimgui.c.ImGuiDockNodeFlags_PassthruCentralNode,
            null,
        ) == dockspace_id);
        return setup;
    }
};

fn drawTerminalWindow(state: struct {
    terminal: *terminal.Terminal,
}) void {
    defer cimgui.c.ImGui_End();
    if (!cimgui.c.ImGui_Begin(
        window_terminal,
        null,
        cimgui.c.ImGuiWindowFlags_NoFocusOnAppearing,
    )) return;

    widgets.terminal.drawInfo(.{
        .terminal = state.terminal,
    });
}
