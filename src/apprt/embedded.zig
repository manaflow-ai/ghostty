//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const terminal_style = @import("../terminal/style.zig");
const termio = @import("../termio.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const String = @import("../main_c.zig").String;

const log = std.log.scoped(.embedded_window);

pub const resourcesDir = internal_os.resourcesDir;

pub const App = struct {
    /// Because we only expect the embedding API to be used in embedded
    /// environments, the options are extern so that we can expose it
    /// directly to a C callconv and not pay for any translation costs.
    ///
    /// C type: ghostty_runtime_config_s
    pub const Options = extern struct {
        /// These are just aliases to make the function signatures below
        /// more obvious what values will be sent.
        const AppUD = ?*anyopaque;
        const SurfaceUD = ?*anyopaque;

        /// Userdata that is passed to all the callbacks.
        userdata: AppUD = null,

        /// True if the selection clipboard is supported.
        supports_selection_clipboard: bool = false,

        /// Callback called to wakeup the event loop. This should trigger
        /// a full tick of the app loop.
        wakeup: *const fn (AppUD) callconv(.c) void,

        /// Callback called to handle an action.
        action: *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool,

        /// Read the clipboard value. Returns true if the clipboard request
        /// was started and complete_clipboard_request may be called with the
        /// given state pointer. Returns false if the clipboard request couldn't
        /// be started (such as when no text is available for a paste request).
        read_clipboard: *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) bool,

        /// This may be called after a read clipboard call to request
        /// confirmation that the clipboard value is safe to read. The embedder
        /// must call complete_clipboard_request with the given request.
        confirm_read_clipboard: *const fn (
            SurfaceUD,
            [*:0]const u8,
            *apprt.ClipboardRequest,
            apprt.ClipboardRequestType,
        ) callconv(.c) void,

        /// Write the clipboard value.
        write_clipboard: *const fn (
            SurfaceUD,
            c_int,
            [*]const CAPI.ClipboardContent,
            usize,
            bool,
        ) callconv(.c) void,

        /// Close the current surface given by this function.
        close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,

        /// Report read-only tmux control-mode state for the surface.
        tmux_control: ?*const fn (
            SurfaceUD,
            apprt.surface.Message.TmuxControlMsg.Event,
            u32,
            [*]const u8,
            usize,
        ) callconv(.c) void = null,
    };

    /// This is the key event sent for ghostty_surface_key and
    /// ghostty_app_key.
    pub const KeyEvent = struct {
        action: input.Action,
        mods: input.Mods,
        consumed_mods: input.Mods,
        keycode: u32,
        text: ?[:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert a libghostty key event into a core key event.
        fn core(self: KeyEvent) ?input.KeyEvent {
            const text: []const u8 = if (self.text) |v| v else "";
            const unshifted_codepoint: u21 = std.math.cast(
                u21,
                self.unshifted_codepoint,
            ) orelse 0;

            // We want to get the physical unmapped key to process keybinds.
            const physical_key = keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;

            // Build our final key event
            return .{
                .action = self.action,
                .key = physical_key,
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }
    };

    core_app: *CoreApp,
    opts: Options,
    keymap: input.Keymap,

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        var keymap = try input.Keymap.init();
        errdefer keymap.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = keymap,
        };
    }

    pub fn terminate(self: *App) void {
        self.keymap.deinit();
        self.config.deinit();
    }

    /// Returns true if there are any global keybinds in the configuration.
    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }

        return false;
    }

    /// The target of a key event. This is used to determine some subtly
    /// different behavior between app and surface key events.
    pub const KeyTarget = union(enum) {
        app,
        surface: *Surface,
    };

    /// See CoreApp.focusEvent
    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    /// See CoreApp.keyEvent.
    pub fn keyEvent(
        self: *App,
        target: KeyTarget,
        event: KeyEvent,
    ) !bool {
        // Convert our C key event into a Zig one.
        const input_event: input.KeyEvent = event.core() orelse
            return false;

        // Invoke the core Ghostty logic to handle this input.
        const effect: CoreSurface.InputEffect = switch (target) {
            .app => if (self.core_app.keyEvent(
                self,
                input_event,
            )) .consumed else .ignored,

            .surface => |surface| try surface.core_surface.keyCallback(
                input_event,
            ),
        };

        return switch (effect) {
            .closed => true,
            .ignored => false,
            .consumed => true,
        };
    }

    /// This should be called whenever the keyboard layout was changed.
    pub fn reloadKeymap(self: *App) !void {
        // Reload the keymap
        try self.keymap.reload();
    }

    /// Loads the keyboard layout.
    ///
    /// Kind of expensive so this should be avoided if possible. When I say
    /// "kind of expensive" I mean that its not something you probably want
    /// to run on every keypress.
    pub fn keyboardLayout(self: *const App) input.KeyboardLayout {
        // We only support keyboard layout detection on macOS.
        if (comptime builtin.os.tag != .macos) return .unknown;

        // Any layout larger than this is not something we can handle.
        var buf: [256]u8 = undefined;
        const id = self.keymap.sourceId(&buf) catch |err| {
            comptime assert(@TypeOf(err) == error{OutOfMemory});
            return .unknown;
        };

        return input.KeyboardLayout.mapAppleId(id) orelse .unknown;
    }

    pub fn wakeup(self: *const App) void {
        self.opts.wakeup(self.opts.userdata);
    }

    pub fn wait(self: *const App) !void {
        _ = self;
    }

    /// Create a new surface for the app.
    fn newSurface(
        self: *App,
        opts: Surface.Options,
        scrollback_limit_bytes: usize,
    ) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try self.core_app.alloc.create(Surface);
        errdefer self.core_app.alloc.destroy(surface);

        // Create the surface
        try surface.init(self, opts, scrollback_limit_bytes);
        errdefer surface.deinit();

        return surface;
    }

    /// Close the given surface.
    pub fn closeSurface(self: *App, surface: *Surface) void {
        surface.deinit();
        self.core_app.alloc.destroy(surface);
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }

    /// Perform a given action. Returns `true` if the action was able to be
    /// performed, `false` otherwise.
    pub fn performAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        return self.opts.action(
            self,
            target.cval(),
            @unionInit(apprt.Action, @tagName(action), value).cval(),
        );
    }

    fn performPreAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) void {
        // Special case certain actions before they are sent to the embedder
        switch (action) {
            .set_title => switch (target) {
                .app => {},
                .surface => |surface| {
                    // Dupe the title so that we can store it. If we get an allocation
                    // error we just ignore it, since this only breaks a few minor things.
                    const alloc = self.core_app.alloc;
                    if (surface.rt_surface.title) |v| alloc.free(v);
                    surface.rt_surface.title = alloc.dupeZ(u8, value.title) catch null;
                },
            },

            .config_change => switch (target) {
                .surface => {},

                // For app updates, we update our core config. We need to
                // clone it because the caller owns the param.
                .app => if (value.config.clone(self.core_app.alloc)) |config| {
                    self.config.deinit();
                    self.config = config;
                } else |err| {
                    log.err("error updating app config err={}", .{err});
                },
            },

            else => {},
        }
    }

    /// Send the given IPC to a running Ghostty. Returns `true` if the action was
    /// able to be performed, `false` otherwise.
    ///
    /// Note that this is a static function. Since this is called from a CLI app (or
    /// some other process that is not Ghostty) there is no full-featured apprt App
    /// to use.
    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
        switch (action) {
            .new_window => return false,
            .toggle_quick_terminal => return false,
        }
    }
};

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,
    opengl: OpenGL,
    metal_external: MetalExternal,

    // If our build target for libghostty is not darwin then we do
    // not include macos support at all.
    pub const MacOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        nsview: objc.Object,
    } else void;

    pub const IOS = if (builtin.target.os.tag.isDarwin()) struct {
        /// The view to render the surface on.
        uiview: objc.Object,
    } else void;

    /// An embedder-owned presenter for Metal IOSurfaces. This platform never
    /// accesses an NSView, UIView, or CALayer. The callback runs on a Metal
    /// command-buffer completion thread after the GPU finishes the frame.
    pub const MetalExternal = if (builtin.target.os.tag.isDarwin()) struct {
        userdata: ?*anyopaque,

        /// `iosurface` is borrowed and valid only for the callback duration.
        /// Retain it or create its transport handle before returning if the
        /// embedder needs to extend its lifetime. The callback must be
        /// thread-safe and must not block the renderer thread.
        present: *const fn (
            userdata: ?*anyopaque,
            iosurface: *anyopaque,
            width_px: u32,
            height_px: u32,
        ) callconv(.c) void,
    } else void;

    /// An embedder-owned OpenGL context and presentation surface. The
    /// callbacks may be invoked from Ghostty's renderer thread.
    pub const OpenGL = struct {
        userdata: ?*anyopaque,
        make_current: *const fn (?*anyopaque) callconv(.c) bool,
        clear_current: *const fn (?*anyopaque) callconv(.c) void,
        get_proc_address: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
        swap_buffers: *const fn (?*anyopaque) callconv(.c) void,
    };

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },

        metal_external: extern struct {
            userdata: ?*anyopaque,
            present: ?*const fn (
                userdata: ?*anyopaque,
                iosurface: *anyopaque,
                width_px: u32,
                height_px: u32,
            ) callconv(.c) void,
        },

        opengl: extern struct {
            userdata: ?*anyopaque,
            make_current: ?*const fn (?*anyopaque) callconv(.c) bool,
            clear_current: ?*const fn (?*anyopaque) callconv(.c) void,
            get_proc_address: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
            swap_buffers: ?*const fn (?*anyopaque) callconv(.c) void,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        const tag = try std.meta.intToEnum(PlatformTag, tag_int);
        return switch (tag) {
            .macos => if (MacOS != void) macos: {
                const config = c_platform.macos;
                const nsview = objc.Object.fromId(config.nsview orelse
                    break :macos error.NSViewMustBeSet);
                break :macos .{ .macos = .{ .nsview = nsview } };
            } else error.UnsupportedPlatform,

            .ios => if (IOS != void) ios: {
                const config = c_platform.ios;
                const uiview = objc.Object.fromId(config.uiview orelse
                    break :ios error.UIViewMustBeSet);
                break :ios .{ .ios = .{ .uiview = uiview } };
            } else error.UnsupportedPlatform,

            .metal_external => if (MetalExternal != void) metal_external: {
                const config = c_platform.metal_external;
                break :metal_external .{ .metal_external = .{
                    .userdata = config.userdata,
                    .present = config.present orelse
                        return error.MetalExternalPresentMustBeSet,
                } };
            } else error.UnsupportedPlatform,

            .opengl => opengl: {
                const config = c_platform.opengl;
                break :opengl .{ .opengl = .{
                    .userdata = config.userdata,
                    .make_current = config.make_current orelse
                        return error.OpenGLMakeCurrentMustBeSet,
                    .clear_current = config.clear_current orelse
                        return error.OpenGLClearCurrentMustBeSet,
                    .get_proc_address = config.get_proc_address orelse
                        return error.OpenGLGetProcAddressMustBeSet,
                    .swap_buffers = config.swap_buffers orelse
                        return error.OpenGLSwapBuffersMustBeSet,
                } };
            },
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
    opengl = 3,
    metal_external = 4,
};

test "embedded metal external platform validates presentation callback" {
    if (Platform.MetalExternal == void) return error.SkipZigTest;

    var c_platform: Platform.C = undefined;
    c_platform.metal_external = .{
        .userdata = null,
        .present = null,
    };
    try std.testing.expectError(
        error.MetalExternalPresentMustBeSet,
        Platform.init(@intFromEnum(PlatformTag.metal_external), c_platform),
    );

    const Callback = struct {
        fn present(
            _: ?*anyopaque,
            _: *anyopaque,
            _: u32,
            _: u32,
        ) callconv(.c) void {}
    };
    c_platform.metal_external.present = &Callback.present;

    const platform = try Platform.init(
        @intFromEnum(PlatformTag.metal_external),
        c_platform,
    );
    try std.testing.expectEqual(
        PlatformTag.metal_external,
        std.meta.activeTag(platform),
    );
    try std.testing.expectEqual(
        @as(c_int, 4),
        @intFromEnum(PlatformTag.metal_external),
    );
}

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: [*:0]const u8,

    /// The value of the environment variable.
    value: [*:0]const u8,
};

