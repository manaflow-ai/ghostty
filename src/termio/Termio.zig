//! Primary terminal IO ("termio") state. This maintains the terminal state,
//! pty, subprocess, etc. This is flexible enough to be used in environments
//! that don't have a pty and simply provides the input/output using raw
//! bytes.
pub const Termio = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const posix = std.posix;
const termio = @import("../termio.zig");
const StreamHandler = @import("stream_handler.zig").StreamHandler;
const terminalpkg = @import("../terminal/main.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const apprt = @import("../apprt.zig");
const internal_os = @import("../os/main.zig");
const windows = internal_os.windows;
const configpkg = @import("../config.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_exec);

const PtyTeeCallback = *const fn (
    ?*anyopaque,
    [*]const u8,
    usize,
    u64,
) callconv(.c) void;

/// Owns callback publication ordering and the userdata lifetime fence.
const PtyOutputPublication = struct {
    mutex: std.Thread.Mutex = .{},
    callback: ?PtyTeeCallback = null,
    userdata: ?*anyopaque = null,

    fn begin(self: *PtyOutputPublication) void {
        self.mutex.lock();
    }

    fn finish(
        self: *PtyOutputPublication,
        bytes: []const u8,
        start_seq: u64,
    ) void {
        defer self.mutex.unlock();
        if (self.callback) |callback| {
            callback(self.userdata, bytes.ptr, bytes.len, start_seq);
        }
    }

    fn set(
        self: *PtyOutputPublication,
        callback: ?PtyTeeCallback,
        userdata: ?*anyopaque,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.callback = callback;
        self.userdata = userdata;
    }

    /// Read a sequence value only after every older parser/callback
    /// publication has completed. Writers mutate the sequence while holding
    /// this mutex from before parsing through callback return.
    fn snapshotSequence(
        self: *PtyOutputPublication,
        sequence: *const u64,
    ) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return sequence.*;
    }

    /// Clear only the callback still owned by `expected_userdata`. Locking is
    /// both the ownership comparison and the lifetime fence: an in-flight
    /// callback holds this mutex until it returns, while a replacement setter
    /// changes userdata under the same mutex.
    fn clearIfUserdata(
        self: *PtyOutputPublication,
        expected_userdata: *anyopaque,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current_userdata = self.userdata orelse return false;
        if (current_userdata != expected_userdata or self.callback == null) {
            return false;
        }
        self.callback = null;
        self.userdata = null;
        return true;
    }
};

/// Mutex state argument for queueMessage.
pub const MutexState = enum { locked, unlocked };

/// Allocator
alloc: Allocator,

/// This is the implementation responsible for io.
backend: termio.Backend,

/// The derived configuration for this termio implementation.
config: DerivedConfig,

/// The terminal emulator internal state. This is the abstract "terminal"
/// that manages input, grid updating, etc. and is renderer-agnostic. It
/// just stores internal state about a grid.
terminal: terminalpkg.Terminal,

/// The shared render state
renderer_state: *renderer.State,

/// A handle to wake up the renderer. This hints to the renderer that
/// a repaint should happen.
renderer_wakeup: xev.Async,

/// The mailbox for notifying the renderer of things.
renderer_mailbox: *renderer.Thread.Mailbox,

/// The mailbox for communicating with the surface.
surface_mailbox: apprt.surface.Mailbox,

/// The cached size info
size: renderer.Size,

/// The mailbox implementation to use.
mailbox: termio.Mailbox,

/// cmux fork: manual IO currently needs an inline write path on iOS because
/// the writer-thread async wakeup is not reliably firing in that environment.
/// Delete when upstream supports manual backend writes without this path.
manual_linefeed_mode: std.atomic.Value(bool) = .{ .raw = false },

/// cmux fork: parser-applied PTY byte counter. Grid export uses this only as an
/// advisory visual-order watermark. It is not raw continuation coverage because
/// the grid does not serialize parser, pen, margin, or saved-screen state.
pty_output_seq: u64 = 0,

/// Serializes PTY parse transactions through callback publication. The
/// renderer-state mutex may be released temporarily by stream handlers while
/// draining a full mailbox, so it cannot by itself order concurrent callers
/// or protect the callback/userdata pair.
pty_output_publication: PtyOutputPublication = .{},

/// Protected by the renderer-state mutex. This remains true across temporary
/// unlocks inside `processOutputLocked`, preventing a visual snapshot from
/// treating an intermediate parser state as a stable synchronization point.
pty_output_in_progress: bool = false,

/// The stream parser. This parses the stream of escape codes and so on
/// from the child process and calls callbacks in the stream handler.
terminal_stream: StreamHandler.Stream,

/// Last time the cursor was reset. This is used to prevent message
/// flooding with cursor resets.
last_cursor_reset: ?std.time.Instant = null,

/// State we have for thread enter. This may be null if we don't need
/// to keep track of any state or if its already been freed.
thread_enter_state: ?*ThreadEnterState = null,

/// The state we need to keep around only until we enter the IO
/// thread. Then we can throw it all away.
const ThreadEnterState = struct {
    arena: ArenaAllocator,

    /// Initial input to send to the subprocess after starting. This
    /// memory is freed once the subprocess start is attempted, even
    /// if it fails, because Exec only starts once.
    input: configpkg.io.RepeatableReadableIO,

    pub fn create(
        alloc: Allocator,
        config: *const configpkg.Config,
    ) !?*ThreadEnterState {
        // If we have no input then we have no thread enter state
        if (config.input.list.items.len == 0) return null;

        // Create our arena allocator
        var arena = ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Allocate our ThreadEnterState
        const ptr = try arena_alloc.create(ThreadEnterState);

        // Copy the input from the config
        const input = try config.input.cloneParsed(arena_alloc);

        // Return the initialized state
        ptr.* = .{
            .arena = arena,
            .input = input,
        };
        return ptr;
    }

    pub fn destroy(self: *ThreadEnterState) void {
        self.arena.deinit();
    }

    /// Prepare the inputs for use. Allocations happen on the arena.
    pub fn prepareInput(
        self: *ThreadEnterState,
    ) (Allocator.Error || error{InputNotFound})![]const Input {
        const alloc = self.arena.allocator();

        var input = try alloc.alloc(
            Input,
            self.input.list.items.len,
        );
        for (self.input.list.items, 0..) |item, i| {
            input[i] = switch (item) {
                .raw => |v| .{ .string = try alloc.dupe(u8, v) },
                .path => |path| file: {
                    const f = std.fs.cwd().openFile(
                        path,
                        .{},
                    ) catch |err| {
                        log.warn("failed to open input file={s} err={}", .{
                            path,
                            err,
                        });
                        return error.InputNotFound;
                    };

                    break :file .{ .file = f };
                },
            };
        }

        return input;
    }

    const Input = union(enum) {
        string: []const u8,
        file: std.fs.File,
    };
};

/// The configuration for this IO that is derived from the main
/// configuration. This must be exported so that we don't need to
/// pass around Config pointers which makes memory management a pain.
pub const DerivedConfig = struct {
    arena: ArenaAllocator,

    palette: terminalpkg.color.Palette,
    image_storage_limit: usize,
    cursor_style: terminalpkg.CursorStyle,
    cursor_blink: ?bool,
    cursor_color: ?configpkg.Config.TerminalColor,
    foreground: configpkg.Config.Color,
    background: configpkg.Config.Color,
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,
    clipboard_write: configpkg.ClipboardAccess,
    enquiry_response: []const u8,
    conditional_state: configpkg.ConditionalState,

    pub fn init(
        alloc_gpa: Allocator,
        config: *const configpkg.Config,
    ) !DerivedConfig {
        var arena = ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        const palette: terminalpkg.color.Palette = palette: {
            if (config.@"palette-generate") generate: {
                if (config.palette.mask.findFirstSet() == null) {
                    // If the user didn't set any values manually, then
                    // we're using the default palette and we don't need
                    // to apply the generation code to it.
                    break :generate;
                }

                break :palette terminalpkg.color.generate256Color(config.palette.value, config.palette.mask, config.background.toTerminalRGB(), config.foreground.toTerminalRGB(), config.@"palette-harmonious");
            }

            break :palette config.palette.value;
        };

        return .{
            .palette = palette,
            .image_storage_limit = config.@"image-storage-limit",
            .cursor_style = config.@"cursor-style",
            .cursor_blink = config.@"cursor-style-blink",
            .cursor_color = config.@"cursor-color",
            .foreground = config.foreground,
            .background = config.background,
            .osc_color_report_format = config.@"osc-color-report-format",
            .clipboard_write = config.@"clipboard-write",
            .enquiry_response = try alloc.dupe(u8, config.@"enquiry-response"),
            .conditional_state = config._conditional_state,

            // This has to be last so that we copy AFTER the arena allocations
            // above happen (Zig assigns in order).
            .arena = arena,
        };
    }

    pub fn deinit(self: *DerivedConfig) void {
        self.arena.deinit();
    }
};

/// Initialize the termio state.
///
/// This will also start the child process if the termio is configured
/// to run a child process.
pub fn init(self: *Termio, alloc: Allocator, opts: termio.Options) !void {
    // The default terminal modes based on our config.
    const default_modes: terminalpkg.ModePacked = modes: {
        var modes: terminalpkg.ModePacked = .{};

        // Setup our initial grapheme cluster support if enabled. We use a
        // switch to ensure we get a compiler error if more cases are added.
        switch (opts.full_config.@"grapheme-width-method") {
            .unicode => modes.grapheme_cluster = true,
            .legacy => {},
        }

        // Set default cursor blink settings
        modes.cursor_blinking = opts.config.cursor_blink orelse true;

        break :modes modes;
    };

    // Create our terminal
    var term = try terminalpkg.Terminal.init(alloc, opts: {
        const grid_size = opts.size.grid();
        break :opts .{
            .cols = grid_size.columns,
            .rows = grid_size.rows,
            .max_scrollback = opts.full_config.@"scrollback-limit",
            .default_modes = default_modes,
            .colors = .{
                .background = .init(opts.config.background.toTerminalRGB()),
                .foreground = .init(opts.config.foreground.toTerminalRGB()),
                .cursor = cursor: {
                    const color = opts.config.cursor_color orelse break :cursor .unset;
                    const rgb = color.toTerminalRGB() orelse break :cursor .unset;
                    break :cursor .init(rgb);
                },
                .palette = .init(opts.config.palette),
            },
            .kitty_image_storage_limit = opts.config.image_storage_limit,
            .kitty_image_loading_limits = .all,
        };
    });
    errdefer term.deinit(alloc);

    // Set our default cursor style
    term.screens.active.cursor.cursor_style = opts.config.cursor_style;

    // Setup our terminal size in pixels for certain requests.
    term.width_px = term.cols * opts.size.cell.width;
    term.height_px = term.rows * opts.size.cell.height;

    // Setup our backend.
    var backend = opts.backend;
    backend.initTerminal(&term);

    // Create our stream handler. This points to memory in self so it
    // isn't safe to use until self.* is set.
    const handler: StreamHandler = .{
        .alloc = alloc,
        .termio_mailbox = &self.mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .size = &self.size,
        .terminal = &self.terminal,
        .osc_color_report_format = opts.config.osc_color_report_format,
        .clipboard_write = opts.config.clipboard_write,
        .enquiry_response = opts.config.enquiry_response,
        .default_cursor_style = opts.config.cursor_style,
        .default_cursor_blink = opts.config.cursor_blink,
    };

    const thread_enter_state = try ThreadEnterState.create(
        alloc,
        opts.full_config,
    );

    self.* = .{
        .alloc = alloc,
        .terminal = term,
        .config = opts.config,
        .renderer_state = opts.renderer_state,
        .renderer_wakeup = opts.renderer_wakeup,
        .renderer_mailbox = opts.renderer_mailbox,
        .surface_mailbox = opts.surface_mailbox,
        .size = opts.size,
        .backend = backend,
        .mailbox = opts.mailbox,
        .terminal_stream = .initAlloc(alloc, handler),
        .thread_enter_state = thread_enter_state,
    };
}

pub fn deinit(self: *Termio) void {
    self.backend.deinit();
    self.terminal.deinit(self.alloc);
    self.config.deinit();
    self.mailbox.deinit(self.alloc);

    // Clear any StreamHandler state
    self.terminal_stream.deinit();

    // Clear any initial state if we have it
    if (self.thread_enter_state) |v| v.destroy();
}

pub fn threadEnter(
    self: *Termio,
    thread: *termio.Thread,
    data: *ThreadData,
) !void {
    // Always free our thread enter state when we're done.
    defer if (self.thread_enter_state) |v| {
        v.destroy();
        self.thread_enter_state = null;
    };

    // If we have thread enter state then we're going to validate
    // and set that all up now so that we can error before we actually
    // start the command and pty.
    const inputs: ?[]const ThreadEnterState.Input = if (self.thread_enter_state) |v|
        try v.prepareInput()
    else
        null;

    data.* = .{
        .alloc = self.alloc,
        .loop = &thread.loop,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .mailbox = &self.mailbox,
        .backend = undefined, // Backend must replace this on threadEnter
    };

    // Setup our backend
    try self.backend.threadEnter(self.alloc, self, data);
    errdefer self.backend.threadExit(data);

    // If we have inputs, then queue them all up.
    for (inputs orelse &.{}) |input| switch (input) {
        .string => |v| self.queueWrite(data, v, false) catch |err| {
            log.warn("failed to queue input string err={}", .{err});
            return error.InputFailed;
        },
        .file => |f| self.queueWrite(
            data,
            f.readToEndAlloc(
                self.alloc,
                10 * 1024 * 1024, // 10 MiB max
            ) catch |err| {
                log.warn("failed to read input file err={}", .{err});
                return error.InputFailed;
            },
            false,
        ) catch |err| {
            log.warn("failed to queue input file err={}", .{err});
            return error.InputFailed;
        },
    };
}

pub fn threadExit(self: *Termio, data: *ThreadData) void {
    self.backend.threadExit(data);
}

/// Send a message to the mailbox. Depending on the mailbox type in use
/// this may process now or it may just enqueue and process later.
///
/// This will also notify the mailbox thread to process the message. If
/// you're sending a lot of messages, it may be more efficient to use
/// the mailbox directly and then call notify separately.
pub fn queueMessage(
    self: *Termio,
    msg: termio.Message,
    mutex: MutexState,
) void {
    switch (self.backend) {
        .manual => {
            self.queueMessageManual(msg);
            return;
        },
        .exec => {},
    }

    self.mailbox.send(msg, switch (mutex) {
        .locked => self.renderer_state.mutex,
        .unlocked => null,
    });
    self.mailbox.notify();
}

fn queueMessageManual(self: *Termio, msg: termio.Message) void {
    var td: ThreadData = .{
        .alloc = self.alloc,
        .loop = undefined,
        .renderer_state = self.renderer_state,
        .surface_mailbox = self.surface_mailbox,
        .backend = .{ .manual = .{} },
        .mailbox = &self.mailbox,
    };

    switch (msg) {
        .color_scheme_report => |v| self.colorSchemeReport(&td, v.force) catch |err| {
            log.warn("manual inline color_scheme_report failed err={}", .{err});
        },
        .crash => @panic("crash request, crashing intentionally"),
        .change_config => |config| {
            defer config.alloc.destroy(config.ptr);
            self.changeConfig(&td, config.ptr) catch |err| {
                log.warn("manual inline change_config failed err={}", .{err});
            };
        },
        .inspector => {},
        .resize => |v| self.resize(&td, v) catch |err| {
            log.warn("manual inline resize failed err={}", .{err});
        },
        .size_report => |v| self.sizeReport(&td, v) catch |err| {
            log.warn("manual inline size_report failed err={}", .{err});
        },
        .clear_screen => |v| self.clearScreen(&td, v.history) catch |err| {
            log.warn("manual inline clear_screen failed err={}", .{err});
        },
        .scroll_viewport => |v| self.scrollViewport(v),
        .selection_scroll => {},
        .jump_to_prompt => |v| self.jumpToPrompt(v) catch |err| {
            log.warn("manual inline jump_to_prompt failed err={}", .{err});
        },
        .start_synchronized_output => {},
        .linefeed_mode => |v| self.manual_linefeed_mode.store(v, .monotonic),
        .focused => |v| self.focusGained(&td, v) catch |err| {
            log.warn("manual inline focused failed err={}", .{err});
        },
        .write_small => |v| self.queueWriteManual(
            &td,
            v.data[0..v.len],
        ) catch |err| {
            log.warn("manual inline write_small failed err={}", .{err});
        },
        .write_stable => |v| self.queueWriteManual(&td, v) catch |err| {
            log.warn("manual inline write_stable failed err={}", .{err});
        },
        .write_alloc => |v| {
            defer v.alloc.free(v.data);
            self.queueWriteManual(&td, v.data) catch |err| {
                log.warn("manual inline write_alloc failed err={}", .{err});
            };
        },
    }

    self.renderer_wakeup.notify() catch |err| {
        log.warn("manual inline renderer wakeup failed err={}", .{err});
    };
}

fn queueWriteManual(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
) !void {
    const linefeed = self.manual_linefeed_mode.load(.monotonic);
    switch (self.backend) {
        .manual => |*manual| try manual.queueWrite(self.alloc, td, data, linefeed),
        .exec => unreachable,
    }
}

/// Queue a write directly to the pty.
///
/// If you're using termio.Thread, this must ONLY be called from the
/// mailbox thread. If you're not on the thread, use queueMessage with
/// mailbox messages instead.
///
/// If you're not using termio.Thread, this is not threadsafe.
pub inline fn queueWrite(
    self: *Termio,
    td: *ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    try self.backend.queueWrite(self.alloc, td, data, linefeed);
}

/// Update the configuration.
pub fn changeConfig(self: *Termio, td: *ThreadData, config: *DerivedConfig) !void {
    // The remainder of this function is modifying terminal state or
    // the read thread data, all of which requires holding the renderer
    // state lock.
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    // Deinit our old config. We do this in the lock because the
    // stream handler may be referencing the old config (i.e. enquiry resp)
    self.config.deinit();
    self.config = config.*;

    // Update our stream handler. The stream handler uses the same
    // renderer mutex so this is safe to do despite being executed
    // from another thread.
    self.terminal_stream.handler.changeConfig(&self.config);
    td.backend.changeConfig(&self.config);

    // Update the configuration that we know about.
    //
    // Specific things we don't update:
    //   - command, working-directory: we never restart the underlying
    //   process so we don't care or need to know about these.

    // Update the default palette.
    self.terminal.colors.palette.changeDefault(config.palette);
    self.terminal.flags.dirty.palette = true;

    // Update all our other colors
    self.terminal.colors.background.default = config.background.toTerminalRGB();
    self.terminal.colors.foreground.default = config.foreground.toTerminalRGB();
    self.terminal.colors.cursor.default = cursor: {
        const color = config.cursor_color orelse break :cursor null;
        break :cursor color.toTerminalRGB() orelse break :cursor null;
    };

    // Set the image limits
    try self.terminal.setKittyGraphicsSizeLimit(self.alloc, config.image_storage_limit);
    self.terminal.setKittyGraphicsLoadingLimits(.all);
}

/// Resize the terminal.
pub fn resize(
    self: *Termio,
    td: *ThreadData,
    size: renderer.Size,
) !void {
    self.size = size;
    const grid_size = size.grid();

    // Update the size of our pty.
    try self.backend.resize(grid_size, size.terminal());

    // Enter the critical area that we want to keep small
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // Update the size of our terminal state
        try self.terminal.resize(
            self.alloc,
            grid_size.columns,
            grid_size.rows,
        );

        // Update our pixel sizes
        self.terminal.width_px = grid_size.columns * self.size.cell.width;
        self.terminal.height_px = grid_size.rows * self.size.cell.height;

        // Disable synchronized output mode so that we show changes
        // immediately for a resize. This is allowed by the spec.
        self.terminal.modes.set(.synchronized_output, false);

        // If we have size reporting enabled we need to send a report.
        if (self.terminal.modes.get(.in_band_size_reports)) {
            try self.sizeReportLocked(td, .mode_2048);
        }
    }

    // Mail the renderer so that it can update the GPU and re-render.
    //
    // cmux iOS fork: on iOS there is no draining renderer-thread vsync loop;
    // `render_now` is the renderer mailbox's only drainer and runs on the SAME
    // serial dispatch queue that runs this resize (iOS uses the `.manual` termio
    // backend, so `Termio.resize` executes inline on that queue). A `.forever`
    // push here therefore wedges the queue permanently whenever the mailbox is
    // full: the `render_now` queued behind it can never run to drain it.
    // Invariant: nothing reachable from the iOS render serial queue may block
    // unboundedly on a resource that only `render_now` drains.
    //
    // Dropping the `.resize` message on a full mailbox is lossless on iOS: the
    // grid size was already applied inline above (and is re-asserted by
    // `applyPendingResizeIfNeeded` before each `render_now`), `drawFrame`
    // re-derives the screen pixel size from the CAMetalLayer every frame, and
    // the only renderer state this message carries (`setScreenSize` applies just
    // `size.padding`) is INVARIANT across resizes on iOS (padding balance is off,
    // so padding does not depend on surface size): a dropped resize keeps the
    // renderer's padding == the new padding. So an instant push that drops on
    // full re-derives identically on the next draw.
    // macOS keeps the proven wake+forever path (its renderer thread is a real
    // draining loop).
    if (comptime builtin.os.tag == .ios) {
        _ = self.renderer_mailbox.push(.{ .resize = size }, .{ .instant = {} });
    } else {
        _ = self.renderer_mailbox.push(.{ .resize = size }, .{ .forever = {} });
    }
    self.renderer_wakeup.notify() catch {};
}

