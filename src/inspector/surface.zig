const cimgui = @import("dcimgui");
const input = @import("../input.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Surface = @import("../Surface.zig");

pub const Mouse = struct {
    /// Last hovered x/y
    last_xpos: f64 = 0,
    last_ypos: f64 = 0,

    // Last hovered screen point
    last_point: ?terminal.Pin = null,
};

/// Window to show surface information.
pub const Window = struct {
    /// Window name/id.
    pub const name = "Surface Info";

    pub const FrameData = struct {
        /// The surface that we're inspecting.
        surface: *Surface,

        /// Mouse state that we track in addition to normal mouse states that
        /// Ghostty always knows about.
        mouse: Mouse = .{},
    };

    /// Render
    pub fn render(self: *Window, data: FrameData) void {
        _ = self;

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
                "This window displays information about the surface (window). " ++
                    "A surface is the graphical area that displays the terminal " ++
                    "content. It includes dimensions, font sizing, and mouse state " ++
                    "information specific to this window instance.",
            );
        }

        cimgui.c.ImGui_SeparatorText("Dimensions");

        {
            _ = cimgui.c.ImGui_BeginTable(
                "table_size",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            // Screen Size
            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Screen Size");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%dpx x %dpx",
                        data.surface.size.screen.width,
                        data.surface.size.screen.height,
                    );
                }
            }

            // Grid Size
            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Grid Size");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    const grid_size = data.surface.size.grid();
                    cimgui.c.ImGui_Text(
                        "%dc x %dr",
                        grid_size.columns,
                        grid_size.rows,
                    );
                }
            }

            // Cell Size
            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Cell Size");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%dpx x %dpx",
                        data.surface.size.cell.width,
                        data.surface.size.cell.height,
                    );
                }
            }

            // Padding
            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Window Padding");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "T=%d B=%d L=%d R=%d px",
                        data.surface.size.padding.top,
                        data.surface.size.padding.bottom,
                        data.surface.size.padding.left,
                        data.surface.size.padding.right,
                    );
                }
            }
        }

        cimgui.c.ImGui_SeparatorText("Font");

        {
            _ = cimgui.c.ImGui_BeginTable(
                "table_font",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Size (Points)");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%.2f pt",
                        data.surface.font_size.points,
                    );
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Size (Pixels)");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "%.2f px",
                        data.surface.font_size.pixels(),
                    );
                }
            }
        }

        cimgui.c.ImGui_SeparatorText("Mouse");

        {
            _ = cimgui.c.ImGui_BeginTable(
                "table_mouse",
                2,
                cimgui.c.ImGuiTableFlags_None,
            );
            defer cimgui.c.ImGui_EndTable();

            const mouse = &data.surface.mouse;
            const t = data.surface.renderer_state.terminal;

            {
                const hover_point: terminal.point.Coordinate = pt: {
                    const p = data.mouse.last_point orelse break :pt .{};
                    const pt = t.screens.active.pages.pointFromPin(
                        .active,
                        p,
                    ) orelse break :pt .{};
                    break :pt pt.coord();
                };

                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Hover Grid");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "row=%d, col=%d",
                        hover_point.y,
                        hover_point.x,
                    );
                }
            }

            {
                const coord: renderer.Coordinate.Terminal = (renderer.Coordinate{
                    .surface = .{
                        .x = data.mouse.last_xpos,
                        .y = data.mouse.last_ypos,
                    },
                }).convert(.terminal, data.surface.size).terminal;

                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Hover Point");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "(%dpx, %dpx)",
                        @as(i64, @intFromFloat(coord.x)),
                        @as(i64, @intFromFloat(coord.y)),
                    );
                }
            }

            const any_click = for (mouse.click_state) |state| {
                if (state == .press) break true;
            } else false;

            click: {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Click State");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    if (!any_click) {
                        cimgui.c.ImGui_Text("none");
                        break :click;
                    }

                    for (mouse.click_state, 0..) |state, i| {
                        if (state != .press) continue;
                        const button: input.MouseButton = @enumFromInt(i);
                        cimgui.c.ImGui_SameLine();
                        cimgui.c.ImGui_Text("%s", (switch (button) {
                            .unknown => "?",
                            .left => "L",
                            .middle => "M",
                            .right => "R",
                            .four => "{4}",
                            .five => "{5}",
                            .six => "{6}",
                            .seven => "{7}",
                            .eight => "{8}",
                            .nine => "{9}",
                            .ten => "{10}",
                            .eleven => "{11}",
                        }).ptr);
                    }
                }
            }

            {
                const left_click_point: terminal.point.Coordinate = pt: {
                    const p = mouse.left_click_pin orelse break :pt .{};
                    const pt = t.screens.active.pages.pointFromPin(
                        .active,
                        p.*,
                    ) orelse break :pt .{};
                    break :pt pt.coord();
                };

                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Click Grid");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "row=%d, col=%d",
                        left_click_point.y,
                        left_click_point.x,
                    );
                }
            }

            {
                cimgui.c.ImGui_TableNextRow();
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(0);
                    cimgui.c.ImGui_Text("Click Point");
                }
                {
                    _ = cimgui.c.ImGui_TableSetColumnIndex(1);
                    cimgui.c.ImGui_Text(
                        "(%dpx, %dpx)",
                        @as(u32, @intFromFloat(mouse.left_click_xpos)),
                        @as(u32, @intFromFloat(mouse.left_click_ypos)),
                    );
                }
            }
        }
    }
};