// cmux fork: delete when upstream libghostty exposes equivalent surface IO
// ownership. iOS uses this so Rust owns the session while Ghostty renders it.
pub const IoMode = enum(c_int) {
    exec = 0,
    manual = 1,
    manual_mirror = 2,

    pub fn usesManualIo(self: IoMode) bool {
        return switch (self) {
            .exec => false,
            .manual, .manual_mirror => true,
        };
    }

    pub fn suppressesTerminalResponses(self: IoMode) bool {
        return self == .manual_mirror;
    }
};

pub const IoWriteCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
pub const PtyTeeCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;
pub const RendererEventCallback = renderer.InstrumentationCallback;

pub const Surface = struct {
    app: *App,
    platform: Platform,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    cursor_pos_mods: input.Mods,
    inspector: ?*Inspector = null,
    io_mode: IoMode = .exec,
    io_write_cb: ?IoWriteCallback = null,
    io_write_userdata: ?*anyopaque = null,
    pty_tee_cb: ?PtyTeeCallback = null,
    pty_tee_userdata: ?*anyopaque = null,
    renderer_event_cb: ?RendererEventCallback = null,
    scrollback_limit_bytes: usize = 0,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = undefined,

        /// Userdata passed to some of the callbacks.
        userdata: ?*anyopaque = null,

        /// The scale factor of the screen.
        scale_factor: f64 = 1,

        /// The font size to inherit. If 0, default font size will be used.
        font_size: f32 = 0,

        /// The working directory to load into.
        working_directory: ?[*:0]const u8 = null,

        /// The command to run in the new surface. If this is set then
        /// the "wait-after-command" option is also automatically set to true,
        /// since this is used for scripting.
        ///
        /// This command always run in a shell (e.g. via `/bin/sh -c`),
        /// despite Ghostty allowing directly executed commands via config.
        /// This is a legacy thing and we should probably change it in the
        /// future once we have a concrete use case.
        command: ?[*:0]const u8 = null,

        /// Extra environment variables to set for the surface.
        env_vars: ?[*]EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Context for the new surface
        context: apprt.surface.NewSurfaceContext = .window,

        /// IO mode for the surface.
        io_mode: IoMode = .exec,

        /// Callback invoked when Ghostty wants to write to the backend.
        io_write_cb: ?IoWriteCallback = null,

        /// Userdata passed to io_write_cb.
        io_write_userdata: ?*anyopaque = null,

        /// Optional content-free renderer activity callback. This receives the
        /// surface `userdata` and runs synchronously on the renderer thread.
        renderer_event_cb: ?RendererEventCallback = null,

        /// Optional tee for every PTY-output byte slice before parsing. Unlike
        /// the post-create setter, this is installed before the IO thread can
        /// emit startup bytes.
        pty_tee_cb: ?PtyTeeCallback = null,

        /// Userdata passed to pty_tee_cb.
        pty_tee_userdata: ?*anyopaque = null,
    };

    pub fn init(
        self: *Surface,
        app: *App,
        opts: Options,
        scrollback_limit_bytes: usize,
    ) !void {
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
            .cursor_pos_mods = .{},
            .io_mode = opts.io_mode,
            .io_write_cb = opts.io_write_cb,
            .io_write_userdata = opts.io_write_userdata,
            .pty_tee_cb = opts.pty_tee_cb,
            .pty_tee_userdata = opts.pty_tee_userdata,
            .renderer_event_cb = opts.renderer_event_cb,
            .scrollback_limit_bytes = scrollback_limit_bytes,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, opts.context);
        defer config.deinit();
        config.@"scrollback-limit" = effectiveScrollbackLimit(
            config.@"scrollback-limit",
            scrollback_limit_bytes,
        );

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                var dir = std.fs.openDirAbsolute(wd, .{}) catch |err| {
                    log.warn(
                        "error opening requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };
                defer dir.close();

                const stat = dir.stat() catch |err| {
                    log.warn(
                        "failed to stat requested working directory dir={s} err={}",
                        .{ wd, err },
                    );
                    break :wd;
                };

                if (stat.kind != .directory) {
                    log.warn(
                        "requested working directory is not a directory dir={s}",
                        .{wd},
                    );
                    break :wd;
                }

                var wd_val: configpkg.WorkingDirectory = .{ .path = wd };
                if (wd_val.finalize(config.arenaAlloc())) |_| {
                    config.@"working-directory" = wd_val;
                } else |err| {
                    log.warn(
                        "error finalizing working directory config dir={s} err={}",
                        .{ wd_val.path, err },
                    );
                }
            }
        }

        // If we have a command from the options then we set it.
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        if (opts.env_var_count > 0) {
            const alloc = config.arenaAlloc();
            for (opts.env_vars.?[0..opts.env_var_count]) |env_var| {
                const key = std.mem.sliceTo(env_var.key, 0);
                const value = std.mem.sliceTo(env_var.value, 0);
                try config.env.map.put(
                    alloc,
                    try alloc.dupeZ(u8, key),
                    try alloc.dupeZ(u8, value),
                );
            }
        }

        // If we have an initial input then we set it.
        if (opts.initial_input) |c_input| {
            const alloc = config.arenaAlloc();

            // We need to escape the string because the "raw" field
            // expects a Zig string.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            try std.zig.stringEscape(
                std.mem.sliceTo(c_input, 0),
                &buf.writer,
            );

            config.input.list.clearRetainingCapacity();
            try config.input.list.append(
                alloc,
                .{ .raw = try buf.toOwnedSliceSentinel(0) },
            );
        }

        // Wait after command
        if (opts.wait_after_command) {
            config.@"wait-after-command" = true;
        }

        // Initialize our surface right away. We're given a view that is
        // ready to use.
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // If our options requested a specific font-size, set that.
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }
    }

    /// Applies an optional embedder cap without ever raising the user's
    /// configured lower scrollback limit.
    fn effectiveScrollbackLimit(configured: usize, embedder_cap: usize) usize {
        if (embedder_cap == 0) return configured;
        return @min(configured, embedder_cap);
    }

    test "embedded surface scrollback cap inherits when unset" {
        try std.testing.expectEqual(@as(usize, 144), @sizeOf(Options));
        try std.testing.expectEqual(
            @as(usize, 50_000_000),
            effectiveScrollbackLimit(50_000_000, 0),
        );
    }

    test "embedded surface options include initial PTY tee" {
        const options: Options = .{};
        try std.testing.expect(options.pty_tee_cb == null);
        try std.testing.expect(options.pty_tee_userdata == null);
        try std.testing.expect(
            @offsetOf(Options, "pty_tee_cb") <
                @offsetOf(Options, "pty_tee_userdata"),
        );
    }

    test "embedded surface scrollback cap only lowers configured limit" {
        try std.testing.expectEqual(
            @as(usize, 8_388_608),
            effectiveScrollbackLimit(50_000_000, 8_388_608),
        );
        try std.testing.expectEqual(
            @as(usize, 2_000_000),
            effectiveScrollbackLimit(2_000_000, 8_388_608),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            effectiveScrollbackLimit(0, 8_388_608),
        );
    }

    pub fn deinit(self: *Surface) void {
        // Shut down our inspector
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(self: *const Surface, process_alive: bool) void {
        const func = self.app.opts.close_surface orelse {
            log.info("runtime embedder does not support closing a surface", .{});
            return;
        };

        func(self.userdata, process_alive);
    }

    pub fn tmuxControl(
        self: *const Surface,
        event: apprt.surface.Message.TmuxControlMsg.Event,
        id: u32,
        data: []const u8,
    ) void {
        const func = self.app.opts.tmux_control orelse return;
        func(self.userdata, event, id, data.ptr, data.len);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn ioMode(self: *const Surface) IoMode {
        return self.io_mode;
    }

    pub fn usesManualIo(self: *const Surface) bool {
        return self.io_mode.usesManualIo();
    }

    pub fn ioWriteCallback(self: *const Surface) ?IoWriteCallback {
        return self.io_write_cb;
    }

    pub fn ioWriteUserdata(self: *const Surface) ?*anyopaque {
        return self.io_write_userdata;
    }

    pub fn ptyTeeCallback(self: *const Surface) ?PtyTeeCallback {
        return self.pty_tee_cb;
    }

    pub fn ptyTeeUserdata(self: *const Surface) ?*anyopaque {
        return self.pty_tee_userdata;
    }

    pub fn suppressTerminalResponses(self: *const Surface) bool {
        return self.io_mode.suppressesTerminalResponses();
    }

    pub fn rendererInstrumentation(self: *const Surface) renderer.Instrumentation {
        return .{
            .callback = self.renderer_event_cb,
            .userdata = self.userdata,
        };
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => true,
            .selection, .primary => self.app.opts.supports_selection_clipboard,
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        // We need to allocate to get a pointer to store our clipboard request
        // so that it is stable until the read_clipboard callback and call
        // complete_clipboard_request. This sucks but clipboard requests aren't
        // high throughput so it's probably fine.
        const alloc = self.app.core_app.alloc;
        const state_ptr = try alloc.create(apprt.ClipboardRequest);
        errdefer alloc.destroy(state_ptr);
        state_ptr.* = state;

        const started = self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_ptr,
        );
        if (!started) {
            alloc.destroy(state_ptr);
            return false;
        }

        return true;
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;

        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    state,
                    state.*,
                );

                return;
            },

            else => log.err("error completing clipboard request err={}", .{err}),
        };

        // We don't defer this because the clipboard confirmation route
        // preserves the clipboard request.
        alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        const alloc = self.app.core_app.alloc;
        const array = try alloc.alloc(CAPI.ClipboardContent, contents.len);
        defer alloc.free(array);
        for (contents, 0..) |content, i| {
            array[i] = .{
                .mime = content.mime,
                .data = content.data,
            };
        }

        self.app.opts.write_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            array.ptr,
            array.len,
            confirm,
        );
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.core_surface.refreshCallback() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return;
        };
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw err={}", .{err});
            return;
        };
    }

    pub fn renderNow(self: *Surface) void {
        self.core_surface.applyPendingResizeIfNeeded();
        self.core_surface.renderer_thread.renderNow();
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        // We are an embedded API so the caller can send us all sorts of
        // garbage. We want to make sure that the float values are valid
        // and we don't want to support fractional scaling below 1.
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return;
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{
            .width = width,
            .height = height,
        };

        // Call the primary callback.
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback err={}", .{err});
            return;
        };
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback err={}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return;
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return;
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return;
        };

        // There are cases where the platform reports a mouse motion event
        // without the cursor actually moving. For example, on macOS, updating
        // the window title can trigger a phantom mouse-move event at the same
        // coordinates. This can cause the mouse to incorrectly unhide when
        // mouse-hide-while-typing is enabled (commonly seen with TUI apps
        // like Zellij that frequently update the title). To prevent incorrect
        // behavior, we only continue with callback logic if the cursor has
        // actually moved.
        if (@abs(self.cursor_pos.x - pos.x) < 1 and
            @abs(self.cursor_pos.y - pos.y) < 1 and
            self.cursor_pos_mods.equal(mods)) return;

        self.cursor_pos = pos;
        self.cursor_pos_mods = mods;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return;
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return;
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in key callback err={}", .{err});
            return;
        };
    }

    pub fn textInputCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textInputCallback(text) catch |err| {
            log.err("error in text input callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return;
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return;
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        _ = self.app.performAction(
            .{ .surface = &self.core_surface },
            .render_inspector,
            {},
        ) catch |err| {
            log.err("error rendering the inspector err={}", .{err});
            return;
        };
    }

    pub fn newSurfaceOptions(self: *const Surface, context: apprt.surface.NewSurfaceContext) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };

        const working_directory: ?[*:0]const u8 = wd: {
            if (!apprt.surface.shouldInheritWorkingDirectory(context, &self.app.config)) break :wd null;
            const cwd = self.core_surface.pwd(self.app.core_app.alloc) catch null orelse break :wd null;
            defer self.app.core_app.alloc.free(cwd);
            break :wd self.app.core_app.alloc.dupeZ(u8, cwd) catch null;
        };

        return .{
            .font_size = font_size,
            .working_directory = working_directory,
            .context = context,
            .io_mode = self.io_mode,
            .io_write_cb = self.io_write_cb,
            .io_write_userdata = self.io_write_userdata,
            .renderer_event_cb = self.renderer_event_cb,
        };
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        const alloc = self.app.core_app.alloc;
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        if (comptime builtin.target.os.tag.isDarwin()) {
            if (env.get("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != null) {
                env.remove("__XCODE_BUILT_PRODUCTS_DIR_PATHS");
                env.remove("__XPC_DYLD_LIBRARY_PATH");
                env.remove("DYLD_FRAMEWORK_PATH");
                env.remove("DYLD_INSERT_LIBRARIES");
                env.remove("DYLD_LIBRARY_PATH");
                env.remove("LD_LIBRARY_PATH");
                env.remove("SECURITYSESSIONID");
                env.remove("XPC_SERVICE_NAME");
            }

            // Remove this so that running `ghostty` within Ghostty works.
            env.remove("GHOSTTY_MAC_LAUNCH_SOURCE");

            // If we were launched from the desktop then we want to
            // remove the LANGUAGE env var so that we don't inherit
            // our translation settings for Ghostty. If we aren't from
            // the desktop then we didn't set our LANGUAGE var so we
            // don't need to remove it.
            if (internal_os.launchedFromDesktop()) env.remove("LANGUAGE");
        }

        return env;
    }

    /// The cursor position from the host directly is in screen coordinates but
    /// all our interface works in pixels.
    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