/// Make a size report.
pub fn sizeReport(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    try self.sizeReportLocked(td, style);
}

fn sizeReportLocked(self: *Termio, td: *ThreadData, style: termio.Message.SizeReport) !void {
    const grid_size = self.size.grid();
    const report_size: terminalpkg.size_report.Size = .{
        .rows = grid_size.rows,
        .columns = grid_size.columns,
        .cell_width = self.size.cell.width,
        .cell_height = self.size.cell.height,
    };

    // 1024 bytes should be enough for size report since report
    // in columns and pixels.
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.size_report.encode(
        &writer,
        style,
        report_size,
    );

    try self.queueWrite(td, writer.buffered(), false);
}

/// Reset the synchronized output mode. This is usually called by timer
/// expiration from the termio thread.
pub fn resetSynchronizedOutput(self: *Termio) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.modes.set(.synchronized_output, false);
    self.renderer_wakeup.notify() catch {};
}

/// Clear the screen.
pub fn clearScreen(self: *Termio, td: *ThreadData, history: bool) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();

        // If we're on the alternate screen, we do not clear. Since this is an
        // emulator-level screen clear, this messes up the running programs
        // knowledge of where the cursor is and causes rendering issues. So,
        // for alt screen, we do nothing.
        if (self.terminal.screens.active_key == .alternate) return;

        // Clear our selection
        self.terminal.screens.active.clearSelection();

        // Clear our scrollback
        if (history) self.terminal.eraseDisplay(.scrollback, false);

        // If we're not at a prompt, we just delete above the cursor.
        if (!self.terminal.cursorIsAtPrompt()) {
            if (self.terminal.screens.active.cursor.y > 0) {
                self.terminal.screens.active.eraseActive(
                    self.terminal.screens.active.cursor.y - 1,
                );
            }

            // Clear all Kitty graphics state for this screen. This copies
            // Kitty's behavior when Cmd+K deletes all Kitty graphics. I
            // didn't spend time researching whether it only deletes Kitty
            // graphics that are placed above the cursor or if it deletes
            // all of them. We delete all of them for now but if this behavior
            // isn't fully correct we should fix this later.
            self.terminal.screens.active.kitty_images.delete(
                self.terminal.screens.active.alloc,
                &self.terminal,
                .{ .all = true },
            );

            return;
        }

        // At a prompt, we want to first fully clear the screen, and then after
        // send a FF (0x0C) to the shell so that it can repaint the screen.
        // Mark the current row as a not a prompt so we can properly
        // clear the full screen in the next eraseDisplay call.
        // TODO: fix this
        // self.terminal.markSemanticPrompt(.command);
        // assert(!self.terminal.cursorIsAtPrompt());
        self.terminal.eraseDisplay(.complete, false);
    }

    // If we reached here it means we're at a prompt, so we send a form-feed.
    try self.queueWrite(td, &[_]u8{0x0C}, false);
}

