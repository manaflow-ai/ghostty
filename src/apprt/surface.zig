const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const App = @import("../App.zig");
const Surface = @import("../Surface.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const Config = @import("../config.zig").Config;
const MessageData = @import("../datastruct/main.zig").MessageData;

/// The message types that can be sent to a single surface.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the max size
    /// we want this union to be.
    pub const WriteReq = MessageData(u8, 255);

    /// Set the title of the surface.
    /// TODO: we should change this to a "WriteReq" style structure in
    /// the termio message so that we can more efficiently send strings
    /// of any length
    set_title: [256]u8,

    /// Report the window title back to the terminal
    report_title: ReportTitleStyle,

    /// Set the mouse shape.
    set_mouse_shape: terminal.MouseShape,

    /// Read the clipboard and write to the pty.
    clipboard_read: apprt.Clipboard,

    /// Write the clipboard contents.
    clipboard_write: struct {
        clipboard_type: apprt.Clipboard,
        req: WriteReq,
    },

    /// Change the configuration to the given configuration. The pointer is
    /// not valid after receiving this message so any config must be used
    /// and derived immediately.
    change_config: *const Config,

    /// Close the surface. This will only close the current surface that
    /// receives this, not the full application.
    close: void,

    /// The child process running in the surface has exited. This may trigger
    /// a surface close, it may not. Additional details about the child
    /// command are given in the `ChildExited` struct.
    child_exited: ChildExited,

    /// Show a desktop notification.
    desktop_notification: struct {
        /// Desktop notification title.
        title: [63:0]u8,

        /// Desktop notification body.
        body: [255:0]u8,
    },

    /// Health status change for the renderer.
    renderer_health: renderer.Health,

    /// Tell the surface to present itself to the user. This may require raising
    /// a window and switching tabs.
    present_surface: void,

    /// Notifies the surface that password input has started within
    /// the terminal. This should always be followed by a false value
    /// unless the surface exits.
    password_input: bool,

    /// A terminal color was changed using OSC sequences.
    color_change: terminal.osc.color.ColoredTarget,

    /// Notifies the surface that a tick of the timer that is timing
    /// out selection scrolling has occurred. "selection scrolling"
    /// is when the user has clicked and dragged the mouse outside
    /// the viewport of the terminal and the terminal is scrolling
    /// the viewport to follow the mouse cursor.
    selection_scroll_tick: bool,

    /// The terminal has reported a change in the working directory.
    pwd_change: WriteReq,

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// A command has started in the shell, start a timer.
    start_command,

    /// A command has finished in the shell, stop the timer and send out
    /// notifications as appropriate. The optional u8 is the exit code
    /// of the command.
    stop_command: ?u8,

    /// The scrollbar state changed for the surface.
    scrollbar: terminal.Scrollbar,

    /// Search progress update
    search_total: ?usize,

    /// Selected search index change
    search_selected: SearchSelected,

    pub const SearchSelected = struct {
        pub const ViewportPosition = terminal.Screen.ViewportCell;

        /// The selected match index, or null when the selection is cleared.
        idx: ?usize,
        /// Source screen for the selected match coordinates.
        screen: terminal.ScreenSet.Key = .primary,
        /// Allocator owning the cloned highlight payload until the message is handled.
        alloc: ?Allocator = null,
        /// Selected match highlight used to recompute viewport-relative
        /// coordinates at handle time.
        highlight: ?terminal.highlight.Flattened = null,

        pub fn initOwned(
            alloc: Allocator,
            sel: terminal.search.Thread.Event.SelectedMatch,
        ) !SearchSelected {
            return .{
                .idx = sel.idx,
                .screen = sel.screen,
                .alloc = alloc,
                .highlight = try sel.highlight.clone(alloc),
            };
        }

        pub fn deinit(self: *SearchSelected) void {
            if (self.highlight) |*highlight| {
                highlight.deinit(self.alloc.?);
                self.highlight = null;
            }
            self.alloc = null;
        }

        pub fn actionValue(
            self: SearchSelected,
            screens: *const terminal.ScreenSet,
        ) apprt.action.SearchSelected {
            var action: apprt.action.SearchSelected = .{
                .selected = self.idx,
            };
            const pos = self.viewportPosition(screens) orelse return action;
            action.has_position = true;
            action.start_x = pos.x;
            action.start_y = pos.y;
            return action;
        }

        fn viewportPosition(
            self: SearchSelected,
            screens: *const terminal.ScreenSet,
        ) ?ViewportPosition {
            if (screens.active_key != self.screen) return null;

            const screen = screens.get(self.screen) orelse return null;
            const highlight = self.highlight orelse return null;
            return viewportPositionForHighlight(screen, highlight);
        }

        pub fn viewportPositionForHighlight(
            screen: *const terminal.Screen,
            highlight: terminal.highlight.Flattened,
        ) ?ViewportPosition {
            const chunks = highlight.chunks.slice();
            const nodes = chunks.items(.node);
            const serials = chunks.items(.serial);

            // Position payloads represent the whole match. If any chunk went stale,
            // fail closed rather than reporting a coordinate from a surviving tail.
            for (0..chunks.len) |chunk_idx| {
                if (nodes[chunk_idx].serial != serials[chunk_idx]) return null;
            }

            const starts = chunks.items(.start);
            const ends = chunks.items(.end);

            // Search selection visibility is determined by any overlapping chunk, so
            // report the first visible cell in highlight order rather than startPin().
            for (0..chunks.len) |chunk_idx| {
                var row = starts[chunk_idx];
                while (row < ends[chunk_idx]) : (row += 1) {
                    const x: terminal.size.CellCountInt = if (chunk_idx == 0 and row == starts[chunk_idx])
                        highlight.top_x
                    else
                        0;
                    const pin: terminal.Pin = .{
                        .node = nodes[chunk_idx],
                        .x = x,
                        .y = row,
                    };
                    return screen.viewportCellForPin(pin) orelse continue;
                }
            }

            return null;
        }
    };

    pub fn deinit(self: *Message) void {
        switch (self.*) {
            .search_selected => |*v| v.deinit(),
            else => {},
        }
    }

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const ChildExited = extern struct {
        exit_code: u32,
        runtime_ms: u64,

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk,
            => @import("gobject").ext.defineBoxed(
                ChildExited,
                .{ .name = "GhosttyApprtChildExited" },
            ),

            .none => void,
        };
    };
};