// The cmux integration combines the OpenGL platform payload (the largest
// Platform.C variant) with the startup PTY tee fields. Keep the resulting C
// layout pinned so every exact-revision consumer fails loudly on drift.
const surface_config_abi_size = 168;

test "embedded surface config ABI is pinned" {
    const defaults: Surface.Options = .{};
    try std.testing.expectEqual(
        @as(usize, surface_config_abi_size),
        @sizeOf(Surface.Options),
    );
    try std.testing.expectEqual(IoMode.exec, defaults.io_mode);
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(IoMode.manual_mirror));
    try std.testing.expect(!IoMode.exec.usesManualIo());
    try std.testing.expect(IoMode.manual.usesManualIo());
    try std.testing.expect(IoMode.manual_mirror.usesManualIo());
    try std.testing.expect(!IoMode.manual.suppressesTerminalResponses());
    try std.testing.expect(IoMode.manual_mirror.suppressesTerminalResponses());
}

comptime {
    const defaults: Surface.Options = .{};
    if (@sizeOf(Surface.Options) != surface_config_abi_size)
        @compileError("embedded surface config ABI changed; update all pinned consumers");
    if (defaults.io_mode != .exec)
        @compileError("surface IO must default to exec mode");
    if (@intFromEnum(IoMode.manual_mirror) != 2)
        @compileError("manual mirror IO mode must preserve its C ABI value");
    if (!IoMode.manual.usesManualIo() or !IoMode.manual_mirror.usesManualIo())
        @compileError("both manual IO modes must use the embedder backend");
    if (IoMode.manual.suppressesTerminalResponses() or
        !IoMode.manual_mirror.suppressesTerminalResponses())
        @compileError("only manual mirror mode may suppress terminal responses");
}

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.time.Instant = null,

    const Backend = enum {
        metal,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
            }
        }
    };

    pub fn init(surface: *Surface) !Inspector {
        const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
        errdefer cimgui.c.ImGui_DestroyContext(ig_ctx);
        cimgui.c.ImGui_SetCurrentContext(ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.BackendPlatformName = "ghostty_embedded";

        // Setup our core inspector
        CoreInspector.setup();
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        return .{
            .surface = surface,
            .ig_ctx = ig_ctx,
        };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        if (self.backend) |v| v.deinit();
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    /// Queue a render for the next frame.
    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    /// Initialize the inspector for a metal backend.
    pub fn initMetal(self: *Inspector, device: objc.Object) bool {
        defer device.msgSend(void, objc.sel("release"), .{});
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplMetal_Init(device.value)) {
            log.warn("failed to initialize metal backend", .{});
            return false;
        }
        self.backend = .metal;

        log.debug("initialized metal backend", .{});
        return true;
    }

    pub fn renderMetal(
        self: *Inspector,
        command_buffer: objc.Object,
        desc: objc.Object,
    ) !void {
        defer {
            command_buffer.msgSend(void, objc.sel("release"), .{});
            desc.msgSend(void, objc.sel("release"), .{});
        }
        assert(self.backend == .metal);
        //log.debug("render", .{});

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplMetal_NewFrame(desc.value);
            try self.newFrame();
            cimgui.c.ImGui_NewFrame();

            // Build our UI
            render: {
                const surface = &self.surface.core_surface;
                const inspector = surface.inspector orelse break :render;
                inspector.render(surface);
            }

            // Render
            cimgui.c.ImGui_Render();
        }

        // MTLRenderCommandEncoder
        const encoder = command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );
        defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
        cimgui.ImGui_ImplMetal_RenderDrawData(
            cimgui.c.ImGui_GetDrawData(),
            command_buffer.value,
            encoder.value,
        );
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = x;

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, @floatCast(x));
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return, // unsupported
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // For precision scrolling (trackpads), the values are in pixels which
        // scroll way too fast. Scale them down to approximate discrete wheel
        // notches. imgui expects 1.0 to scroll ~5 lines of text.
        const scale: f64 = if (mods.precision) 0.1 else 1.0;
        cimgui.c.ImGuiIO_AddMouseWheelEvent(
            io,
            @floatCast(xoff * scale),
            @floatCast(yoff * scale),
        );
    }

    pub fn cursorPosCallback(self: *Inspector, x: f64, y: f64) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddMousePosEvent(
            io,
            @floatCast(x * self.content_scale),
            @floatCast(y * self.content_scale),
        );
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddFocusEvent(io, focused);
    }

    pub fn textCallback(self: *Inspector, text: [:0]const u8) void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, text.ptr);
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Update all our modifiers
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, mods.shift);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, mods.ctrl);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, mods.alt);
        cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftSuper, mods.super);

        // Send our keypress
        if (key.imguiKey()) |imgui_key| {
            cimgui.c.ImGuiIO_AddKeyEvent(
                io,
                imgui_key,
                action == .press or action == .repeat,
            );
        }
    }

    fn newFrame(self: *Inspector) !void {
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        // Determine our delta time
        const now = try std.time.Instant.now();
        io.DeltaTime = if (self.instant) |prev| delta: {
            const since_ns: f64 = @floatFromInt(now.since(prev));
            const ns_per_s: f64 = @floatFromInt(std.time.ns_per_s);
            const since_s: f32 = @floatCast(since_ns / ns_per_s);
            break :delta @max(0.00001, since_s);
        } else (1.0 / 60.0);
        self.instant = now;
    }
};