/// Scroll the viewport
pub fn scrollViewport(
    self: *Termio,
    scroll: terminalpkg.Terminal.ScrollViewport,
) void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();
    self.terminal.scrollViewport(scroll);
}

/// Jump the viewport to the prompt.
pub fn jumpToPrompt(self: *Termio, delta: isize) !void {
    {
        self.renderer_state.mutex.lock();
        defer self.renderer_state.mutex.unlock();
        self.terminal.screens.active.scroll(.{ .delta_prompt = delta });
    }

    try self.renderer_wakeup.notify();
}

/// Called when focus is gained or lost (when focus events are enabled)
pub fn focusGained(self: *Termio, td: *ThreadData, focused: bool) !void {
    self.renderer_state.mutex.lock();
    const focus_event = self.renderer_state.terminal.modes.get(.focus_event);
    self.renderer_state.mutex.unlock();

    // If we have focus events enabled, we send the focus event.
    if (focus_event) {
        var buf: [terminalpkg.focus.max_encode_size]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        terminalpkg.focus.encode(&writer, if (focused) .gained else .lost) catch |err| {
            log.err("error encoding focus event err={}", .{err});
            return;
        };
        try self.queueWrite(td, writer.buffered(), false);
    }

    // We always notify our backend of focus changes.
    try self.backend.focusGained(td, focused);
}