/// A surface mailbox.
pub const Mailbox = struct {
    surface: *Surface,
    app: App.Mailbox,

    /// Send a message to the surface.
    pub fn push(
        self: Mailbox,
        msg: Message,
        timeout: App.Mailbox.Queue.Timeout,
    ) App.Mailbox.Queue.Size {
        // Surface message sending is actually implemented on the app
        // thread, so we have to rewrap the message with our surface
        // pointer and send it to the app thread.
        return self.app.push(.{
            .surface_message = .{
                .surface = self.surface,
                .message = msg,
            },
        }, timeout);
    }
};

/// Context for new surface creation to determine inheritance behavior
pub const NewSurfaceContext = enum(c_int) {
    window = 0,
    tab = 1,
    split = 2,
};

pub fn shouldInheritWorkingDirectory(context: NewSurfaceContext, config: *const Config) bool {
    return switch (context) {
        .window => config.@"window-inherit-working-directory",
        .tab => config.@"tab-inherit-working-directory",
        .split => config.@"split-inherit-working-directory",
    };
}

/// Returns a new config for a surface for the given app that should be
/// used for any new surfaces. The resulting config should be deinitialized
/// after the surface is initialized.
pub fn newConfig(
    app: *const App,
    config: *const Config,
    context: NewSurfaceContext,
) Allocator.Error!Config {
    // Create a shallow clone
    var copy = config.shallowClone(app.alloc);

    // Our allocator is our config's arena
    const alloc = copy._arena.?.allocator();

    // Get our previously focused surface for some inherited values.
    const prev = app.focusedSurface();
    if (prev) |p| {
        if (shouldInheritWorkingDirectory(context, config)) {
            if (try p.pwd(alloc)) |pwd| {
                copy.@"working-directory" = .{ .path = pwd };
            }
        }
    }

    return copy;
}

test "surface message deinit releases search-selected highlight" {
    const testing = std.testing;

    var highlight: terminal.highlight.Flattened = .empty;
    try highlight.chunks.append(testing.allocator, .{
        .node = @ptrFromInt(0x1000),
        .serial = 1,
        .start = 0,
        .end = 1,
    });

    var msg: Message = .{ .search_selected = .{
        .idx = 0,
        .screen = .primary,
        .alloc = testing.allocator,
        .highlight = highlight,
    } };
    msg.deinit();
}