// C API
pub const CAPI = struct {
    const global = &@import("../global.zig").state;

    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: input.Action,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent) App.KeyEvent {
            return .{
                .action = self.action,
                .mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.mods))),
                )),
                .consumed_mods = @bitCast(@as(
                    input.Mods.Backing,
                    @truncate(@as(c_uint, @bitCast(self.consumed_mods))),
                )),
                .keycode = self.keycode,
                .text = if (self.text) |ptr| std.mem.sliceTo(ptr, 0) else null,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    const SurfaceSize = extern struct {
        columns: u16,
        rows: u16,
        width_px: u32,
        height_px: u32,
        cell_width_px: u32,
        cell_height_px: u32,
    };

    const SurfaceScrollbar = extern struct {
        total: u64,
        offset: u64,
        len: u64,
        row_space_revision: u64,
    };

    // ghostty_clipboard_content_s
    const ClipboardContent = extern struct {
        mime: [*:0]const u8,
        data: [*:0]const u8,
    };

    // ghostty_text_s
    const Text = extern struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
        text: ?[*:0]const u8,
        text_len: usize,

        pub fn deinit(self: *Text) void {
            if (self.text) |ptr| {
                global.alloc.free(ptr[0..self.text_len :0]);
            }
        }
    };

    // ghostty_point_s
    const Point = extern struct {
        tag: Tag,
        coord_tag: CoordTag,
        x: u32,
        y: u32,

        const Tag = enum(c_int) {
            active = 0,
            viewport = 1,
            screen = 2,
            history = 3,
        };

        const CoordTag = enum(c_int) {
            exact = 0,
            top_left = 1,
            bottom_right = 2,
        };

        fn pin(
            self: Point,
            screen: *const terminal.Screen,
        ) ?terminal.Pin {
            // The core point tag.
            const tag: terminal.point.Tag = switch (self.tag) {
                inline else => |tag| @field(
                    terminal.point.Tag,
                    @tagName(tag),
                ),
            };

            // Clamp our point to the screen bounds.
            const clamped_x = @min(self.x, screen.pages.cols -| 1);
            const clamped_y = @min(self.y, screen.pages.rows -| 1);

            return switch (self.coord_tag) {
                // Exact coordinates require a specific pin.
                .exact => exact: {
                    const pt_x = std.math.cast(
                        terminal.size.CellCountInt,
                        clamped_x,
                    ) orelse std.math.maxInt(terminal.size.CellCountInt);

                    const pt: terminal.Point = switch (tag) {
                        inline else => |v| @unionInit(
                            terminal.Point,
                            @tagName(v),
                            .{ .x = pt_x, .y = clamped_y },
                        ),
                    };

                    break :exact screen.pages.pin(pt) orelse null;
                },

                .top_left => screen.pages.getTopLeft(tag),

                .bottom_right => screen.pages.getBottomRight(tag),
            };
        }
    };

    // ghostty_selection_s
    const Selection = extern struct {
        tl: Point,
        br: Point,
        rectangle: bool,

        fn core(
            self: Selection,
            screen: *const terminal.Screen,
        ) ?terminal.Selection {
            return .{
                .bounds = .{ .untracked = .{
                    .start = self.tl.pin(screen) orelse return null,
                    .end = self.br.pin(screen) orelse return null,
                } },
                .rectangle = self.rectangle,
            };
        }
    };

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.os.tag.isDarwin()) {
            _ = Darwin;
        }
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts: *const apprt.runtime.App.Options,
        config: *const Config,
    ) !*App {
        const core_app = try CoreApp.create(global.alloc);
        errdefer core_app.destroy();

        // Create our runtime app
        var app = try global.alloc.create(App);
        errdefer global.alloc.destroy(app);
        try app.init(core_app, config, opts.*);
        errdefer app.terminate();

        return app;
    }

    /// Tick the event loop. This should be called whenever the "wakeup"
    /// callback is invoked for the runtime.
    export fn ghostty_app_tick(v: *App) void {
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
        };
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v: *App) ?*anyopaque {
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v: *App) void {
        const core_app = v.core_app;
        v.terminate();
        global.alloc.destroy(v);
        core_app.destroy();
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app: *App,
        focused: bool,
    ) void {
        app.focusEvent(focused);
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app: *App,
        event: KeyEvent,
    ) bool {
        return app.keyEvent(.app, event.keyEvent()) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_config_key_is_binding(
        config: *Config,
        event: KeyEvent,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return config.keyEventIsBinding(core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v: *App) void {
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return;
        };
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v: *App) void {
        _ = v.performAction(.app, .open_config, {}) catch |err| {
            log.err("error reloading config err={}", .{err});
            return;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v: *App,
        config: *const Config,
    ) void {
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v: *App) bool {
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v: *App) bool {
        return v.hasGlobalKeybinds();
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v: *App, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return;
        };
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: *App,
        opts: *const apprt.Surface.Options,
    ) ?*Surface {
        return surface_new_(app, opts, 0) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    /// Create a surface with an embedder-owned upper bound for scrollback
    /// while preserving the byte layout of Surface.Options.
    export fn ghostty_surface_new_with_scrollback_limit(
        app: *App,
        opts: *const apprt.Surface.Options,
        scrollback_limit_bytes: usize,
    ) ?*Surface {
        return surface_new_(app, opts, scrollback_limit_bytes) catch |err| {
            log.err("error initializing surface err={}", .{err});
            return null;
        };
    }

    fn surface_new_(
        app: *App,
        opts: *const apprt.Surface.Options,
        scrollback_limit_bytes: usize,
    ) !*Surface {
        return try app.newSurface(opts.*, scrollback_limit_bytes);
    }

    export fn ghostty_surface_free(ptr: *Surface) void {
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface: *Surface) ?*anyopaque {
        return surface.userdata;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface: *Surface) *App {
        return surface.app;
    }

    /// Returns the separate embedder cap so inherited surface creation can
    /// preserve it without adding a field to Surface.Options.
    export fn ghostty_surface_scrollback_limit_bytes(surface: *Surface) usize {
        return surface.scrollback_limit_bytes;
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(
        surface: *Surface,
        source: apprt.surface.NewSurfaceContext,
    ) Surface.Options {
        return surface.newSurfaceOptions(source);
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return;
        };
    }

    /// Update only the terminal color defaults used by OSC reset sequences.
    /// Manual-IO embedders must serialize this with process_output.
    export fn ghostty_surface_update_theme_config(
        surface: *Surface,
        config: *const Config,
    ) void {
        var derived = termio.Termio.DerivedConfig.init(
            surface.core_surface.alloc,
            config,
        ) catch |err| {
            log.err("error deriving theme config err={}", .{err});
            return;
        };
        defer derived.deinit();
        surface.core_surface.io.changeColorConfig(&derived);
        surface.core_surface.renderer.changeColorConfig(config);
    }

    /// Returns true if the surface needs to confirm quitting.
    export fn ghostty_surface_needs_confirm_quit(surface: *Surface) bool {
        return surface.core_surface.needsConfirmQuit();
    }

    /// Returns true if the surface process has exited.
    export fn ghostty_surface_process_exited(surface: *Surface) bool {
        return surface.core_surface.child_exited;
    }

    /// Returns the live app-thread-owned font size without touching renderer state.
    export fn ghostty_surface_font_size(surface: *Surface) f32 {
        return surface.core_surface.font_size.points;
    }

    /// Returns whether the live font size has explicit surface-local ownership.
    export fn ghostty_surface_font_size_adjusted(surface: *Surface) bool {
        return surface.core_surface.font_size_adjusted;
    }

    /// Returns true if the surface has a selection.
    export fn ghostty_surface_has_selection(surface: *Surface) bool {
        return surface.core_surface.hasSelection();
    }

    /// Select the cell under the cursor (cmux-specific).
    export fn ghostty_surface_select_cursor_cell(surface: *Surface) bool {
        return surface.core_surface.selectCursorCell() catch |err| {
            log.warn("error selecting cursor cell err={}", .{err});
            return false;
        };
    }

    /// Select the semantic line under the cursor (cmux-specific).
    export fn ghostty_surface_select_cursor_line(surface: *Surface) bool {
        return surface.core_surface.selectCursorLine() catch |err| {
            log.warn("error selecting cursor line err={}", .{err});
            return false;
        };
    }

    /// Clear the active selection (cmux-specific).
    export fn ghostty_surface_clear_selection(surface: *Surface) bool {
        return surface.core_surface.clearSelection() catch |err| {
            log.warn("error clearing selection err={}", .{err});
            return false;
        };
    }

    /// Select inclusive absolute screen rows without writing clipboards
    /// (cmux-specific).
    export fn ghostty_surface_select_screen_rows(
        surface: *Surface,
        top_y: u32,
        bottom_y: u32,
    ) bool {
        return surface.core_surface.selectScreenRows(top_y, bottom_y) catch |err| {
            log.warn("error selecting screen rows err={}", .{err});
            return false;
        };
    }

    /// Query the active tracked selection as inclusive absolute screen rows
    /// (cmux-specific).
    export fn ghostty_surface_selection_screen_rows(
        surface: *Surface,
        top_y: *u32,
        bottom_y: *u32,
    ) bool {
        return surface.core_surface.selectionScreenRows(top_y, bottom_y);
    }

    /// Same as ghostty_surface_read_text but reads from the user selection,
    /// if any.
    export fn ghostty_surface_read_selection(
        surface: *Surface,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        // If we don't have a selection, do nothing.
        const core_sel = core_surface.io.terminal.screens.active.selection orelse return false;

        // Read the text from the selection.
        return readTextLocked(surface, core_sel, result);
    }

    /// Read some arbitrary text from the surface.
    ///
    /// This is an expensive operation so it shouldn't be called too
    /// often. We recommend that callers cache the result and throttle
    /// calls to this function.
    export fn ghostty_surface_read_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    /// cmux fork: read clipboard-formatted plain text from inclusive absolute
    /// screen rows without mutating the active selection.
    export fn ghostty_surface_read_screen_clipboard_text(
        surface: *Surface,
        top_y: u32,
        bottom_y: u32,
        max_bytes: usize,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        if (top_y > bottom_y) return false;

        const screen = surface.core_surface.renderer_state.terminal.screens.active;
        const pages = &screen.pages;
        if (pages.cols == 0) return false;

        const top_left = pages.pin(.{
            .screen = .{ .x = 0, .y = top_y },
        }) orelse return false;
        const bottom_right = pages.pin(.{
            .screen = .{ .x = pages.cols -| 1, .y = bottom_y },
        }) orelse return false;
        const core_sel = terminal.Selection.init(top_left, bottom_right, false);

        return readClipboardTextLocked(surface, core_sel, max_bytes, result);
    }

    /// cmux fork: read a byte-bounded VT reconstruction of the most recent
    /// physical screen/history rows without flattening Ghostty's cell model.
    export fn ghostty_surface_read_screen_tail_vt(
        surface: *Surface,
        max_rows: usize,
        max_bytes: usize,
        result: *Text,
    ) bool {
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        return readScreenTailVTLocked(surface, max_rows, max_bytes, result);
    }

    /// Atomically capture a VT tail and the modulo-u64 position immediately
    /// after every PTY-output byte represented by that terminal snapshot.
    export fn ghostty_surface_read_screen_tail_vt_with_output_sequence(
        surface: *Surface,
        max_rows: usize,
        max_bytes: usize,
        result: *Text,
        next_sequence: *u64,
    ) bool {
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        const snapshot_succeeded = readScreenTailVTLocked(
            surface,
            max_rows,
            max_bytes,
            result,
        );
        return publishOutputSnapshotSequenceLocked(
            snapshot_succeeded,
            surface.core_surface.io.processed_output_bytes,
            next_sequence,
        );
    }

    fn readScreenTailVTLocked(
        surface: *Surface,
        max_rows: usize,
        max_bytes: usize,
        result: *Text,
    ) bool {
        if (max_rows == 0 or max_bytes == 0) return false;
        const core_surface = &surface.core_surface;
        const opts: terminal.formatter.Options = .{
            .emit = .vt,
            .unwrap = false,
            .trim = false,
            .background = core_surface.io.terminal.colors.background.get(),
            .foreground = core_surface.io.terminal.colors.foreground.get(),
            .palette = &core_surface.io.terminal.colors.palette.current,
        };
        const formatter: terminal.formatter.ScreenFormatter = .init(
            core_surface.io.terminal.screens.active,
            opts,
        );

        const scratch = global.alloc.alloc(u8, max_bytes) catch |err| {
            log.warn("error allocating bounded screen tail buffer err={}", .{err});
            return false;
        };
        defer global.alloc.free(scratch);

        const formatted = formatter.formatTailBounded(scratch, max_rows) catch |err| {
            log.warn("error formatting bounded screen tail err={}", .{err});
            return false;
        };
        const owned = global.alloc.dupeZ(u8, formatted) catch |err| {
            log.warn("error allocating bounded screen tail result err={}", .{err});
            return false;
        };

        result.* = .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
            .text = owned.ptr,
            .text_len = owned.len,
        };
        return true;
    }

    fn publishOutputSnapshotSequenceLocked(
        snapshot_succeeded: bool,
        processed_output_bytes: u64,
        next_sequence: *u64,
    ) bool {
        if (!snapshot_succeeded) return false;
        next_sequence.* = processed_output_bytes;
        return true;
    }

    fn readTextLocked(
        surface: *Surface,
        core_sel: terminal.Selection,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;

        // Get our text directly from the core surface.
        const text = core_surface.dumpTextLocked(
            global.alloc,
            core_sel,
        ) catch |err| {
            log.warn("error reading text err={}", .{err});
            return false;
        };

        const vp: CoreSurface.Text.Viewport = text.viewport orelse .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
        };

        result.* = .{
            .tl_px_x = vp.tl_px_x,
            .tl_px_y = vp.tl_px_y,
            .offset_start = vp.offset_start,
            .offset_len = vp.offset_len,
            .text = text.text.ptr,
            .text_len = text.text.len,
        };

        return true;
    }

    fn readClipboardTextLocked(
        surface: *Surface,
        core_sel: terminal.Selection,
        max_bytes: usize,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        const opts: terminal.formatter.Options = .{
            .emit = .plain,
            .unwrap = true,
            .trim = core_surface.config.clipboard_trim_trailing_spaces,
            .codepoint_map = core_surface.config.clipboard_codepoint_map.map.list,
            .background = core_surface.io.terminal.colors.background.get(),
            .foreground = core_surface.io.terminal.colors.foreground.get(),
            .palette = &core_surface.io.terminal.colors.palette.current,
        };

        var formatter: terminal.formatter.ScreenFormatter = .init(
            core_surface.io.terminal.screens.active,
            opts,
        );
        formatter.content = .{ .selection = core_sel };

        const scratch = global.alloc.alloc(u8, max_bytes) catch |err| {
            log.warn("error allocating bounded clipboard text buffer err={}", .{err});
            return false;
        };
        defer global.alloc.free(scratch);

        var writer = std.Io.Writer.fixed(scratch);
        formatter.format(&writer) catch |err| {
            log.warn("error formatting clipboard text err={}", .{err});
            return false;
        };
        const formatted = global.alloc.dupeZ(u8, writer.buffered()) catch |err| {
            log.warn("error allocating clipboard text err={}", .{err});
            return false;
        };

        result.* = .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
            .text = formatted.ptr,
            .text_len = formatted.len,
        };

        return true;
    }

    export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void {
        ptr.deinit();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface: *Surface) void {
        surface.refresh();
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface: *Surface) void {
        surface.draw();
    }

    /// Perform a full render cycle synchronously from the calling thread.
    export fn ghostty_surface_render_now(surface: *Surface) void {
        surface.renderNow();
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface: *Surface, w: u32, h: u32) void {
        surface.updateSize(w, h);
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface: *Surface) SurfaceSize {
        const grid_size = surface.core_surface.size.grid();
        return .{
            .columns = grid_size.columns,
            .rows = grid_size.rows,
            .width_px = surface.core_surface.size.screen.width,
            .height_px = surface.core_surface.size.screen.height,
            .cell_width_px = surface.core_surface.size.cell.width,
            .cell_height_px = surface.core_surface.size.cell.height,
        };
    }

    const RenderGridColorSource = enum {
        default_color,
        palette,
        rgb,
    };

    const RenderGridColorSemantics = struct {
        source: RenderGridColorSource,
        palette_index: ?u8 = null,
    };

    /// Read current scrollbar geometry and its absolute row-space identity
    /// directly from the terminal, independent of renderer publication.
    export fn ghostty_surface_scrollbar(
        surface: *Surface,
        result: *SurfaceScrollbar,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.lockDemand();
        defer core_surface.renderer_state.unlockDemand();

        const screens = &core_surface.renderer_state.terminal.screens;
        const screen_key = screens.active_key;
        const scrollbar = screens.active.pages.scrollbar();
        result.* = .{
            .total = @intCast(scrollbar.total),
            .offset = @intCast(scrollbar.offset),
            .len = @intCast(scrollbar.len),
            .row_space_revision = core_surface.rowSpaceIdentity(
                screen_key,
                screens.generation(screen_key),
                scrollbar.row_space_revision,
            ),
        };
        return true;
    }

    /// Atomically validate an absolute row-space identity and scroll within it.
    export fn ghostty_surface_scroll_to_row_if_revision(
        surface: *Surface,
        row: u64,
        expected_row_space_revision: u64,
        result: *SurfaceScrollbar,
    ) bool {
        const target_row = std.math.cast(usize, row) orelse return false;
        const maybe_snapshot = surface.core_surface.scrollToRowIfRevision(
            target_row,
            expected_row_space_revision,
        ) catch return false;
        const snapshot = maybe_snapshot orelse return false;
        result.* = .{
            .total = snapshot.total,
            .offset = snapshot.offset,
            .len = snapshot.len,
            .row_space_revision = snapshot.row_space_revision,
        };
        return true;
    }

    const RenderGridStyle = struct {
        id: u32,
        foreground: terminal.color.RGB,
        background: terminal.color.RGB,
        foreground_source: RenderGridColorSource,
        foreground_palette_index: ?u8 = null,
        background_source: RenderGridColorSource,
        background_palette_index: ?u8 = null,
        bold: bool = false,
        faint: bool = false,
        italic: bool = false,
        underline: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        overline: bool = false,

        fn visualEql(self: RenderGridStyle, other: RenderGridStyle) bool {
            return self.foreground.eql(other.foreground) and
                self.background.eql(other.background) and
                self.foreground_source == other.foreground_source and
                self.foreground_palette_index == other.foreground_palette_index and
                self.background_source == other.background_source and
                self.background_palette_index == other.background_palette_index and
                self.bold == other.bold and
                self.faint == other.faint and
                self.italic == other.italic and
                self.underline == other.underline and
                self.blink == other.blink and
                self.inverse == other.inverse and
                self.invisible == other.invisible and
                self.strikethrough == other.strikethrough and
                self.overline == other.overline;
        }
    };

    const RenderGridSpan = struct {
        row: u32,
        column: u32,
        style_id: u32,
        cell_width: u32,
        text: []const u8,
    };

    const RenderGridMode = struct {
        code: u16,
        ansi: bool,
        on: bool,
    };

    /// DEC private mode codes excluded from the render-grid `modes` list:
    /// screen switching and save-cursor (restored via `active_screen`), cursor
    /// visibility/blink (restored via the cursor object), column width (causes
    /// a resize), and transient negotiation/report modes.
    fn renderGridModeIsExcluded(value: u16, ansi: bool) bool {
        if (ansi) return false;
        return switch (value) {
            3, 12, 25, 47, 1047, 1048, 1049, 2026, 2048, 2031 => true,
            else => false,
        };
    }

    const RenderGridSpanBuilder = struct {
        alloc: Allocator,
        spans: *std.ArrayListUnmanaged(RenderGridSpan),
        text: std.Io.Writer.Allocating,
        active: bool = false,
        row: u32 = 0,
        column: u32 = 0,
        style_id: u32 = 0,
        cell_width: u32 = 0,

        fn init(
            alloc: Allocator,
            spans: *std.ArrayListUnmanaged(RenderGridSpan),
        ) RenderGridSpanBuilder {
            return .{
                .alloc = alloc,
                .spans = spans,
                .text = .init(alloc),
            };
        }

        fn deinit(self: *RenderGridSpanBuilder) void {
            self.text.deinit();
        }

        fn ensure(
            self: *RenderGridSpanBuilder,
            row: u32,
            column: u32,
            style_id: u32,
        ) !void {
            if (self.active and
                self.row == row and
                self.style_id == style_id and
                self.column + self.cell_width == column)
            {
                return;
            }

            try self.close();
            self.active = true;
            self.row = row;
            self.column = column;
            self.style_id = style_id;
            self.cell_width = 0;
        }

        fn appendCellWidth(self: *RenderGridSpanBuilder, width: u32) void {
            self.cell_width += width;
        }

        fn close(self: *RenderGridSpanBuilder) !void {
            if (!self.active) return;
            const text = try self.text.toOwnedSlice();
            errdefer self.alloc.free(text);
            try self.spans.append(self.alloc, .{
                .row = self.row,
                .column = self.column,
                .style_id = self.style_id,
                .cell_width = self.cell_width,
                .text = text,
            });
            self.text = .init(self.alloc);
            self.active = false;
            self.cell_width = 0;
        }
    };

    fn renderGridStyleID(
        styles: *std.ArrayListUnmanaged(RenderGridStyle),
        style: RenderGridStyle,
    ) !u32 {
        for (styles.items) |existing| {
            if (existing.visualEql(style)) return existing.id;
        }

        var next = style;
        next.id = @intCast(styles.items.len);
        try styles.append(global.alloc, next);
        return next.id;
    }

    fn resolvedRenderGridStyle(
        p: *const terminal.Page,
        cell: *const terminal.Cell,
        foreground: terminal.color.RGB,
        background: terminal.color.RGB,
        palette: *const terminal.color.Palette,
        bold_color: ?terminal.Style.BoldColor,
    ) RenderGridStyle {
        const style: terminal.Style = if (cell.style_id == terminal_style.default_id)
            .{}
        else
            p.styles.get(p.memory, cell.style_id).*;
        const foreground_semantics = renderGridColorSemantics(style.fg_color);
        const background_semantics: RenderGridColorSemantics = switch (cell.content_tag) {
            .bg_color_palette => .{
                .source = .palette,
                .palette_index = cell.content.color_palette,
            },
            .bg_color_rgb => .{ .source = .rgb },
            else => renderGridColorSemantics(style.bg_color),
        };
        return .{
            .id = 0,
            .foreground = style.fg(.{
                .default = foreground,
                .palette = palette,
                .bold = bold_color,
            }),
            .background = style.bg(cell, palette) orelse background,
            .foreground_source = foreground_semantics.source,
            .foreground_palette_index = foreground_semantics.palette_index,
            .background_source = background_semantics.source,
            .background_palette_index = background_semantics.palette_index,
            .bold = style.flags.bold,
            .faint = style.flags.faint,
            .italic = style.flags.italic,
            .underline = style.flags.underline != .none,
            .blink = style.flags.blink,
            .inverse = style.flags.inverse,
            .invisible = style.flags.invisible,
            .strikethrough = style.flags.strikethrough,
            .overline = style.flags.overline,
        };
    }

    fn renderGridColorSemantics(color: terminal.Style.Color) RenderGridColorSemantics {
        return switch (color) {
            .none => .{ .source = .default_color },
            .palette => |index| .{ .source = .palette, .palette_index = index },
            .rgb => .{ .source = .rgb },
        };
    }

    fn renderGridColorSourceName(source: RenderGridColorSource) []const u8 {
        return switch (source) {
            .default_color => "default",
            .palette => "palette",
            .rgb => "rgb",
        };
    }

    fn appendRenderGridCellText(
        builder: *RenderGridSpanBuilder,
        p: *const terminal.Page,
        cell: *const terminal.Cell,
    ) !void {
        try builder.text.writer.print("{u}", .{cell.codepoint()});
        if (cell.hasGrapheme()) {
            if (p.lookupGrapheme(cell)) |graphemes| {
                for (graphemes) |cp| {
                    try builder.text.writer.print("{u}", .{cp});
                }
            }
        }
    }

    fn renderGridCellNeedsOwnSpan(cell: *const terminal.Cell) bool {
        return cell.gridWidth() != 1 or cell.hasGrapheme();
    }

    fn writeRenderGridColor(
        jw: *std.json.Stringify,
        color: terminal.color.RGB,
    ) !void {
        const digits = "0123456789ABCDEF";
        var buf: [7]u8 = undefined;
        buf[0] = '#';
        buf[1] = digits[@intCast(color.r >> 4)];
        buf[2] = digits[@intCast(color.r & 0x0F)];
        buf[3] = digits[@intCast(color.g >> 4)];
        buf[4] = digits[@intCast(color.g & 0x0F)];
        buf[5] = digits[@intCast(color.b >> 4)];
        buf[6] = digits[@intCast(color.b & 0x0F)];
        try jw.write(buf[0..]);
    }

    fn cursorStyleName(style: terminal.CursorStyle) []const u8 {
        return switch (style) {
            .bar => "bar",
            .block => "block",
            .underline => "underline",
            .block_hollow => "block_hollow",
        };
    }

    fn resolveRenderGridThemeColor(
        value: ?configpkg.Config.TerminalColor,
        foreground: terminal.color.RGB,
        background: terminal.color.RGB,
        fallback: terminal.color.RGB,
    ) terminal.color.RGB {
        const configured = value orelse return fallback;
        return switch (configured) {
            .color => |color| color.toTerminalRGB(),
            .@"cell-foreground" => foreground,
            .@"cell-background" => background,
        };
    }

    fn writeRenderGridSemanticColor(
        jw: *std.json.Stringify,
        field: []const u8,
        value: ?configpkg.Config.TerminalColor,
    ) !void {
        const configured = value orelse return;
        const semantic = switch (configured) {
            .color => return,
            .@"cell-foreground" => "cell-foreground",
            .@"cell-background" => "cell-background",
        };
        try jw.objectField(field);
        try jw.write(semantic);
    }

    fn buildRenderGridJson(
        surface: *Surface,
        surface_id: []const u8,
        state_seq: u64,
        scrollback_lines: usize,
        include_theme: bool,
    ) !String {
        const alloc = global.alloc;
        const core_surface = &surface.core_surface;
        var config_background: terminal.color.RGB = undefined;
        var config_foreground: terminal.color.RGB = undefined;
        var config_cursor_color: ?configpkg.Config.TerminalColor = null;
        var config_cursor_text: ?configpkg.Config.TerminalColor = null;
        var config_selection_background: ?configpkg.Config.TerminalColor = null;
        var config_selection_foreground: ?configpkg.Config.TerminalColor = null;
        var bold_color: ?terminal.Style.BoldColor = null;
        {
            core_surface.renderer.draw_mutex.lock();
            defer core_surface.renderer.draw_mutex.unlock();
            const config = &core_surface.renderer.config;
            config_background = config.background;
            config_foreground = config.foreground;
            if (include_theme) {
                config_cursor_color = config.cursor_color;
                config_cursor_text = config.cursor_text;
                config_selection_background = config.selection_background;
                config_selection_foreground = config.selection_foreground;
            }
            bold_color = config.bold_color;
        }

        var styles: std.ArrayListUnmanaged(RenderGridStyle) = .empty;
        defer styles.deinit(alloc);
        var spans: std.ArrayListUnmanaged(RenderGridSpan) = .empty;
        defer {
            for (spans.items) |span| alloc.free(span.text);
            spans.deinit(alloc);
        }
        var scrollback_spans: std.ArrayListUnmanaged(RenderGridSpan) = .empty;
        defer {
            for (scrollback_spans.items) |span| alloc.free(span.text);
            scrollback_spans.deinit(alloc);
        }
        var modes_out: std.ArrayListUnmanaged(RenderGridMode) = .empty;
        defer modes_out.deinit(alloc);

        var cursor_row: ?u32 = null;
        var cursor_column: u32 = 0;
        var cursor_visible = false;
        var cursor_blinking = false;
        var cursor_style: terminal.CursorStyle = .block;
        var columns: u32 = 0;
        var rows: u32 = 0;
        var is_alternate = false;
        var cursor_color_override: ?terminal.color.RGB = null;
        var effective_background: terminal.color.RGB = undefined;
        var effective_foreground: terminal.color.RGB = undefined;
        var theme_cursor: terminal.color.RGB = undefined;
        var theme_cursor_text: ?terminal.color.RGB = null;
        var theme_selection_background: terminal.color.RGB = undefined;
        var theme_selection_foreground: terminal.color.RGB = undefined;
        var theme_palette: [256]terminal.color.RGB = undefined;
        var config_palette: [256]terminal.color.RGB = undefined;
        var theme_cursor_color_semantic: ?configpkg.Config.TerminalColor = null;
        var theme_cursor_text_semantic: ?configpkg.Config.TerminalColor = null;
        var theme_selection_background_semantic: ?configpkg.Config.TerminalColor = null;
        var theme_selection_foreground_semantic: ?configpkg.Config.TerminalColor = null;
        var scrollback_rows: u32 = 0;

        {
            core_surface.renderer_state.mutex.lock();
            defer core_surface.renderer_state.mutex.unlock();

            const t: *terminal.Terminal = core_surface.renderer_state.terminal;
            const s: *terminal.Screen = t.screens.active;
            const palette = &t.colors.palette.current;
            var background = t.colors.background.get() orelse config_background;
            var foreground = t.colors.foreground.get() orelse config_foreground;
            if (t.modes.get(.reverse_colors)) {
                std.mem.swap(terminal.color.RGB, &background, &foreground);
            }

            columns = @intCast(s.pages.cols);
            rows = @intCast(s.pages.rows);
            cursor_column = @intCast(@min(s.cursor.x, s.pages.cols - 1));
            cursor_visible = t.modes.get(.cursor_visible);
            cursor_blinking = t.modes.get(.cursor_blinking);
            cursor_style = s.cursor.cursor_style;
            is_alternate = t.screens.active_key == .alternate;
            effective_background = background;
            effective_foreground = foreground;
            cursor_color_override = t.colors.cursor.override;
            if (include_theme) {
                theme_cursor = t.colors.cursor.get() orelse resolveRenderGridThemeColor(
                    config_cursor_color,
                    foreground,
                    background,
                    foreground,
                );
                if (config_cursor_text) |cursor_text| {
                    theme_cursor_text = resolveRenderGridThemeColor(
                        cursor_text,
                        foreground,
                        background,
                        background,
                    );
                }
                theme_selection_background = resolveRenderGridThemeColor(
                    config_selection_background,
                    foreground,
                    background,
                    foreground,
                );
                theme_selection_foreground = resolveRenderGridThemeColor(
                    config_selection_foreground,
                    foreground,
                    background,
                    background,
                );
                @memcpy(&theme_palette, palette[0..theme_palette.len]);
                @memcpy(&config_palette, t.colors.palette.original[0..config_palette.len]);
                if (cursor_color_override == null) theme_cursor_color_semantic = config_cursor_color;
                theme_cursor_text_semantic = config_cursor_text;
                theme_selection_background_semantic = config_selection_background;
                theme_selection_foreground_semantic = config_selection_foreground;
            }

            // Capture every non-default-handled DEC/ANSI mode so the client can
            // restore mouse tracking, bracketed paste, application keys, origin,
            // autowrap, etc. exactly.
            inline for (@typeInfo(terminal.modes.Mode).@"enum".fields) |field| {
                const mode: terminal.modes.Mode = @enumFromInt(field.value);
                const tag = terminal.modes.ModeTag.fromMode(mode);
                if (!renderGridModeIsExcluded(tag.value, tag.ansi)) {
                    try modes_out.append(alloc, .{
                        .code = tag.value,
                        .ansi = tag.ansi,
                        .on = t.modes.get(mode),
                    });
                }
            }

            const default_style: RenderGridStyle = .{
                .id = 0,
                .foreground = foreground,
                .background = background,
                .foreground_source = .default_color,
                .background_source = .default_color,
            };
            try styles.append(alloc, default_style);

            var vp_builder = RenderGridSpanBuilder.init(alloc, &spans);
            defer vp_builder.deinit();
            var sb_builder = RenderGridSpanBuilder.init(alloc, &scrollback_spans);
            defer sb_builder.deinit();

            // Iterate the (bounded) scrollback above the viewport plus the
            // viewport itself in one pass. The alternate screen has no
            // scrollback, so `up` clamps to the viewport top and no scrollback
            // rows are emitted.
            const vp_top = s.pages.getTopLeft(.viewport);
            const start = if (scrollback_lines == 0)
                vp_top
            else
                (vp_top.up(scrollback_lines) orelse s.pages.getTopLeft(.screen));
            const vp_bottom = s.pages.getBottomRight(.viewport) orelse vp_top;

            var row_it = start.rowIterator(.right_down, vp_bottom);
            var vp_y: u32 = 0;
            var sb_y: u32 = 0;
            var in_viewport = false;
            var preserved_node: ?*terminal.PageList.List.Node = null;
            var preserved_page: ?terminal.PageList.List.Node.PreservedPage = null;
            defer if (preserved_page) |*page_| page_.deinit();
            while (row_it.next()) |row_pin| {
                if (!in_viewport and row_pin.eql(vp_top)) in_viewport = true;
                const builder = if (in_viewport) &vp_builder else &sb_builder;
                const out_row = if (in_viewport) vp_y else sb_y;

                if (in_viewport and cursor_row == null and
                    row_pin.node == s.cursor.page_pin.node and
                    row_pin.y == s.cursor.page_pin.y)
                {
                    cursor_row = vp_y;
                }

                // Render-grid snapshots must not make compressed scrollback
                // resident again. Decode each compressed node once into a
                // temporary page and reuse it for every row from that node.
                if (preserved_node != row_pin.node) {
                    const next_page = try row_pin.node.pagePreservingState(alloc);
                    if (preserved_page) |*page_| page_.deinit();
                    preserved_page = next_page;
                    preserved_node = row_pin.node;
                }
                const p = if (preserved_page) |*page_| page_.page() else unreachable;
                const page_rac = p.getRowAndCell(row_pin.x, row_pin.y);
                const page_cells: []const terminal.Cell = p.getCells(page_rac.row);
                for (page_cells, 0..) |*cell, x| {
                    if (cell.wide == .spacer_tail) {
                        continue;
                    }

                    const style = resolvedRenderGridStyle(
                        p,
                        cell,
                        foreground,
                        background,
                        palette,
                        bold_color,
                    );
                    const has_text = cell.hasText();
                    const style_id = try renderGridStyleID(&styles, style);
                    const is_default_blank = !has_text and style_id == 0;
                    if (is_default_blank) {
                        try builder.close();
                        continue;
                    }

                    const owns_span = has_text and renderGridCellNeedsOwnSpan(cell);
                    if (owns_span) try builder.close();
                    try builder.ensure(out_row, @intCast(x), style_id);
                    if (has_text) {
                        try appendRenderGridCellText(builder, p, cell);
                        builder.appendCellWidth(@intCast(cell.gridWidth()));
                    } else {
                        try builder.text.writer.writeByte(' ');
                        builder.appendCellWidth(1);
                    }
                    if (owns_span) try builder.close();
                }
                try builder.close();
                if (in_viewport) {
                    vp_y += 1;
                } else {
                    sb_y += 1;
                }
            }
            try vp_builder.close();
            try sb_builder.close();
            scrollback_rows = sb_y;
        }

        var buf: std.Io.Writer.Allocating = .init(alloc);
        errdefer buf.deinit();
        var jw: std.json.Stringify = .{ .writer = &buf.writer };
        try jw.beginObject();

        try jw.objectField("format");
        try jw.write("cmux.render-grid.v1");
        try jw.objectField("surface_id");
        try jw.write(surface_id);
        try jw.objectField("state_seq");
        try jw.write(state_seq);
        try jw.objectField("columns");
        try jw.write(columns);
        try jw.objectField("rows");
        try jw.write(rows);
        try jw.objectField("full");
        try jw.write(true);

        try jw.objectField("cursor");
        try jw.beginObject();
        try jw.objectField("row");
        try jw.write(cursor_row orelse 0);
        try jw.objectField("column");
        try jw.write(cursor_column);
        try jw.objectField("visible");
        try jw.write(cursor_visible and cursor_row != null);
        try jw.objectField("style");
        try jw.write(cursorStyleName(cursor_style));
        try jw.objectField("blinking");
        try jw.write(cursor_blinking);
        try jw.endObject();

        try jw.objectField("styles");
        try jw.beginArray();
        for (styles.items) |style| {
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(style.id);
            try jw.objectField("foreground");
            try writeRenderGridColor(&jw, style.foreground);
            try jw.objectField("background");
            try writeRenderGridColor(&jw, style.background);
            try jw.objectField("foreground_source");
            try jw.write(renderGridColorSourceName(style.foreground_source));
            if (style.foreground_palette_index) |index| {
                try jw.objectField("foreground_palette_index");
                try jw.write(index);
            }
            try jw.objectField("background_source");
            try jw.write(renderGridColorSourceName(style.background_source));
            if (style.background_palette_index) |index| {
                try jw.objectField("background_palette_index");
                try jw.write(index);
            }
            try jw.objectField("bold");
            try jw.write(style.bold);
            try jw.objectField("faint");
            try jw.write(style.faint);
            try jw.objectField("italic");
            try jw.write(style.italic);
            try jw.objectField("underline");
            try jw.write(style.underline);
            try jw.objectField("blink");
            try jw.write(style.blink);
            try jw.objectField("inverse");
            try jw.write(style.inverse);
            try jw.objectField("invisible");
            try jw.write(style.invisible);
            try jw.objectField("strikethrough");
            try jw.write(style.strikethrough);
            try jw.objectField("overline");
            try jw.write(style.overline);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("row_spans");
        try jw.beginArray();
        for (spans.items) |span| {
            try jw.beginObject();
            try jw.objectField("row");
            try jw.write(span.row);
            try jw.objectField("column");
            try jw.write(span.column);
            try jw.objectField("style_id");
            try jw.write(span.style_id);
            try jw.objectField("cell_width");
            try jw.write(span.cell_width);
            try jw.objectField("text");
            try jw.write(span.text);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("active_screen");
        try jw.write(if (is_alternate) "alternate" else "primary");

        if (include_theme) {
            try jw.objectField("terminal_config_theme");
            try jw.beginObject();
            try jw.objectField("background");
            try writeRenderGridColor(&jw, config_background);
            try jw.objectField("foreground");
            try writeRenderGridColor(&jw, config_foreground);
            try jw.objectField("cursor");
            try writeRenderGridColor(
                &jw,
                resolveRenderGridThemeColor(
                    config_cursor_color,
                    config_foreground,
                    config_background,
                    config_foreground,
                ),
            );
            try writeRenderGridSemanticColor(&jw, "cursorColorSemantic", config_cursor_color);
            if (config_cursor_text) |cursor_text| {
                try jw.objectField("cursorText");
                try writeRenderGridColor(
                    &jw,
                    resolveRenderGridThemeColor(
                        cursor_text,
                        config_foreground,
                        config_background,
                        config_background,
                    ),
                );
            }
            try writeRenderGridSemanticColor(&jw, "cursorTextSemantic", config_cursor_text);
            try jw.objectField("selectionBackground");
            try writeRenderGridColor(
                &jw,
                resolveRenderGridThemeColor(
                    config_selection_background,
                    config_foreground,
                    config_background,
                    config_foreground,
                ),
            );
            try writeRenderGridSemanticColor(
                &jw,
                "selectionBackgroundSemantic",
                config_selection_background,
            );
            try jw.objectField("selectionForeground");
            try writeRenderGridColor(
                &jw,
                resolveRenderGridThemeColor(
                    config_selection_foreground,
                    config_foreground,
                    config_background,
                    config_background,
                ),
            );
            try writeRenderGridSemanticColor(
                &jw,
                "selectionForegroundSemantic",
                config_selection_foreground,
            );
            try jw.objectField("palette");
            try jw.beginArray();
            for (config_palette) |color| try writeRenderGridColor(&jw, color);
            try jw.endArray();
            try jw.endObject();

            try jw.objectField("terminal_theme");
            try jw.beginObject();
            try jw.objectField("background");
            try writeRenderGridColor(&jw, effective_background);
            try jw.objectField("foreground");
            try writeRenderGridColor(&jw, effective_foreground);
            try jw.objectField("cursor");
            try writeRenderGridColor(&jw, theme_cursor);
            try writeRenderGridSemanticColor(&jw, "cursorColorSemantic", theme_cursor_color_semantic);
            if (theme_cursor_text) |cursor_text| {
                try jw.objectField("cursorText");
                try writeRenderGridColor(&jw, cursor_text);
            }
            try writeRenderGridSemanticColor(&jw, "cursorTextSemantic", theme_cursor_text_semantic);
            try jw.objectField("selectionBackground");
            try writeRenderGridColor(&jw, theme_selection_background);
            try writeRenderGridSemanticColor(
                &jw,
                "selectionBackgroundSemantic",
                theme_selection_background_semantic,
            );
            try jw.objectField("selectionForeground");
            try writeRenderGridColor(&jw, theme_selection_foreground);
            try writeRenderGridSemanticColor(
                &jw,
                "selectionForegroundSemantic",
                theme_selection_foreground_semantic,
            );
            try jw.objectField("palette");
            try jw.beginArray();
            for (theme_palette) |color| try writeRenderGridColor(&jw, color);
            try jw.endArray();
            try jw.endObject();
        }

        // Always export the small effective default colors. These include OSC
        // overrides and DECSCNM reverse-video, so clients can keep chrome in sync
        // without requesting the full 256-color terminal_theme on every tick.
        try jw.objectField("terminal_foreground");
        try writeRenderGridColor(&jw, effective_foreground);
        try jw.objectField("terminal_background");
        try writeRenderGridColor(&jw, effective_background);
        if (cursor_color_override) |c| {
            try jw.objectField("terminal_cursor_color");
            try writeRenderGridColor(&jw, c);
        }

        try jw.objectField("modes");
        try jw.beginArray();
        for (modes_out.items) |mode| {
            try jw.beginObject();
            try jw.objectField("code");
            try jw.write(mode.code);
            try jw.objectField("ansi");
            try jw.write(mode.ansi);
            try jw.objectField("on");
            try jw.write(mode.on);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.objectField("scrollback_rows");
        try jw.write(scrollback_rows);

        try jw.objectField("scrollback_spans");
        try jw.beginArray();
        for (scrollback_spans.items) |span| {
            try jw.beginObject();
            try jw.objectField("row");
            try jw.write(span.row);
            try jw.objectField("column");
            try jw.write(span.column);
            try jw.objectField("style_id");
            try jw.write(span.style_id);
            try jw.objectField("cell_width");
            try jw.write(span.cell_width);
            try jw.objectField("text");
            try jw.write(span.text);
            try jw.endObject();
        }
        try jw.endArray();

        try jw.endObject();
        return .fromSlice(try buf.toOwnedSlice());
    }

    /// Export the Ghostty grid as cmux mobile render-grid JSON: the visible
    /// viewport plus full restore state (active screen, DEC/ANSI modes, dynamic
    /// colors, cursor) and up to `scrollback_lines` rows of scrollback history.
    /// This reads the terminal page grid directly instead of consuming renderer
    /// dirty state, so it does not interfere with desktop drawing.
    export fn ghostty_surface_render_grid_json(
        surface: *Surface,
        surface_id_ptr: [*]const u8,
        surface_id_len: usize,
        state_seq: u64,
        scrollback_lines: usize,
    ) String {
        return buildRenderGridJson(
            surface,
            surface_id_ptr[0..surface_id_len],
            state_seq,
            scrollback_lines,
            false,
        ) catch |err| {
            log.warn("error exporting render grid err={}", .{err});
            return .empty;
        };
    }

    export fn ghostty_surface_render_grid_json_with_theme(
        surface: *Surface,
        surface_id_ptr: [*]const u8,
        surface_id_len: usize,
        state_seq: u64,
        scrollback_lines: usize,
        include_theme: bool,
    ) String {
        return buildRenderGridJson(
            surface,
            surface_id_ptr[0..surface_id_len],
            state_seq,
            scrollback_lines,
            include_theme,
        ) catch |err| {
            log.warn("error exporting render grid err={}", .{err});
            return .empty;
        };
    }

    /// Returns the PID of the foreground process for the surface PTY.
    export fn ghostty_surface_foreground_pid(surface: *Surface) u64 {
        return surface.core_surface.getProcessInfo(.foreground_pid) orelse 0;
    }

    /// Returns the PTY name for the surface. The returned string must be
    /// freed by the caller via ghostty_string_free.
    export fn ghostty_surface_tty_name(surface: *Surface) String {
        const tty_name = surface.core_surface.getProcessInfo(.tty_name) orelse return .empty;
        const copy = surface.app.core_app.alloc.dupeZ(u8, tty_name) catch |err| {
            log.err("error allocating tty name err={}", .{err});
            return .empty;
        };

        return .fromSlice(copy);
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface: *Surface, scheme_raw: c_int) void {
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return;
        };

        surface.colorSchemeCallback(scheme);
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface: *Surface, x: f64, y: f64) void {
        surface.updateContentScale(x, y);
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface: *Surface, focused: bool) void {
        surface.focusCallback(focused);
    }

    /// Update the occlusion state of a surface.
    export fn ghostty_surface_set_occlusion(surface: *Surface, visible: bool) void {
        surface.occlusionCallback(visible);
    }

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface: *Surface,
        mods_raw: c_int,
    ) c_int {
        const mods: input.Mods = @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(mods_raw))),
        ));
        const result = mods.translation(
            surface.core_surface.config.macos_option_as_alt orelse
                surface.app.keyboardLayout().detectOptionAsAlt(),
        );
        return @intCast(@as(input.Mods.Backing, @bitCast(result)));
    }

    /// Send this for raw keypresses (i.e. the keyDown event on macOS).
    /// This will handle the keymap translation and send the appropriate
    /// key and char events.
    export fn ghostty_surface_key(
        surface: *Surface,
        event: KeyEvent,
    ) bool {
        return surface.app.keyEvent(
            .{ .surface = surface },
            event.keyEvent(),
        ) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_surface_key_is_binding(
        surface: *Surface,
        event: KeyEvent,
        c_flags: ?*input.Binding.Flags.C,
    ) bool {
        const core_event = event.keyEvent().core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        const flags = surface.core_surface.keyEventIsBinding(
            core_event,
        ) orelse return false;
        if (c_flags) |ptr| ptr.* = flags.cval();
        return true;
    }

    /// Send raw text to the terminal. This is treated like a paste
    /// so this isn't useful for sending escape sequences. For that,
    /// individual key input should be used.
    export fn ghostty_surface_text(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textCallback(ptr[0..len]);
    }

    /// Send committed text input to the terminal. This is treated like
    /// typed text, not a paste. Newlines are normalized to carriage
    /// returns and bracketed paste mode is not used.
    export fn ghostty_surface_text_input(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.textInputCallback(ptr[0..len]);
    }

    /// Set the preedit text for the surface. This is used for IME
    /// composition. If the length is 0, then the preedit text is cleared.
    export fn ghostty_surface_preedit(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        surface.preeditCallback(if (len == 0) null else ptr[0..len]);
    }

    /// Process output bytes as if they were read from the PTY.
    export fn ghostty_surface_process_output(
        surface: *Surface,
        ptr: [*]const u8,
        len: usize,
    ) void {
        if (len == 0) return;
        surface.core_surface.io.processOutput(ptr[0..len]);
    }

    /// Install a callback that fires on every PTY-output byte slice
    /// before the VT parser sees it. Pass `cb = null` to clear.
    ///
    /// The callback runs on the IO read thread (or whoever calls
    /// `ghostty_surface_process_output`). The embedder owns thread
    /// safety for any cross-thread hand-off; the typical pattern is a
    /// non-blocking memcpy into a ring buffer + an async wakeup.
    ///
    /// userdata is opaque to libghostty; the embedder owns its lifetime
    /// (usually tied to the surface).
    ///
    /// cmux fork: the Mac sync server uses this to broadcast raw PTY
    /// bytes to paired iPhones so the phone can feed identical bytes
    /// into its own libghostty surface, producing a byte-for-byte
    /// matching grid. Upstream candidate.
    export fn ghostty_surface_set_pty_tee_cb(
        surface: *Surface,
        cb: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
        userdata: ?*anyopaque,
    ) void {
        surface.core_surface.io.pty_tee_cb = cb;
        surface.core_surface.io.pty_tee_userdata = userdata;
    }

    /// Returns true if the surface currently has mouse capturing
    /// enabled.
    export fn ghostty_surface_mouse_captured(surface: *Surface) bool {
        return surface.core_surface.mouseCaptured();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) bool {
        return surface.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface: *Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) void {
        surface.cursorPosCallback(
            x,
            y,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface: *Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        surface.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface: *Surface,
        stage_raw: u32,
        pressure: f64,
    ) void {
        const stage = std.meta.intToEnum(
            input.MousePressureStage,
            stage_raw,
        ) catch {
            log.warn(
                "invalid mouse pressure stage value={}",
                .{stage_raw},
            );
            return;
        };

        surface.mousePressureCallback(stage, pressure);
    }

    export fn ghostty_surface_ime_point(
        surface: *Surface,
        x: *f64,
        y: *f64,
        width: *f64,
        height: *f64,
    ) void {
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
        width.* = pos.width;
        height.* = pos.height;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr: *Surface) void {
        ptr.core_surface.close();
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr: *Surface, direction: apprt.action.SplitDirection) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr: *Surface,
        direction: apprt.action.GotoSplit,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr: *Surface,
        direction: apprt.action.ResizeSplit.Direction,
        amount: u16,
    ) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr: *Surface) void {
        _ = ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr: *Surface,
        action_ptr: [*]const u8,
        action_len: usize,
    ) bool {
        const action_str = action_ptr[0..action_len];
        const action = input.Binding.Action.parse(action_str) catch |err| {
            log.err("error parsing binding action action={s} err={}", .{ action_str, err });
            return false;
        };

        return ptr.core_surface.performBindingAction(action) catch |err| {
            log.err("error performing binding action action={f} err={}", .{ action, err });
            return false;
        };
    }

    /// Complete a clipboard read request started via the read callback.
    /// This can only be called once for a given request. Once it is called
    /// with a request the request pointer will be invalidated.
    export fn ghostty_surface_complete_clipboard_request(
        ptr: *Surface,
        str: [*:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        ptr.completeClipboardRequest(
            std.mem.sliceTo(str, 0),
            state,
            confirmed,
        );
    }

    export fn ghostty_surface_inspector(ptr: *Surface) ?*Inspector {
        return ptr.initInspector() catch |err| {
            log.err("error initializing inspector err={}", .{err});
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr: *Surface) void {
        ptr.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr: *Inspector, w: u32, h: u32) void {
        ptr.updateSize(w, h);
    }

    export fn ghostty_inspector_set_content_scale(ptr: *Inspector, x: f64, y: f64) void {
        ptr.updateContentScale(x, y);
    }

    export fn ghostty_inspector_mouse_button(
        ptr: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: c_int,
    ) void {
        ptr.mouseButtonCallback(
            action,
            button,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(mods))),
            )),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr: *Inspector, x: f64, y: f64) void {
        ptr.cursorPosCallback(x, y);
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr: *Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) void {
        ptr.scrollCallback(
            x,
            y,
            @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(scroll_mods))))),
        );
    }

    export fn ghostty_inspector_key(
        ptr: *Inspector,
        action: input.Action,
        key: input.Key,
        c_mods: c_int,
    ) void {
        ptr.keyCallback(
            action,
            key,
            @bitCast(@as(
                input.Mods.Backing,
                @truncate(@as(c_uint, @bitCast(c_mods))),
            )),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return;
        };
    }

    export fn ghostty_inspector_text(
        ptr: *Inspector,
        str: [*:0]const u8,
    ) void {
        ptr.textCallback(std.mem.sliceTo(str, 0));
    }

    export fn ghostty_inspector_set_focus(ptr: *Inspector, focused: bool) void {
        ptr.focusCallback(focused);
    }

    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@"background-opacity" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel("windowNumber"), .{}),
            @intCast(config.@"background-blur".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern "c" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern "c" fn CGSDefaultConnectionForThread() *anyopaque;

    // Darwin-only C APIs.
    const Darwin = struct {
        export fn ghostty_surface_set_display_id(ptr: *Surface, display_id: u32) void {
            const surface = &ptr.core_surface;
            _ = surface.renderer_thread.mailbox.push(
                .{ .macos_display_id = display_id },
                .{ .forever = {} },
            );
            surface.renderer_thread.wakeup.notify() catch {};
        }

        /// cmux fork: release (realized=false) or recreate (realized=true) the
        /// renderer's GPU resources (Metal swap chain / IOSurface) for a surface
        /// without freeing the surface itself. Lets cmux reclaim the ~40MB
        /// IOSurface of an occluded terminal while keeping its PTY/io thread and
        /// terminal state alive; the swap chain is rebuilt on re-show.
        ///
        /// Darwin-only by placement: iOS owns occlusion via `renderingSuspended`
        /// and must not be driven through this path. The message is
        /// non-idempotent (it must strictly alternate with the swap chain's
        /// `defunct` state), so the caller (cmux) must only advance its own
        /// realize/unrealize state when this returns `true`. The push is
        /// `.instant` (non-blocking): this runs on the caller's main actor and
        /// must never stall the UI waiting on the renderer thread to drain. When
        /// the mailbox is full the push drops and returns `false`; cmux keeps its
        /// mirror state unchanged and retries on its next reclamation pass, so a
        /// drop is harmless rather than tripping `displayRealized`'s
        /// `assert(swap_chain.defunct)`. On re-show the mailbox is normally empty,
        /// so the realize enqueues immediately and the surface is never presented
        /// against a defunct swap chain.
        export fn ghostty_surface_set_renderer_realized(ptr: *Surface, realized: bool) bool {
            const surface = &ptr.core_surface;
            const enqueued = surface.renderer_thread.mailbox.push(
                .{ .display_realized = realized },
                .{ .instant = {} },
            ) != 0;
            surface.renderer_thread.wakeup.notify() catch {};
            return enqueued;
        }

        /// This returns a CTFontRef that should be used for quicklook
        /// highlighted text. This is always the primary font in use
        /// regardless of the selected text. If coretext is not in use
        /// then this will return nothing.
        export fn ghostty_surface_quicklook_font(ptr: *Surface) ?*anyopaque {
            // For non-CoreText we just return null.
            if (comptime font.options.backend != .coretext) {
                return null;
            }

            // We'll need content scale so fail early if we can't get it.
            const content_scale = ptr.getContentScale() catch return null;

            // Get the shared font grid. We acquire a read lock to
            // read the font face. It should not be deferred since
            // we're loading the primary face.
            const grid = ptr.core_surface.renderer.font_grid;
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const collection = &grid.resolver.collection;
            const face = collection.getFace(.{}) catch return null;

            // We need to unscale the content scale. We apply the
            // content scale to our font stack because we are rendering
            // at 1x but callers of this should be using scaled or apply
            // scale themselves.
            const size: f32 = size: {
                const num = face.font.copyAttribute(.size) orelse
                    break :size 12;
                defer num.release();
                var v: f32 = 12;
                _ = num.getValue(.float, &v);
                break :size v;
            };

            const copy = face.font.copyWithAttributes(
                size / content_scale.y,
                null,
                null,
            ) catch return null;

            return copy;
        }

        /// This returns the selected word for quicklook. This will populate
        /// the buffer with the word under the cursor and the selection
        /// info so that quicklook can be rendered.
        ///
        /// This does not modify the selection active on the surface (if any).
        export fn ghostty_surface_quicklook_word(
            ptr: *Surface,
            result: *Text,
        ) bool {
            const surface = &ptr.core_surface;
            surface.renderer_state.mutex.lock();
            defer surface.renderer_state.mutex.unlock();

            // Get our word selection
            const sel = sel: {
                const screen: *terminal.Screen = surface.renderer_state.terminal.screens.active;
                const pos = try ptr.getCursorPos();
                const pt_viewport = surface.posToViewport(pos.x, pos.y);
                const pin = screen.pages.pin(.{
                    .viewport = .{
                        .x = pt_viewport.x,
                        .y = pt_viewport.y,
                    },
                }) orelse {
                    if (comptime std.debug.runtime_safety) unreachable;
                    return false;
                };
                break :sel surface.io.terminal.screens.active.selectWord(
                    pin,
                    surface.config.selection_word_chars,
                ) orelse return false;
            };

            // Read the selection
            return readTextLocked(ptr, sel, result);
        }

        export fn ghostty_inspector_metal_init(ptr: *Inspector, device: objc.c.id) bool {
            return ptr.initMetal(.fromId(device));
        }

        export fn ghostty_inspector_metal_render(
            ptr: *Inspector,
            command_buffer: objc.c.id,
            descriptor: objc.c.id,
        ) void {
            return ptr.renderMetal(
                .fromId(command_buffer),
                .fromId(descriptor),
            ) catch |err| {
                log.err("error rendering inspector err={}", .{err});
                return;
            };
        }

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) void {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
        }
    };
};