/// Process output from the pty. This is the manual API that users can
/// call with pty data but it is also called by the read thread when using
/// an exec subprocess.
pub fn processOutput(self: *Termio, buf: []const u8) void {
    // Keep parsing, sequence advancement, and callback publication in one
    // total order even when manual embedders invoke this concurrently.
    self.pty_output_publication.begin();

    // Parse and advance the advisory visual watermark as one renderer-state
    // transaction. Exporters cannot observe a watermark ahead of parser state.
    self.renderer_state.mutex.lock();
    self.pty_output_in_progress = true;
    self.processOutputLocked(buf);
    const chunk_seq = self.pty_output_seq;
    self.pty_output_seq +%= @intCast(buf.len);
    self.pty_output_in_progress = false;
    self.renderer_state.mutex.unlock();
    self.renderer_state.yieldToDemand();

    // Publish only after parser-applied state and its sequence are visible.
    // The callback runs on the read thread; the embedder owns cross-thread
    // hand-off and must copy bytes before returning.
    self.pty_output_publication.finish(buf, chunk_seq);
}

/// Atomically replace the PTY callback and its userdata. This waits for any
/// callback already in progress, so clearing the callback is a lifetime fence
/// for embedder-owned userdata.
pub fn setPtyTeeCallback(
    self: *Termio,
    cb: ?PtyTeeCallback,
    userdata: ?*anyopaque,
) void {
    self.pty_output_publication.set(cb, userdata);
}

