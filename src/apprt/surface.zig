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
const lib = @import("../lib/main.zig");

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
    /// The scrollbar is captured by the terminal stream at the same point as
    /// the OSC 7 report, before any later PTY output can mutate the viewport.
    pwd_change: struct {
        pwd: WriteReq,
        scrollbar: terminal.Scrollbar,
        screen_key: terminal.ScreenSet.Key,
        screen_generation: usize,
    },

    /// The terminal encountered a bell character.
    ring_bell,

    /// Report the progress of an action using a GUI element
    progress_report: terminal.osc.Command.ProgressReport,

    /// Read-only tmux control-mode state for embedded runtimes.
    tmux_control: TmuxControlMsg,

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
    search_selected: ?usize,

    /// Release a message that was not delivered. A failed mailbox push leaves
    /// ownership with the sender, including when the surface is shutting down.
    pub fn deinit(self: Message) void {
        switch (self) {
            .clipboard_write => |value| value.req.deinit(),
            .pwd_change => |value| value.pwd.deinit(),
            .tmux_control => |value| value.data.deinit(),
            else => {},
        }
    }

    pub const ReportTitleStyle = enum {
        csi_21_t,

        // This enum is a placeholder for future title styles.
    };

    pub const TmuxControlMsg = struct {
        event: Event,
        id: u32 = 0,
        data: WriteReq = .{ .stable = "" },

        pub const Event = enum(c_int) {
            enter,
            exit,
            windows_changed,
            pane_output,

            test "ghostty.h TmuxControlMsg.Event" {
                try lib.checkGhosttyHEnum(Event, "GHOSTTY_TMUX_");
            }
        };
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

    /// Send a message to the surface. Returns zero if full, timed out, or the
    /// surface is shutting down. On failure the caller still owns the message.
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

test "rejected surface mailbox pushes preserve payload ownership" {
    const alloc = std.testing.allocator;
    const data: []const u8 = "x" ** 1024;
    var surface: Surface = undefined;
    surface.mailbox_canceled = false;
    var queue: App.Mailbox.Queue = .{};

    // Cover both a full live mailbox and a canceled producer with capacity.
    for (0..2) |mode| {
        if (mode == 0) {
            for (0..64) |_| _ = queue.push(std.testing.io, .open_config, .instant);
        } else {
            while (queue.pop(std.testing.io) != null) {}
            queue.cancelPushes(std.testing.io, &surface.mailbox_canceled);
        }
        const timeout: App.Mailbox.Queue.Timeout = if (mode == 0) .instant else .forever;
        // Exceed inline storage so the allocator checks every owned payload.
        const messages = [_]Message{
            .{ .clipboard_write = .{
                .clipboard_type = .standard,
                .req = try Message.WriteReq.init(alloc, data),
            } },
            .{ .pwd_change = .{
                .pwd = try Message.WriteReq.init(alloc, data),
                .scrollbar = undefined,
                .screen_key = .primary,
                .screen_generation = 0,
            } },
            .{ .tmux_control = .{
                .event = .pane_output,
                .data = try Message.WriteReq.init(alloc, data),
            } },
        };
        for (messages) |message| {
            defer message.deinit();
            // Exercise the same cancelable enqueue used by App.Mailbox,
            // without requiring a platform app solely to issue its wakeup.
            try std.testing.expectEqual(@as(App.Mailbox.Queue.Size, 0), queue.pushCancelable(std.testing.io, .{
                .surface_message = .{
                    .surface = &surface,
                    .message = message,
                },
            }, timeout, &surface.mailbox_canceled));
        }
        try std.testing.expectEqual(@as(App.Mailbox.Queue.Size, if (mode == 0) 64 else 0), queue.count(std.testing.io));
    }
}

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