test "output sequence publishes only with successful VT tail snapshot" {
    var next_sequence: u64 = 99;
    try std.testing.expect(!CAPI.publishOutputSnapshotSequenceLocked(
        false,
        42,
        &next_sequence,
    ));
    try std.testing.expectEqual(@as(u64, 99), next_sequence);

    try std.testing.expect(CAPI.publishOutputSnapshotSequenceLocked(
        true,
        42,
        &next_sequence,
    ));
    try std.testing.expectEqual(@as(u64, 42), next_sequence);
}

test "render grid preserves terminal color semantics" {
    const default_color = CAPI.renderGridColorSemantics(.none);
    try std.testing.expectEqual(CAPI.RenderGridColorSource.default_color, default_color.source);
    try std.testing.expectEqual(@as(?u8, null), default_color.palette_index);

    const palette = CAPI.renderGridColorSemantics(.{ .palette = 42 });
    try std.testing.expectEqual(CAPI.RenderGridColorSource.palette, palette.source);
    try std.testing.expectEqual(@as(?u8, 42), palette.palette_index);

    const rgb = CAPI.renderGridColorSemantics(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } });
    try std.testing.expectEqual(CAPI.RenderGridColorSource.rgb, rgb.source);
    try std.testing.expectEqual(@as(?u8, null), rgb.palette_index);
}