/// Clear the installed callback only when its userdata still belongs to the
/// expected embedder lease. Returns after any matching in-flight callback has
/// completed. A stale lease cannot clear a newer replacement callback.
pub fn clearPtyTeeCallbackIfUserdata(
    self: *Termio,
    expected_userdata: *anyopaque,
) bool {
    return self.pty_output_publication.clearIfUserdata(expected_userdata);
}

/// Return the raw PTY-output watermark after any in-flight publication has
/// completed. This deliberately uses only the publication mutex: output takes
/// publication before renderer state, while render-grid reads stay under the
/// renderer-state mutex, so no reverse lock order is introduced.
pub fn ptyOutputSequence(self: *Termio) u64 {
    return self.pty_output_publication.snapshotSequence(&self.pty_output_seq);
}

/// Process output from readdata but the lock is already held.
fn processOutputLocked(self: *Termio, buf: []const u8) void {
    // Schedule a render. We can call this first because we have the lock.
    self.terminal_stream.handler.queueRender() catch unreachable;

    // Whenever a character is typed, we ensure the cursor is in the
    // non-blink state so it is rendered if visible. If we're under
    // HEAVY read load, we don't want to send a ton of these so we
    // use a timer under the covers
    if (std.time.Instant.now()) |now| cursor_reset: {
        if (self.last_cursor_reset) |last| {
            if (now.since(last) <= (500 * std.time.ns_per_ms)) {
                break :cursor_reset;
            }
        }

        self.last_cursor_reset = now;
        _ = self.renderer_mailbox.push(.{
            .reset_cursor_blink = {},
        }, .{ .instant = {} });
    } else |err| {
        log.warn("failed to get current time err={}", .{err});
    }

    // If we have an inspector, we enter SLOW MODE because we need to
    // process a byte at a time alternating between the inspector handler
    // and the termio handler. This is very slow compared to our optimizations
    // below but at least users only pay for it if they're using the inspector.
    if (self.renderer_state.inspector) |insp| {
        for (buf, 0..) |byte, i| {
            insp.recordPtyRead(
                self.alloc,
                &self.terminal,
                buf[i .. i + 1],
            ) catch |err| {
                log.err("error recording pty read in inspector err={}", .{err});
            };

            self.terminal_stream.next(byte);
        }
    } else {
        self.terminal_stream.nextSlice(buf);
    }

    // If our stream handling caused messages to be sent to the mailbox
    // thread, then we need to wake it up so that it processes them.
    if (self.terminal_stream.handler.termio_messaged) {
        self.terminal_stream.handler.termio_messaged = false;
        self.mailbox.notify();
    }
}

/// Sends a DSR response for the current color scheme to the pty.
pub fn colorSchemeReport(self: *Termio, td: *ThreadData, force: bool) !void {
    self.renderer_state.mutex.lock();
    defer self.renderer_state.mutex.unlock();

    try self.colorSchemeReportLocked(td, force);
}

pub fn colorSchemeReportLocked(self: *Termio, td: *ThreadData, force: bool) !void {
    if (!force and !self.renderer_state.terminal.modes.get(.report_color_scheme)) {
        return;
    }
    const scheme: terminalpkg.device_status.ColorScheme = switch (self.config.conditional_state.theme) {
        .light => .light,
        .dark => .dark,
    };

    var buf: [terminalpkg.device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try terminalpkg.device_status.encodeColorSchemeReport(&writer, scheme);
    try self.queueWrite(td, writer.buffered(), false);
}

/// ThreadData is the data created and stored in the termio thread
/// when the thread is started and destroyed when the thread is
/// stopped.
///
/// All of the fields in this struct should only be read/written by
/// the termio thread. As such, a lock is not necessary.
pub const ThreadData = struct {
    /// Allocator used for the event data
    alloc: Allocator,

    /// The event loop associated with this thread. This is owned by
    /// the Thread but we have a pointer so we can queue new work to it.
    loop: *xev.Loop,

    /// The shared render state
    renderer_state: *renderer.State,

    /// Mailboxes for different threads
    surface_mailbox: apprt.surface.Mailbox,

    /// Data associated with the backend implementation (i.e. pty/exec state)
    backend: termio.backend.ThreadData,
    mailbox: *termio.Mailbox,

    pub fn deinit(self: *ThreadData) void {
        self.backend.deinit(self.alloc);
        self.* = undefined;
    }
};

/// Get information about the process(es) attached to the backend. Returns
/// `null` if there was an error getting the information or the information is
/// not available on a particular platform.
pub fn getProcessInfo(self: *Termio, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    return self.backend.getProcessInfo(info);
}

const PtyPublicationTestRecorder = struct {
    bytes: [2]u8 = undefined,
    sequences: [2]u64 = undefined,
    count: usize = 0,

    fn callback(
        userdata: ?*anyopaque,
        bytes: [*]const u8,
        len: usize,
        start_seq: u64,
    ) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        std.debug.assert(len == 1);
        std.debug.assert(self.count < self.bytes.len);
        self.bytes[self.count] = bytes[0];
        self.sequences[self.count] = start_seq;
        self.count += 1;
    }
};

test "pty publication preserves concurrent A B order" {
    const Context = struct {
        publication: *PtyOutputPublication,
        byte: u8,
        sequence: u64,
        acquired: ?*std.Thread.ResetEvent = null,
        attempted: ?*std.Thread.ResetEvent = null,
        release: ?*std.Thread.ResetEvent = null,

        fn run(self: *@This()) void {
            if (self.attempted) |event| event.set();
            self.publication.begin();
            if (self.acquired) |event| event.set();
            if (self.release) |event| event.wait();
            self.publication.finish(&.{self.byte}, self.sequence);
        }
    };

    var recorder: PtyPublicationTestRecorder = .{};
    var publication: PtyOutputPublication = .{};
    publication.set(PtyPublicationTestRecorder.callback, &recorder);

    var a_acquired: std.Thread.ResetEvent = .{};
    var release_a: std.Thread.ResetEvent = .{};
    var a: Context = .{
        .publication = &publication,
        .byte = 'A',
        .sequence = 10,
        .acquired = &a_acquired,
        .release = &release_a,
    };
    var a_thread = try std.Thread.spawn(.{}, Context.run, .{&a});
    try a_acquired.timedWait(std.time.ns_per_s);

    var b_attempted: std.Thread.ResetEvent = .{};
    var b: Context = .{
        .publication = &publication,
        .byte = 'B',
        .sequence = 11,
        .attempted = &b_attempted,
    };
    var b_thread = try std.Thread.spawn(.{}, Context.run, .{&b});
    try b_attempted.timedWait(std.time.ns_per_s);

    release_a.set();
    a_thread.join();
    b_thread.join();

    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqualSlices(u8, "AB", &recorder.bytes);
    try std.testing.expectEqualSlices(u64, &.{ 10, 11 }, &recorder.sequences);
}

test "clearing pty callback waits for in flight publication" {
    const BlockingCallback = struct {
        entered: std.Thread.ResetEvent = .{},
        release: std.Thread.ResetEvent = .{},

        fn callback(
            userdata: ?*anyopaque,
            _: [*]const u8,
            _: usize,
            _: u64,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.entered.set();
            self.release.wait();
        }
    };
    const PublishContext = struct {
        publication: *PtyOutputPublication,

        fn run(self: *@This()) void {
            self.publication.begin();
            self.publication.finish("x", 0);
        }
    };
    const ClearContext = struct {
        publication: *PtyOutputPublication,
        attempted: *std.Thread.ResetEvent,
        completed: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.attempted.set();
            self.publication.set(null, null);
            self.completed.store(true, .release);
        }
    };

    var blocker: BlockingCallback = .{};
    var publication: PtyOutputPublication = .{};
    publication.set(BlockingCallback.callback, &blocker);

    var publish: PublishContext = .{ .publication = &publication };
    var publish_thread = try std.Thread.spawn(.{}, PublishContext.run, .{&publish});
    try blocker.entered.timedWait(std.time.ns_per_s);

    var clear_attempted: std.Thread.ResetEvent = .{};
    var clear_completed: std.atomic.Value(bool) = .init(false);
    var clear: ClearContext = .{
        .publication = &publication,
        .attempted = &clear_attempted,
        .completed = &clear_completed,
    };
    var clear_thread = try std.Thread.spawn(.{}, ClearContext.run, .{&clear});
    try clear_attempted.timedWait(std.time.ns_per_s);
    try std.testing.expect(!clear_completed.load(.acquire));

    blocker.release.set();
    publish_thread.join();
    clear_thread.join();
    try std.testing.expect(clear_completed.load(.acquire));
    try std.testing.expect(publication.callback == null);
    try std.testing.expect(publication.userdata == null);
}

test "pty sequence snapshot waits for callback publication" {
    const BlockingCallback = struct {
        entered: std.Thread.ResetEvent = .{},
        release: std.Thread.ResetEvent = .{},

        fn callback(
            userdata: ?*anyopaque,
            _: [*]const u8,
            _: usize,
            _: u64,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.entered.set();
            self.release.wait();
        }
    };
    const PublishContext = struct {
        publication: *PtyOutputPublication,
        sequence: *u64,

        fn run(self: *@This()) void {
            self.publication.begin();
            self.sequence.* = 5;
            self.publication.finish("bytes", 0);
        }
    };
    const SnapshotContext = struct {
        publication: *PtyOutputPublication,
        sequence: *const u64,
        attempted: *std.Thread.ResetEvent,
        completed: *std.atomic.Value(bool),
        result: *std.atomic.Value(u64),

        fn run(self: *@This()) void {
            self.attempted.set();
            const value = self.publication.snapshotSequence(self.sequence);
            self.result.store(value, .release);
            self.completed.store(true, .release);
        }
    };

    var blocker: BlockingCallback = .{};
    var publication: PtyOutputPublication = .{};
    publication.set(BlockingCallback.callback, &blocker);

    var sequence: u64 = 0;
    var publish: PublishContext = .{
        .publication = &publication,
        .sequence = &sequence,
    };
    var publish_thread = try std.Thread.spawn(.{}, PublishContext.run, .{&publish});
    try blocker.entered.timedWait(std.time.ns_per_s);

    var snapshot_attempted: std.Thread.ResetEvent = .{};
    var snapshot_completed: std.atomic.Value(bool) = .init(false);
    var snapshot_result: std.atomic.Value(u64) = .init(0);
    var snapshot: SnapshotContext = .{
        .publication = &publication,
        .sequence = &sequence,
        .attempted = &snapshot_attempted,
        .completed = &snapshot_completed,
        .result = &snapshot_result,
    };
    var snapshot_thread = try std.Thread.spawn(.{}, SnapshotContext.run, .{&snapshot});
    try snapshot_attempted.timedWait(std.time.ns_per_s);
    try std.testing.expect(!snapshot_completed.load(.acquire));

    blocker.release.set();
    publish_thread.join();
    snapshot_thread.join();
    try std.testing.expect(snapshot_completed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 5), snapshot_result.load(.acquire));
}

test "compare clearing pty callback waits for matching in flight publication" {
    const BlockingCallback = struct {
        entered: std.Thread.ResetEvent = .{},
        release: std.Thread.ResetEvent = .{},

        fn callback(
            userdata: ?*anyopaque,
            _: [*]const u8,
            _: usize,
            _: u64,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.entered.set();
            self.release.wait();
        }
    };
    const PublishContext = struct {
        publication: *PtyOutputPublication,

        fn run(self: *@This()) void {
            self.publication.begin();
            self.publication.finish("x", 0);
        }
    };
    const ClearContext = struct {
        publication: *PtyOutputPublication,
        expected_userdata: *anyopaque,
        attempted: *std.Thread.ResetEvent,
        completed: *std.atomic.Value(bool),
        cleared: *std.atomic.Value(bool),

        fn run(self: *@This()) void {
            self.attempted.set();
            const cleared = self.publication.clearIfUserdata(self.expected_userdata);
            self.cleared.store(cleared, .release);
            self.completed.store(true, .release);
        }
    };

    var blocker: BlockingCallback = .{};
    var publication: PtyOutputPublication = .{};
    publication.set(BlockingCallback.callback, &blocker);

    var publish: PublishContext = .{ .publication = &publication };
    var publish_thread = try std.Thread.spawn(.{}, PublishContext.run, .{&publish});
    try blocker.entered.timedWait(std.time.ns_per_s);

    var clear_attempted: std.Thread.ResetEvent = .{};
    var clear_completed: std.atomic.Value(bool) = .init(false);
    var did_clear: std.atomic.Value(bool) = .init(false);
    var clear: ClearContext = .{
        .publication = &publication,
        .expected_userdata = &blocker,
        .attempted = &clear_attempted,
        .completed = &clear_completed,
        .cleared = &did_clear,
    };
    var clear_thread = try std.Thread.spawn(.{}, ClearContext.run, .{&clear});
    try clear_attempted.timedWait(std.time.ns_per_s);
    try std.testing.expect(!clear_completed.load(.acquire));

    blocker.release.set();
    publish_thread.join();
    clear_thread.join();
    try std.testing.expect(clear_completed.load(.acquire));
    try std.testing.expect(did_clear.load(.acquire));
    try std.testing.expect(publication.callback == null);
    try std.testing.expect(publication.userdata == null);
}

test "stale userdata cannot clear replacement pty callback" {
    var old_recorder: PtyPublicationTestRecorder = .{};
    var replacement_recorder: PtyPublicationTestRecorder = .{};
    var publication: PtyOutputPublication = .{};
    publication.set(PtyPublicationTestRecorder.callback, &old_recorder);
    publication.set(PtyPublicationTestRecorder.callback, &replacement_recorder);

    try std.testing.expect(!publication.clearIfUserdata(&old_recorder));
    try std.testing.expect(publication.callback != null);
    try std.testing.expect(
        publication.userdata.? == @as(*anyopaque, @ptrCast(&replacement_recorder)),
    );
    try std.testing.expect(publication.clearIfUserdata(&replacement_recorder));
    try std.testing.expect(publication.callback == null);
    try std.testing.expect(publication.userdata == null);
}
