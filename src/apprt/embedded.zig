//! Application runtime for the embedded version of Ghostty. The embedded
//! version is when Ghostty is embedded within a parent host application,
//! rather than owning the application lifecycle itself. This is used for
//! example for the macOS build of Ghostty so that we can use a native
//! Swift+XCode-based application.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const build_config = @import("../build_config.zig");
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

const libc = if (builtin.target.os.tag == .linux) struct {
    extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;
} else struct {};

pub const resourcesDir = internal_os.resourcesDir;

const embedded_runtime_tests = builtin.is_test and apprt.runtime == apprt.embedded;
const max_surface_env_vars = 4096;
const embedding_abi_version = 15;
const max_surface_initial_output_bytes = 1024 * 1024;
const max_surface_scrollback_read_bytes = 1024 * 1024;

pub const RuntimeClipboardContent = extern struct {
    mime: [*:0]const u8,
    data: [*:0]const u8,
};

/// Because we only expect the embedding API to be used in embedded
/// environments, the options are extern so that we can expose it
/// directly to a C callconv and not pay for any translation costs.
///
/// C type: ghostty_runtime_config_s
pub const RuntimeOptions = extern struct {
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
    wakeup: if (builtin.target.os.tag == .linux)
        ?*const fn (AppUD) callconv(.c) void
    else
        *const fn (AppUD) callconv(.c) void = if (builtin.target.os.tag == .linux) null else undefined,

    /// Callback called to handle an action.
    action: if (builtin.target.os.tag == .linux)
        ?*const fn (?*anyopaque, apprt.Target.C, apprt.Action.C) callconv(.c) bool
    else
        *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool = if (builtin.target.os.tag == .linux) null else undefined,

    /// Read the clipboard value. Returns true if the clipboard request
    /// was started and complete_clipboard_request may be called with the
    /// given state pointer. Returns false if the clipboard request couldn't
    /// be started (such as when no text is available for a paste request).
    read_clipboard: if (builtin.target.os.tag == .linux)
        ?*const fn (SurfaceUD, c_int, ?*anyopaque) callconv(.c) bool
    else
        *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) bool = if (builtin.target.os.tag == .linux) null else undefined,

    /// This may be called after a read clipboard call to request
    /// confirmation that the clipboard value is safe to read. The embedder
    /// must call complete_clipboard_request with the given request.
    confirm_read_clipboard: if (builtin.target.os.tag == .linux)
        ?*const fn (SurfaceUD, [*c]const u8, ?*anyopaque, c_int) callconv(.c) void
    else
        *const fn (SurfaceUD, [*:0]const u8, *apprt.ClipboardRequest, apprt.ClipboardRequestType) callconv(.c) void = if (builtin.target.os.tag == .linux) null else undefined,

    /// Write the clipboard value.
    write_clipboard: if (builtin.target.os.tag == .linux)
        ?*const fn (SurfaceUD, c_int, [*c]const RuntimeClipboardContent, usize, bool) callconv(.c) void
    else
        *const fn (SurfaceUD, c_int, [*]const CAPI.ClipboardContent, usize, bool) callconv(.c) void = if (builtin.target.os.tag == .linux) null else undefined,

    /// Close the current surface given by this function.
    close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void = null,

    /// Request that the host redraw the current surface on its app thread.
    /// Required for Linux embedders because GLArea-style contexts must be
    /// painted by the host application thread.
    redraw_surface: if (builtin.target.os.tag == .linux)
        ?*const fn (SurfaceUD) callconv(.c) void
    else
        void = if (builtin.target.os.tag == .linux) null else {},

    /// Report read-only tmux control-mode state for the surface on the native
    /// embedded runtime. This shares the final ABI slot with Linux redraw.
    tmux_control: if (builtin.target.os.tag == .linux)
        void
    else
        ?*const fn (SurfaceUD, apprt.surface.Message.TmuxControlMsg.Event, u32, [*]const u8, usize) callconv(.c) void = if (builtin.target.os.tag == .linux)
    {} else null,
};

const ValidatedRuntimeOptions = struct {
    const AppUD = RuntimeOptions.AppUD;
    const SurfaceUD = RuntimeOptions.SurfaceUD;

    userdata: AppUD,
    supports_selection_clipboard: bool,
    wakeup: *const fn (AppUD) callconv(.c) void,
    action: if (builtin.target.os.tag == .linux)
        *const fn (?*anyopaque, apprt.Target.C, apprt.Action.C) callconv(.c) bool
    else
        *const fn (*App, apprt.Target.C, apprt.Action.C) callconv(.c) bool,
    read_clipboard: if (builtin.target.os.tag == .linux)
        *const fn (SurfaceUD, c_int, ?*anyopaque) callconv(.c) bool
    else
        *const fn (SurfaceUD, c_int, *apprt.ClipboardRequest) callconv(.c) bool,
    confirm_read_clipboard: if (builtin.target.os.tag == .linux)
        *const fn (SurfaceUD, [*c]const u8, ?*anyopaque, c_int) callconv(.c) void
    else
        *const fn (SurfaceUD, [*:0]const u8, *apprt.ClipboardRequest, apprt.ClipboardRequestType) callconv(.c) void,
    write_clipboard: if (builtin.target.os.tag == .linux)
        *const fn (SurfaceUD, c_int, [*c]const RuntimeClipboardContent, usize, bool) callconv(.c) void
    else
        *const fn (SurfaceUD, c_int, [*]const CAPI.ClipboardContent, usize, bool) callconv(.c) void,
    close_surface: ?*const fn (SurfaceUD, bool) callconv(.c) void,
    redraw_surface: if (builtin.target.os.tag == .linux)
        ?*const fn (SurfaceUD) callconv(.c) void
    else
        void,
    tmux_control: if (builtin.target.os.tag == .linux)
        void
    else
        ?*const fn (SurfaceUD, apprt.surface.Message.TmuxControlMsg.Event, u32, [*]const u8, usize) callconv(.c) void,

    fn init(opts: RuntimeOptions) !ValidatedRuntimeOptions {
        if (comptime builtin.target.os.tag == .linux) {
            return .{
                .userdata = opts.userdata,
                .supports_selection_clipboard = opts.supports_selection_clipboard,
                .wakeup = opts.wakeup orelse return error.RuntimeWakeupMustBeSet,
                .action = opts.action orelse return error.RuntimeActionMustBeSet,
                .read_clipboard = opts.read_clipboard orelse return error.RuntimeReadClipboardMustBeSet,
                .confirm_read_clipboard = opts.confirm_read_clipboard orelse return error.RuntimeConfirmReadClipboardMustBeSet,
                .write_clipboard = opts.write_clipboard orelse return error.RuntimeWriteClipboardMustBeSet,
                .close_surface = opts.close_surface,
                .redraw_surface = try validateRedrawSurfaceCallback(opts.redraw_surface),
                .tmux_control = {},
            };
        }

        return .{
            .userdata = opts.userdata,
            .supports_selection_clipboard = opts.supports_selection_clipboard,
            .wakeup = opts.wakeup,
            .action = opts.action,
            .read_clipboard = opts.read_clipboard,
            .confirm_read_clipboard = opts.confirm_read_clipboard,
            .write_clipboard = opts.write_clipboard,
            .close_surface = opts.close_surface,
            .redraw_surface = {},
            .tmux_control = opts.tmux_control,
        };
    }

    fn validateRedrawSurfaceCallback(
        callback: ?*const fn (SurfaceUD) callconv(.c) void,
    ) !?*const fn (SurfaceUD) callconv(.c) void {
        if (comptime builtin.target.os.tag == .linux) {
            return callback orelse error.RuntimeRedrawSurfaceMustBeSet;
        }

        return callback;
    }
};

pub const App = struct {
    /// Linux OpenGL embedders commonly host us in GTK GLArea-style contexts
    /// that must be painted from the host application thread.
    pub const must_draw_from_app_thread = builtin.target.os.tag == .linux;

    /// Marker for synthesized physical keys in the C API keycode field.
    pub const keycode_physical_key_flag: u32 = 0x8000_0000;
    pub const keycode_native_mask: u32 = 0x7fff_ffff;

    pub const Options = RuntimeOptions;

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

            // Build our final key event
            return .{
                .action = self.action,
                .key = self.physicalKey(),
                .mods = self.mods,
                .consumed_mods = self.consumed_mods,
                .composing = self.composing,
                .utf8 = text,
                .unshifted_codepoint = unshifted_codepoint,
            };
        }

        fn physicalKey(self: KeyEvent) input.Key {
            if (self.keycode & keycode_physical_key_flag != 0) {
                const key_raw = std.math.cast(
                    c_int,
                    self.keycode & keycode_native_mask,
                ) orelse return .unidentified;
                return std.meta.intToEnum(input.Key, key_raw) catch .unidentified;
            }

            // We want to get the physical unmapped key to process keybinds.
            return keycode: for (input.keycodes.entries) |entry| {
                if (entry.native == self.keycode) break :keycode entry.key;
            } else .unidentified;
        }
    };

    core_app: *CoreApp,
    opts: ValidatedRuntimeOptions,
    keymap: input.Keymap,

    /// Set before app teardown starts. Runtime callbacks may reenter the C API
    /// while surfaces are being drained, and must not repopulate that registry.
    destroying: std.atomic.Value(bool) = .init(false),

    /// The configuration for the app. This is owned by this structure.
    config: Config,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        const validated_opts = try ValidatedRuntimeOptions.init(opts);

        // We have to clone the config.
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        var keymap = try input.Keymap.init();
        errdefer keymap.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = validated_opts,
            .keymap = keymap,
            .destroying = .init(false),
        };
    }

    fn beginDestroy(self: *App) bool {
        return !self.destroying.swap(true, .acq_rel);
    }

    fn isDestroying(self: *const App) bool {
        return self.destroying.load(.acquire);
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
        if (self.isDestroying()) return error.AppDestroying;

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
        const removal = self.core_app.removeSurfaceForDestroy(surface);
        if (!removal.removed) {
            log.warn("embedded surface close requested for untracked surface ptr={X}", .{
                @intFromPtr(surface),
            });
            return;
        }

        surface.deinit();
        self.core_app.finishSurfaceDestroy(self, removal);
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
        if (self.performRenderAction(target, action)) return true;

        // Special case certain actions before they are sent to the
        // embedded apprt.
        self.performPreAction(target, action, value);

        log.debug("dispatching action target={t} action={} value={any}", .{
            target,
            action,
            value,
        });
        const c_target = target.cval();
        const c_action = @unionInit(apprt.Action, @tagName(action), value).cval();
        if (comptime builtin.target.os.tag == .linux) {
            return self.opts.action(self.opts.userdata, c_target, c_action);
        }
        return self.opts.action(self, c_target, c_action);
    }

    fn performRenderAction(
        self: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
    ) bool {
        if (!hostRedrawAction(action)) return false;
        if (comptime builtin.target.os.tag != .linux) return false;

        const func = self.opts.redraw_surface orelse return false;
        const rt_surface = switch (target) {
            .app => return false,
            .surface => |surface| surface.rt_surface,
        };
        if (!rt_surface.display_realized) return true;
        func(rt_surface.userdata);
        return true;
    }

    fn hostRedrawAction(comptime action: apprt.Action.Key) bool {
        return switch (action) {
            .render,
            .render_inspector,
            => true,

            else => false,
        };
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

test "ghostty.h runtime config ABI" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;
    const c = @import("ghostty.h");
    const RuntimeWakeupFn = *const fn (?*anyopaque) callconv(.c) void;
    const RuntimeActionFn =
        *const fn (?*anyopaque, apprt.Target.C, apprt.Action.C) callconv(.c) bool;
    const RuntimeReadClipboardFn =
        *const fn (?*anyopaque, c_int, ?*anyopaque) callconv(.c) bool;
    const RuntimeConfirmReadClipboardFn =
        *const fn (?*anyopaque, [*c]const u8, ?*anyopaque, c_int) callconv(.c) void;
    const RuntimeWriteClipboardFn =
        *const fn (?*anyopaque, c_int, [*c]const RuntimeClipboardContent, usize, bool) callconv(.c) void;
    const RuntimeCloseSurfaceFn = *const fn (?*anyopaque, bool) callconv(.c) void;
    const RuntimeRedrawSurfaceFn = *const fn (?*anyopaque) callconv(.c) void;
    const CRuntimeActionFn =
        *const fn (c.ghostty_app_t, c.ghostty_target_s, c.ghostty_action_s) callconv(.c) bool;
    const CRuntimeReadClipboardFn =
        *const fn (?*anyopaque, c.ghostty_clipboard_e, ?*anyopaque) callconv(.c) bool;
    const CRuntimeConfirmReadClipboardFn =
        *const fn (?*anyopaque, [*c]const u8, ?*anyopaque, c.ghostty_clipboard_request_e) callconv(.c) void;
    const CRuntimeWriteClipboardFn =
        *const fn (?*anyopaque, c.ghostty_clipboard_e, [*c]const c.ghostty_clipboard_content_s, usize, bool) callconv(.c) void;

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_runtime_config_s)),
        @as(usize, @sizeOf(RuntimeOptions)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_runtime_config_s)),
        @as(usize, @alignOf(RuntimeOptions)),
    );

    try std.testing.expectEqual(@as(usize, @sizeOf(c_int)), @as(usize, @sizeOf(c.ghostty_clipboard_e)));
    try std.testing.expectEqual(@as(usize, @alignOf(c_int)), @as(usize, @alignOf(c.ghostty_clipboard_e)));
    try std.testing.expectEqual(@as(usize, @sizeOf(c_int)), @as(usize, @sizeOf(c.ghostty_clipboard_request_e)));
    try std.testing.expectEqual(@as(usize, @alignOf(c_int)), @as(usize, @alignOf(c.ghostty_clipboard_request_e)));

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_clipboard_content_s)),
        @as(usize, @sizeOf(RuntimeClipboardContent)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_clipboard_content_s)),
        @as(usize, @alignOf(RuntimeClipboardContent)),
    );
    const clipboard_content_fields = .{ "mime", "data" };
    inline for (clipboard_content_fields) |field| {
        try std.testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_clipboard_content_s, field)),
            @as(usize, @offsetOf(RuntimeClipboardContent, field)),
        );
    }

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_target_s)),
        @as(usize, @sizeOf(apprt.Target.C)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_target_s)),
        @as(usize, @alignOf(apprt.Target.C)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_target_s, "tag")),
        @as(usize, @offsetOf(apprt.Target.C, "key")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_target_s, "target")),
        @as(usize, @offsetOf(apprt.Target.C, "value")),
    );

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_action_s)),
        @as(usize, @sizeOf(apprt.Action.C)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_action_s)),
        @as(usize, @alignOf(apprt.Action.C)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_action_s, "tag")),
        @as(usize, @offsetOf(apprt.Action.C, "key")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_action_s, "action")),
        @as(usize, @offsetOf(apprt.Action.C, "value")),
    );

    const fields = .{
        .{ "userdata", "userdata" },
        .{ "supports_selection_clipboard", "supports_selection_clipboard" },
        .{ "wakeup_cb", "wakeup" },
        .{ "action_cb", "action" },
        .{ "read_clipboard_cb", "read_clipboard" },
        .{ "confirm_read_clipboard_cb", "confirm_read_clipboard" },
        .{ "write_clipboard_cb", "write_clipboard" },
        .{ "close_surface_cb", "close_surface" },
        .{ "redraw_surface_cb", "redraw_surface" },
    };
    inline for (fields) |field| {
        try std.testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_runtime_config_s, field[0])),
            @as(usize, @offsetOf(RuntimeOptions, field[1])),
        );
    }

    try std.testing.expect(@FieldType(RuntimeOptions, "wakeup") == ?RuntimeWakeupFn);
    try std.testing.expect(@FieldType(RuntimeOptions, "action") == ?RuntimeActionFn);
    try std.testing.expect(@FieldType(RuntimeOptions, "read_clipboard") == ?RuntimeReadClipboardFn);
    try std.testing.expect(@FieldType(RuntimeOptions, "confirm_read_clipboard") == ?RuntimeConfirmReadClipboardFn);
    try std.testing.expect(@FieldType(RuntimeOptions, "write_clipboard") == ?RuntimeWriteClipboardFn);
    try std.testing.expect(@FieldType(RuntimeOptions, "close_surface") == ?RuntimeCloseSurfaceFn);
    try std.testing.expect(@FieldType(RuntimeOptions, "redraw_surface") == ?RuntimeRedrawSurfaceFn);
    try std.testing.expect(@FieldType(c.ghostty_runtime_config_s, "redraw_surface_cb") == c.ghostty_runtime_redraw_surface_cb);

    try std.testing.expect(c.ghostty_runtime_wakeup_cb == ?RuntimeWakeupFn);
    try std.testing.expect(c.ghostty_runtime_action_cb == ?CRuntimeActionFn);
    try std.testing.expect(c.ghostty_runtime_read_clipboard_cb == ?CRuntimeReadClipboardFn);
    try std.testing.expect(c.ghostty_runtime_confirm_read_clipboard_cb == ?CRuntimeConfirmReadClipboardFn);
    try std.testing.expect(c.ghostty_runtime_write_clipboard_cb == ?CRuntimeWriteClipboardFn);
    try std.testing.expect(c.ghostty_runtime_close_surface_cb == ?RuntimeCloseSurfaceFn);
    try std.testing.expect(c.ghostty_runtime_redraw_surface_cb == ?RuntimeRedrawSurfaceFn);
}

test "ghostty.h action payload ABI" {
    const c = @import("ghostty.h");

    const ABI = struct {
        fn expectLayout(comptime C: type, comptime Zig: type) !void {
            try std.testing.expectEqual(
                @as(usize, @sizeOf(C)),
                @as(usize, @sizeOf(Zig)),
            );
            try std.testing.expectEqual(
                @as(usize, @alignOf(C)),
                @as(usize, @alignOf(Zig)),
            );
        }
    };

    try ABI.expectLayout(c.ghostty_action_u, apprt.Action.CValue);
    try ABI.expectLayout(c.ghostty_action_split_direction_e, @FieldType(apprt.Action.CValue, "new_split"));
    try ABI.expectLayout(c.ghostty_action_fullscreen_e, @FieldType(apprt.Action.CValue, "toggle_fullscreen"));
    try ABI.expectLayout(c.ghostty_action_move_tab_s, @FieldType(apprt.Action.CValue, "move_tab"));
    try ABI.expectLayout(c.ghostty_action_goto_tab_e, @FieldType(apprt.Action.CValue, "goto_tab"));
    try ABI.expectLayout(c.ghostty_action_goto_split_e, @FieldType(apprt.Action.CValue, "goto_split"));
    try ABI.expectLayout(c.ghostty_action_goto_window_e, @FieldType(apprt.Action.CValue, "goto_window"));
    try ABI.expectLayout(c.ghostty_action_resize_split_s, @FieldType(apprt.Action.CValue, "resize_split"));
    try ABI.expectLayout(c.ghostty_action_size_limit_s, @FieldType(apprt.Action.CValue, "size_limit"));
    try ABI.expectLayout(c.ghostty_action_initial_size_s, @FieldType(apprt.Action.CValue, "initial_size"));
    try ABI.expectLayout(c.ghostty_action_cell_size_s, @FieldType(apprt.Action.CValue, "cell_size"));
    try ABI.expectLayout(c.ghostty_action_scrollbar_s, @FieldType(apprt.Action.CValue, "scrollbar"));
    try ABI.expectLayout(c.ghostty_action_inspector_e, @FieldType(apprt.Action.CValue, "inspector"));
    try ABI.expectLayout(c.ghostty_action_desktop_notification_s, @FieldType(apprt.Action.CValue, "desktop_notification"));
    try ABI.expectLayout(c.ghostty_action_set_title_s, @FieldType(apprt.Action.CValue, "set_title"));
    try ABI.expectLayout(c.ghostty_action_set_title_s, @FieldType(apprt.Action.CValue, "set_tab_title"));
    try ABI.expectLayout(c.ghostty_action_prompt_title_e, @FieldType(apprt.Action.CValue, "prompt_title"));
    try ABI.expectLayout(c.ghostty_action_pwd_s, @FieldType(apprt.Action.CValue, "pwd"));
    try ABI.expectLayout(c.ghostty_action_mouse_shape_e, @FieldType(apprt.Action.CValue, "mouse_shape"));
    try ABI.expectLayout(c.ghostty_action_mouse_visibility_e, @FieldType(apprt.Action.CValue, "mouse_visibility"));
    try ABI.expectLayout(c.ghostty_action_mouse_over_link_s, @FieldType(apprt.Action.CValue, "mouse_over_link"));
    try ABI.expectLayout(c.ghostty_action_renderer_health_e, @FieldType(apprt.Action.CValue, "renderer_health"));
    try ABI.expectLayout(c.ghostty_action_quit_timer_e, @FieldType(apprt.Action.CValue, "quit_timer"));
    try ABI.expectLayout(c.ghostty_action_float_window_e, @FieldType(apprt.Action.CValue, "float_window"));
    try ABI.expectLayout(c.ghostty_action_secure_input_e, @FieldType(apprt.Action.CValue, "secure_input"));
    try ABI.expectLayout(c.ghostty_action_key_sequence_s, @FieldType(apprt.Action.CValue, "key_sequence"));
    try ABI.expectLayout(c.ghostty_action_key_table_s, @FieldType(apprt.Action.CValue, "key_table"));
    try ABI.expectLayout(c.ghostty_action_color_change_s, @FieldType(apprt.Action.CValue, "color_change"));
    try ABI.expectLayout(c.ghostty_action_reload_config_s, @FieldType(apprt.Action.CValue, "reload_config"));
    try ABI.expectLayout(c.ghostty_action_config_change_s, @FieldType(apprt.Action.CValue, "config_change"));
    try ABI.expectLayout(c.ghostty_action_open_url_s, @FieldType(apprt.Action.CValue, "open_url"));
    try ABI.expectLayout(c.ghostty_action_close_tab_mode_e, @FieldType(apprt.Action.CValue, "close_tab"));
    try ABI.expectLayout(c.ghostty_surface_message_childexited_s, @FieldType(apprt.Action.CValue, "show_child_exited"));
    try ABI.expectLayout(c.ghostty_action_progress_report_s, @FieldType(apprt.Action.CValue, "progress_report"));
    try ABI.expectLayout(c.ghostty_action_command_finished_s, @FieldType(apprt.Action.CValue, "command_finished"));
    try ABI.expectLayout(c.ghostty_action_start_search_s, @FieldType(apprt.Action.CValue, "start_search"));
    try ABI.expectLayout(c.ghostty_action_search_total_s, @FieldType(apprt.Action.CValue, "search_total"));
    try ABI.expectLayout(c.ghostty_action_search_selected_s, @FieldType(apprt.Action.CValue, "search_selected"));
    try ABI.expectLayout(c.ghostty_action_readonly_e, @FieldType(apprt.Action.CValue, "readonly"));
}

test "runtime options reject missing required callbacks" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const Callbacks = struct {
        fn wakeup(_: ?*anyopaque) callconv(.c) void {}

        fn action(
            _: ?*anyopaque,
            _: apprt.Target.C,
            _: apprt.Action.C,
        ) callconv(.c) bool {
            return true;
        }

        fn readClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: ?*anyopaque,
        ) callconv(.c) bool {
            return false;
        }

        fn confirmReadClipboard(
            _: ?*anyopaque,
            _: [*c]const u8,
            _: ?*anyopaque,
            _: c_int,
        ) callconv(.c) void {}

        fn writeClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: [*c]const RuntimeClipboardContent,
            _: usize,
            _: bool,
        ) callconv(.c) void {}

        fn redrawSurface(_: ?*anyopaque) callconv(.c) void {}
    };

    var opts: RuntimeOptions = .{};
    try std.testing.expectError(error.RuntimeWakeupMustBeSet, ValidatedRuntimeOptions.init(opts));

    opts.wakeup = Callbacks.wakeup;
    try std.testing.expectError(error.RuntimeActionMustBeSet, ValidatedRuntimeOptions.init(opts));

    opts.action = Callbacks.action;
    try std.testing.expectError(error.RuntimeReadClipboardMustBeSet, ValidatedRuntimeOptions.init(opts));

    opts.read_clipboard = Callbacks.readClipboard;
    try std.testing.expectError(error.RuntimeConfirmReadClipboardMustBeSet, ValidatedRuntimeOptions.init(opts));

    opts.confirm_read_clipboard = Callbacks.confirmReadClipboard;
    try std.testing.expectError(error.RuntimeWriteClipboardMustBeSet, ValidatedRuntimeOptions.init(opts));

    opts.write_clipboard = Callbacks.writeClipboard;
    if (builtin.target.os.tag == .linux) {
        try std.testing.expectError(error.RuntimeRedrawSurfaceMustBeSet, ValidatedRuntimeOptions.init(opts));
        opts.redraw_surface = Callbacks.redrawSurface;
    }

    const validated = try ValidatedRuntimeOptions.init(opts);
    try std.testing.expect(validated.wakeup == Callbacks.wakeup);
    try std.testing.expect(validated.action == Callbacks.action);
    try std.testing.expect(validated.read_clipboard == Callbacks.readClipboard);
    try std.testing.expect(validated.confirm_read_clipboard == Callbacks.confirmReadClipboard);
    try std.testing.expect(validated.write_clipboard == Callbacks.writeClipboard);
    if (builtin.target.os.tag == .linux) {
        try std.testing.expect(validated.redraw_surface.? == Callbacks.redrawSurface);
    }
}

test "embedded host redraw routes terminal and inspector render actions" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expect(App.hostRedrawAction(.render));
    try std.testing.expect(App.hostRedrawAction(.render_inspector));
    try std.testing.expect(!App.hostRedrawAction(.set_title));
}

test "Linux embedded host redraw skips unrealized display" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const Callbacks = struct {
        var redraw_count: usize = 0;

        fn wakeup(_: ?*anyopaque) callconv(.c) void {}

        fn action(
            _: ?*anyopaque,
            _: apprt.Target.C,
            _: apprt.Action.C,
        ) callconv(.c) bool {
            return false;
        }

        fn readClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: ?*anyopaque,
        ) callconv(.c) bool {
            return false;
        }

        fn confirmReadClipboard(
            _: ?*anyopaque,
            _: [*c]const u8,
            _: ?*anyopaque,
            _: c_int,
        ) callconv(.c) void {}

        fn writeClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: [*c]const RuntimeClipboardContent,
            _: usize,
            _: bool,
        ) callconv(.c) void {}

        fn redrawSurface(_: ?*anyopaque) callconv(.c) void {
            redraw_count += 1;
        }
    };

    const opts: RuntimeOptions = .{
        .wakeup = Callbacks.wakeup,
        .action = Callbacks.action,
        .read_clipboard = Callbacks.readClipboard,
        .confirm_read_clipboard = Callbacks.confirmReadClipboard,
        .write_clipboard = Callbacks.writeClipboard,
        .redraw_surface = Callbacks.redrawSurface,
    };
    var app: App = undefined;
    app.opts = try ValidatedRuntimeOptions.init(opts);

    var rt_surface: Surface = undefined;
    rt_surface.userdata = null;
    rt_surface.display_realized = false;

    var core_surface: CoreSurface = undefined;
    core_surface.rt_surface = &rt_surface;

    try std.testing.expect(app.performRenderAction(
        .{ .surface = &core_surface },
        .render,
    ));
    try std.testing.expectEqual(@as(usize, 0), Callbacks.redraw_count);

    rt_surface.display_realized = true;
    try std.testing.expect(app.performRenderAction(
        .{ .surface = &core_surface },
        .render,
    ));
    try std.testing.expectEqual(@as(usize, 1), Callbacks.redraw_count);
}

test "embedded surface destroy finish uses captured runtime app" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const Callbacks = struct {
        var quit_timer_start_count: usize = 0;

        fn wakeup(_: ?*anyopaque) callconv(.c) void {}

        fn action(
            _: ?*anyopaque,
            target: apprt.Target.C,
            action_value: apprt.Action.C,
        ) callconv(.c) bool {
            if (target.key == .app and
                action_value.key == .quit_timer and
                action_value.value.quit_timer == .start)
            {
                quit_timer_start_count += 1;
            }
            return true;
        }

        fn readClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: ?*anyopaque,
        ) callconv(.c) bool {
            return false;
        }

        fn confirmReadClipboard(
            _: ?*anyopaque,
            _: [*c]const u8,
            _: ?*anyopaque,
            _: c_int,
        ) callconv(.c) void {}

        fn writeClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: [*c]const RuntimeClipboardContent,
            _: usize,
            _: bool,
        ) callconv(.c) void {}

        fn redrawSurface(_: ?*anyopaque) callconv(.c) void {}
    };

    var app: App = undefined;
    app.opts = try ValidatedRuntimeOptions.init(.{
        .wakeup = Callbacks.wakeup,
        .action = Callbacks.action,
        .read_clipboard = Callbacks.readClipboard,
        .confirm_read_clipboard = Callbacks.confirmReadClipboard,
        .write_clipboard = Callbacks.writeClipboard,
        .redraw_surface = if (builtin.target.os.tag == .linux) Callbacks.redrawSurface else null,
    });

    var core_app: CoreApp = undefined;
    core_app.finishSurfaceDestroy(&app, .{
        .removed = true,
        .start_quit_timer = true,
    });

    try std.testing.expectEqual(@as(usize, 1), Callbacks.quit_timer_start_count);

    core_app.finishSurfaceDestroy(&app, .{
        .removed = false,
        .start_quit_timer = false,
    });

    try std.testing.expectEqual(@as(usize, 1), Callbacks.quit_timer_start_count);
}

/// Platform-specific configuration for libghostty.
pub const Platform = union(PlatformTag) {
    macos: MacOS,
    ios: IOS,
    linux: Linux,

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

    pub const Linux = if (builtin.target.os.tag == .linux) struct {
        pub const MakeCurrentFn = *const fn (?*anyopaque) callconv(.c) bool;
        pub const GetProcAddressFn = *const fn (?*anyopaque, [*c]const u8) callconv(.c) ?*anyopaque;
        pub const DoneCurrentFn = *const fn (?*anyopaque) callconv(.c) void;

        /// Userdata passed back to all Linux platform callbacks.
        userdata: ?*anyopaque,

        /// Make the host-owned OpenGL context current for this surface.
        make_current: MakeCurrentFn,

        /// Look up an OpenGL procedure in the host-owned OpenGL context.
        get_proc_address: GetProcAddressFn,

        /// Release the host-owned OpenGL context after Ghostty is done with it.
        done_current: ?DoneCurrentFn = null,
    } else void;

    // The C ABI compatible version of this union. The tag is expected
    // to be stored elsewhere.
    pub const C = extern union {
        macos: extern struct {
            nsview: ?*anyopaque,
        },

        ios: extern struct {
            uiview: ?*anyopaque,
        },

        linux_gl: extern struct {
            userdata: ?*anyopaque,
            make_current: ?*const fn (?*anyopaque) callconv(.c) bool,
            get_proc_address: ?*const fn (?*anyopaque, [*c]const u8) callconv(.c) ?*anyopaque,
            done_current: ?*const fn (?*anyopaque) callconv(.c) void,
        },
    };

    /// Initialize a Platform a tag and configuration from the C ABI.
    pub fn init(tag_int: c_int, c_platform: C) !Platform {
        if (tag_int == 0) return error.InvalidPlatform;
        const tag = std.meta.intToEnum(PlatformTag, tag_int) catch return error.InvalidPlatform;
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

            .linux => if (Linux != void) linux: {
                const config = c_platform.linux_gl;
                break :linux .{ .linux = .{
                    .userdata = config.userdata,
                    .make_current = config.make_current orelse
                        break :linux error.LinuxMakeCurrentMustBeSet,
                    .get_proc_address = config.get_proc_address orelse
                        break :linux error.LinuxGetProcAddressMustBeSet,
                    .done_current = config.done_current,
                } };
            } else error.UnsupportedPlatform,
        };
    }
};

pub const PlatformTag = enum(c_int) {
    // "0" is reserved for invalid so we can detect unset values
    // from the C API.

    macos = 1,
    ios = 2,
    linux = 3,

    test "ghostty.h PlatformTag" {
        try renderer.lib.checkGhosttyHEnum(PlatformTag, "GHOSTTY_PLATFORM_");
    }
};

test "Platform rejects invalid C tag" {
    const c = @import("ghostty.h");

    try std.testing.expectEqual(@as(c_int, 0), c.GHOSTTY_PLATFORM_INVALID);
    try std.testing.expectError(error.InvalidPlatform, Platform.init(
        c.GHOSTTY_PLATFORM_INVALID,
        .{ .linux_gl = .{
            .userdata = null,
            .make_current = null,
            .get_proc_address = null,
            .done_current = null,
        } },
    ));
    try std.testing.expectError(error.InvalidPlatform, Platform.init(
        99,
        .{ .linux_gl = .{
            .userdata = null,
            .make_current = null,
            .get_proc_address = null,
            .done_current = null,
        } },
    ));
}

test "Linux Platform validates GL callbacks" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const makeCurrent = struct {
        fn callback(_: ?*anyopaque) callconv(.c) bool {
            return true;
        }
    }.callback;

    const getProcAddress = struct {
        fn callback(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }
    }.callback;

    const doneCurrent = struct {
        fn callback(_: ?*anyopaque) callconv(.c) void {}
    }.callback;

    try std.testing.expectError(error.LinuxMakeCurrentMustBeSet, Platform.init(
        @intFromEnum(PlatformTag.linux),
        .{ .linux_gl = .{
            .userdata = null,
            .make_current = null,
            .get_proc_address = getProcAddress,
            .done_current = null,
        } },
    ));

    try std.testing.expectError(error.LinuxGetProcAddressMustBeSet, Platform.init(
        @intFromEnum(PlatformTag.linux),
        .{ .linux_gl = .{
            .userdata = null,
            .make_current = makeCurrent,
            .get_proc_address = null,
            .done_current = null,
        } },
    ));

    const platform = try Platform.init(
        @intFromEnum(PlatformTag.linux),
        .{ .linux_gl = .{
            .userdata = null,
            .make_current = makeCurrent,
            .get_proc_address = getProcAddress,
            .done_current = null,
        } },
    );
    try std.testing.expect(platform == .linux);
    try std.testing.expect(platform.linux.done_current == null);

    const userdata: ?*anyopaque = @ptrFromInt(0x1234);
    const platform_with_done = try Platform.init(
        @intFromEnum(PlatformTag.linux),
        .{ .linux_gl = .{
            .userdata = userdata,
            .make_current = makeCurrent,
            .get_proc_address = getProcAddress,
            .done_current = doneCurrent,
        } },
    );
    try std.testing.expect(platform_with_done == .linux);
    try std.testing.expectEqual(userdata, platform_with_done.linux.userdata);
    try std.testing.expect(platform_with_done.linux.make_current == makeCurrent);
    try std.testing.expect(platform_with_done.linux.get_proc_address == getProcAddress);
    try std.testing.expect(platform_with_done.linux.done_current.? == doneCurrent);
}

test "Linux embedded surfaces start unrealized until host display callback" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const makeCurrent = struct {
        fn callback(_: ?*anyopaque) callconv(.c) bool {
            return true;
        }
    }.callback;
    const getProcAddress = struct {
        fn callback(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }
    }.callback;

    const platform: Platform = .{ .linux = .{
        .userdata = null,
        .make_current = makeCurrent,
        .get_proc_address = getProcAddress,
        .done_current = null,
    } };

    try std.testing.expect(!Surface.initialDisplayRealized(platform));
}

pub const EnvVar = extern struct {
    /// The name of the environment variable.
    key: ?[*:0]const u8,

    /// The value of the environment variable.
    value: ?[*:0]const u8,
};

pub const IoMode = enum(c_int) {
    exec = 0,
    manual = 1,
};

pub const IoWriteCallback = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;

test "ghostty.h platform ABI" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;
    const c = @import("ghostty.h");
    const MacOSC = @FieldType(Platform.C, "macos");
    const IOSC = @FieldType(Platform.C, "ios");
    const LinuxC = @FieldType(Platform.C, "linux_gl");
    const MakeCurrentFn = *const fn (?*anyopaque) callconv(.c) bool;
    const GetProcAddressFn = *const fn (?*anyopaque, [*c]const u8) callconv(.c) ?*anyopaque;
    const DoneCurrentFn = *const fn (?*anyopaque) callconv(.c) void;

    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(PlatformTag.macos)),
        c.GHOSTTY_PLATFORM_MACOS,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(PlatformTag.ios)),
        c.GHOSTTY_PLATFORM_IOS,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(PlatformTag.linux)),
        c.GHOSTTY_PLATFORM_LINUX,
    );

    try std.testing.expect(@FieldType(MacOSC, "nsview") == ?*anyopaque);
    try std.testing.expect(@FieldType(IOSC, "uiview") == ?*anyopaque);
    try std.testing.expect(c.ghostty_linux_make_current_fn == ?MakeCurrentFn);
    try std.testing.expect(c.ghostty_linux_get_proc_address_fn == ?GetProcAddressFn);
    try std.testing.expect(c.ghostty_linux_done_current_fn == ?DoneCurrentFn);
    try std.testing.expect(@FieldType(LinuxC, "make_current") == ?MakeCurrentFn);
    try std.testing.expect(@FieldType(LinuxC, "get_proc_address") == ?GetProcAddressFn);
    try std.testing.expect(@FieldType(LinuxC, "done_current") == ?DoneCurrentFn);

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_platform_macos_s)),
        @as(usize, @sizeOf(MacOSC)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_platform_macos_s)),
        @as(usize, @alignOf(MacOSC)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_platform_macos_s, "nsview")),
        @as(usize, @offsetOf(MacOSC, "nsview")),
    );
    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_platform_ios_s)),
        @as(usize, @sizeOf(IOSC)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_platform_ios_s)),
        @as(usize, @alignOf(IOSC)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_platform_ios_s, "uiview")),
        @as(usize, @offsetOf(IOSC, "uiview")),
    );
    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_platform_linux_s)),
        @as(usize, @sizeOf(LinuxC)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_platform_linux_s)),
        @as(usize, @alignOf(LinuxC)),
    );

    const linux_fields = .{
        .{ "userdata", "userdata" },
        .{ "make_current", "make_current" },
        .{ "get_proc_address", "get_proc_address" },
        .{ "done_current", "done_current" },
    };
    inline for (linux_fields) |field| {
        try std.testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_platform_linux_s, field[0])),
            @as(usize, @offsetOf(LinuxC, field[1])),
        );
    }

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_platform_u)),
        @as(usize, @sizeOf(Platform.C)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_platform_u)),
        @as(usize, @alignOf(Platform.C)),
    );
}

test "ghostty.h surface config ABI" {
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;
    const c = @import("ghostty.h");

    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.surface.NewSurfaceContext.window)),
        c.GHOSTTY_SURFACE_CONTEXT_WINDOW,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.surface.NewSurfaceContext.tab)),
        c.GHOSTTY_SURFACE_CONTEXT_TAB,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.surface.NewSurfaceContext.split)),
        c.GHOSTTY_SURFACE_CONTEXT_SPLIT,
    );

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_env_var_s)),
        @as(usize, @sizeOf(EnvVar)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_env_var_s)),
        @as(usize, @alignOf(EnvVar)),
    );
    try std.testing.expectEqual(
        @as(usize, max_surface_env_vars),
        @as(usize, c.GHOSTTY_SURFACE_MAX_ENV_VARS),
    );

    const env_fields = .{
        .{ "key", "key" },
        .{ "value", "value" },
    };
    inline for (env_fields) |field| {
        try std.testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_env_var_s, field[0])),
            @as(usize, @offsetOf(EnvVar, field[1])),
        );
    }

    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_surface_config_s)),
        @as(usize, @sizeOf(Surface.Options)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_surface_config_s)),
        @as(usize, @alignOf(Surface.Options)),
    );

    const config_fields = .{
        .{ "platform_tag", "platform_tag" },
        .{ "platform", "platform" },
        .{ "userdata", "userdata" },
        .{ "scale_factor", "scale_factor" },
        .{ "font_size", "font_size" },
        .{ "working_directory", "working_directory" },
        .{ "command", "command" },
        .{ "env_vars", "env_vars" },
        .{ "env_var_count", "env_var_count" },
        .{ "initial_input", "initial_input" },
        .{ "wait_after_command", "wait_after_command" },
        .{ "context", "context" },
        .{ "io_mode", "io_mode" },
        .{ "io_write_cb", "io_write_cb" },
        .{ "io_write_userdata", "io_write_userdata" },
        .{ "initial_output", "initial_output" },
        .{ "initial_output_len", "initial_output_len" },
        .{ "initial_width_px", "initial_width_px" },
        .{ "initial_height_px", "initial_height_px" },
    };
    inline for (config_fields) |field| {
        try std.testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_surface_config_s, field[0])),
            @as(usize, @offsetOf(Surface.Options, field[1])),
        );
    }
}

const ClipboardRequestEntry = struct {
    token: usize,
    request: apprt.ClipboardRequest,
};

pub const RendererEventCallback = renderer.InstrumentationCallback;
pub const RenderPresentedCallback = *const fn (?*anyopaque, u64) callconv(.c) void;

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
    initial_output: []const u8 = "",
    /// The host wants this surface to have a drawable display. Linux hosts can
    /// request realization before their GL context is current, so this may be
    /// true while `display_realized` is still false.
    display_realization_requested: bool = false,
    display_realized: bool = false,
    /// Published before surface teardown begins so reentrant host callbacks
    /// cannot enter C APIs while the surface is being deinitialized.
    destroying: std.atomic.Value(bool) = .init(false),

    /// Outstanding clipboard read requests owned by this surface. Tokens are
    /// monotonic so a delayed host completion can never alias a later request
    /// through allocator address reuse.
    clipboard_request_mutex: std.Thread.Mutex = .{},
    clipboard_requests: std.ArrayListUnmanaged(ClipboardRequestEntry) = .{},
    next_clipboard_request_token: usize = 1,
    renderer_event_cb: ?RendererEventCallback = null,
    scrollback_limit_bytes: usize = 0,
    // Presentation userdata belongs to this exact embedded surface. Install
    // it through the post-construction setter instead of inheriting it through
    // the public by-value Options ABI.
    render_presented_cb: ?RenderPresentedCallback = null,
    render_presented_userdata: ?*anyopaque = null,

    /// The current title of the surface. The embedded apprt saves this so
    /// that getTitle works without the implementer needing to save it.
    title: ?[:0]const u8 = null,

    /// Surface initialization options.
    pub const Options = extern struct {
        /// The platform that this surface is being initialized for and
        /// the associated platform-specific configuration.
        platform_tag: c_int = 0,
        platform: Platform.C = std.mem.zeroes(Platform.C),

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
        env_vars: ?[*]const EnvVar = null,
        env_var_count: usize = 0,

        /// Input to send to the command after it is started.
        initial_input: ?[*:0]const u8 = null,

        /// Wait after the command exits
        wait_after_command: bool = false,

        /// Context for the new surface.
        ///
        /// C type: ghostty_surface_context_e
        context: if (builtin.target.os.tag == .linux)
            c_int
        else
            apprt.surface.NewSurfaceContext = if (builtin.target.os.tag == .linux)
            @intFromEnum(apprt.surface.NewSurfaceContext.window)
        else
            .window,

        /// Select whether Ghostty owns a child PTY or the embedder owns IO.
        io_mode: if (builtin.target.os.tag == .linux)
            c_int
        else
            IoMode = if (builtin.target.os.tag == .linux)
            @intFromEnum(IoMode.exec)
        else
            .exec,

        /// Encoded terminal writes for manual IO surfaces.
        io_write_cb: ?IoWriteCallback = null,

        /// Userdata passed to io_write_cb.
        io_write_userdata: ?*anyopaque = null,

        /// Optional content-free renderer activity callback on native embeds.
        renderer_event_cb: if (builtin.target.os.tag == .linux)
            void
        else
            ?RendererEventCallback = if (builtin.target.os.tag == .linux)
        {} else null,

        /// Raw terminal output parsed before the child IO thread starts.
        initial_output: if (builtin.target.os.tag == .linux) ?[*]const u8 else void = if (builtin.target.os.tag == .linux) null else {},
        initial_output_len: if (builtin.target.os.tag == .linux) usize else void = if (builtin.target.os.tag == .linux) 0 else {},

        /// Initial drawable size used to derive the PTY grid before spawning.
        initial_width_px: if (builtin.target.os.tag == .linux) u32 else void = if (builtin.target.os.tag == .linux) 0 else {},
        initial_height_px: if (builtin.target.os.tag == .linux) u32 else void = if (builtin.target.os.tag == .linux) 0 else {},
    };

    pub fn init(
        self: *Surface,
        app: *App,
        opts: Options,
        scrollback_limit_bytes: usize,
    ) !void {
        const scale_factor = if (comptime builtin.target.os.tag == .linux)
            sanitizeContentScale(opts.scale_factor)
        else
            opts.scale_factor;
        const context = if (comptime builtin.target.os.tag == .linux)
            try surfaceContext(opts.context)
        else
            opts.context;
        const io_mode = if (comptime builtin.target.os.tag == .linux)
            std.meta.intToEnum(IoMode, opts.io_mode) catch return error.InvalidIoMode
        else
            opts.io_mode;
        if (io_mode == .manual and opts.io_write_cb == null) {
            return error.ManualIoWriteCallbackRequired;
        }
        const initial_output = if (comptime builtin.target.os.tag == .linux)
            try surfaceOptionsInitialOutput(opts)
        else
            "";
        self.* = .{
            .app = app,
            .platform = try .init(opts.platform_tag, opts.platform),
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = scale_factor,
                .y = scale_factor,
            },
            .size = .{
                .width = if (comptime builtin.target.os.tag == .linux)
                    if (opts.initial_width_px > 0) opts.initial_width_px else 800
                else
                    800,
                .height = if (comptime builtin.target.os.tag == .linux)
                    if (opts.initial_height_px > 0) opts.initial_height_px else 600
                else
                    600,
            },
            .cursor_pos = .{ .x = -1, .y = -1 },
            .cursor_pos_mods = .{},
            .io_mode = io_mode,
            .io_write_cb = opts.io_write_cb,
            .io_write_userdata = opts.io_write_userdata,
            .initial_output = initial_output,
            .destroying = .init(false),
            .clipboard_request_mutex = .{},
            .clipboard_requests = .{},
            .next_clipboard_request_token = 1,
            .renderer_event_cb = if (comptime builtin.target.os.tag == .linux) null else opts.renderer_event_cb,
            .scrollback_limit_bytes = scrollback_limit_bytes,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Shallow copy the config so that we can modify it.
        var config = try apprt.surface.newConfig(app.core_app, &app.config, context);
        defer config.deinit();
        config.@"scrollback-limit" = effectiveScrollbackLimit(
            config.@"scrollback-limit",
            scrollback_limit_bytes,
        );

        // If we have a working directory from the options then we set it.
        if (opts.working_directory) |c_wd| {
            const wd = try surfaceOptionUtf8String(c_wd, "working_directory");
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
            const cmd = try surfaceOptionUtf8String(c_command, "command");
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Apply any environment variables that were requested.
        const env_vars = try surfaceOptionsEnvVars(opts);
        if (env_vars.len > 0) {
            const alloc = config.arenaAlloc();
            for (env_vars) |env_var| {
                const key = try surfaceOptionEnvKey(env_var.key);
                const value = try surfaceOptionUtf8String(env_var.value, "env value");
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
                try surfaceOptionUtf8String(c_input, "initial_input"),
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
        // The host only owns this buffer for the synchronous create call.
        self.initial_output = "";

        // If our options requested a specific font-size, set that.
        if (sanitizeSurfaceFontSize(opts.font_size)) |points| {
            var font_size = self.core_surface.font_size;
            font_size.points = points;
            try self.core_surface.setFontSize(font_size);
        }

        // Darwin embedders historically create surfaces with native views that
        // are already ready for drawing. Linux GL embedders create while the
        // host context is current, but the host display lifecycle is explicit
        // and must be acknowledged with ghostty_surface_display_realized.
        self.display_realized = initialDisplayRealized(self.platform);
        self.display_realization_requested = self.display_realized;
    }

    pub fn ioMode(self: *const Surface) IoMode {
        return self.io_mode;
    }

    pub fn ioWriteCallback(self: *const Surface) ?IoWriteCallback {
        return self.io_write_cb;
    }

    pub fn ioWriteUserdata(self: *const Surface) ?*anyopaque {
        return self.io_write_userdata;
    }

    pub fn initialOutput(self: *const Surface) []const u8 {
        return self.initial_output;
    }

    /// Applies an optional embedder cap without ever raising the user's
    /// configured lower scrollback limit.
    fn effectiveScrollbackLimit(configured: usize, embedder_cap: usize) usize {
        if (embedder_cap == 0) return configured;
        return @min(configured, embedder_cap);
    }

    test "embedded surface scrollback cap inherits when unset" {
        try std.testing.expectEqual(
            @as(usize, if (builtin.target.os.tag == .linux) 160 else 120),
            @sizeOf(Options),
        );
        try std.testing.expectEqual(
            @as(usize, 50_000_000),
            effectiveScrollbackLimit(50_000_000, 0),
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
        _ = self.beginDestroy();
        self.unrealizeDisplayForDeinit();
        self.drainClipboardRequests();

        // Shut down our inspector. This must happen after display unrealize so
        // Linux OpenGL inspector backend cleanup can run while the host context
        // is still available.
        self.freeInspector();

        // Free our title
        if (self.title) |v| self.app.core_app.alloc.free(v);

        // Remove ourselves from the list of known surfaces in the app.
        self.app.core_app.deleteSurface(self);

        // Clean up our core surface so that all the rendering and IO stop.
        self.core_surface.deinit();
    }

    pub fn destroyFromCoreApp(self: *Surface) void {
        const alloc = self.app.core_app.alloc;
        self.deinit();
        alloc.destroy(self);
    }

    fn beginDestroy(self: *Surface) bool {
        return !self.destroying.swap(true, .acq_rel);
    }

    fn isDestroying(self: *const Surface) bool {
        return self.destroying.load(.acquire);
    }

    fn unrealizeDisplayForDeinit(self: *Surface) void {
        self.displayUnrealized() catch |err| {
            log.warn("failed to unrealize embedded display during surface free err={}", .{err});
        };
    }

    fn initialDisplayRealized(platform: Platform) bool {
        if (comptime Platform.Linux != void) {
            if (std.meta.activeTag(platform) == .linux) return false;
        }

        return true;
    }

    /// Initialize the inspector instance. A surface can only have one
    /// inspector at any given time, so this will return the previous inspector
    /// if it was already initialized.
    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| {
            if (v.isDestroying()) return error.InspectorDestroying;
            return v;
        }

        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        const inspector = self.claimInspectorForDestroy() orelse return;
        inspector.deinit();
        self.inspector = null;
        self.app.core_app.alloc.destroy(inspector);
    }

    fn claimInspectorForDestroy(self: *Surface) ?*Inspector {
        const inspector = self.inspector orelse return null;
        if (!inspector.beginDestroy()) return null;
        return inspector;
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
        if (comptime builtin.target.os.tag == .linux) return;
        const func = self.app.opts.tmux_control orelse return;
        func(self.userdata, event, id, data.ptr, data.len);
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn rendererInstrumentation(self: *const Surface) renderer.Instrumentation {
        return .{
            .callback = if (comptime builtin.target.os.tag == .linux) null else self.renderer_event_cb,
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
        if (comptime builtin.target.os.tag != .linux) {
            const alloc = self.app.core_app.alloc;
            const state_ptr = try alloc.create(apprt.ClipboardRequest);
            errdefer alloc.destroy(state_ptr);
            state_ptr.* = state;
            const started = self.app.opts.read_clipboard(
                self.userdata,
                @intCast(@intFromEnum(clipboard_type)),
                state_ptr,
            );
            if (!started) alloc.destroy(state_ptr);
            return started;
        }

        const state_token = try self.registerClipboardRequest(state);
        const started = self.app.opts.read_clipboard(
            self.userdata,
            @intCast(@intFromEnum(clipboard_type)),
            state_token,
        );
        if (!started) {
            _ = self.takeClipboardRequestOpaque(state_token);
            return false;
        }

        return true;
    }

    fn completeClipboardRequestLinux(
        self: *Surface,
        str: [:0]const u8,
        entry: ClipboardRequestEntry,
        confirmed: bool,
    ) bool {
        // Attempt to complete the request, but we may request
        // confirmation.
        self.core_surface.completeClipboardRequest(
            entry.request,
            str,
            confirmed,
        ) catch |err| switch (err) {
            error.UnsafePaste,
            error.UnauthorizedPaste,
            => {
                const request_type: c_int =
                    @intCast(@intFromEnum(std.meta.activeTag(entry.request)));
                self.restoreClipboardRequest(entry) catch |register_err| {
                    log.err("error preserving clipboard request err={}", .{register_err});
                    return false;
                };

                self.app.opts.confirm_read_clipboard(
                    self.userdata,
                    str.ptr,
                    @ptrFromInt(entry.token),
                    request_type,
                );

                return true;
            },

            else => {
                log.err("error completing clipboard request err={}", .{err});
                return false;
            },
        };

        return true;
    }

    fn completeClipboardRequestNative(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;
        self.core_surface.completeClipboardRequest(state.*, str, confirmed) catch |err| switch (err) {
            error.UnsafePaste, error.UnauthorizedPaste => {
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
        alloc.destroy(state);
    }

    fn registerClipboardRequest(
        self: *Surface,
        request: apprt.ClipboardRequest,
    ) !*anyopaque {
        self.clipboard_request_mutex.lock();
        defer self.clipboard_request_mutex.unlock();

        const token = self.next_clipboard_request_token;
        self.next_clipboard_request_token = std.math.add(usize, token, 1) catch
            return error.ClipboardRequestTokenExhausted;
        try self.clipboard_requests.append(self.app.core_app.alloc, .{
            .token = token,
            .request = request,
        });
        return @ptrFromInt(token);
    }

    fn restoreClipboardRequest(
        self: *Surface,
        entry: ClipboardRequestEntry,
    ) !void {
        self.clipboard_request_mutex.lock();
        defer self.clipboard_request_mutex.unlock();

        try self.clipboard_requests.append(self.app.core_app.alloc, entry);
    }

    fn takeClipboardRequestOpaque(
        self: *Surface,
        state: *anyopaque,
    ) ?ClipboardRequestEntry {
        self.clipboard_request_mutex.lock();
        defer self.clipboard_request_mutex.unlock();

        const token = @intFromPtr(state);
        for (self.clipboard_requests.items, 0..) |request, i| {
            if (request.token == token) {
                return self.clipboard_requests.swapRemove(i);
            }
        }

        return null;
    }

    fn drainClipboardRequests(self: *Surface) void {
        const alloc = self.app.core_app.alloc;

        self.clipboard_request_mutex.lock();
        var requests = self.clipboard_requests;
        self.clipboard_requests = .{};
        self.clipboard_request_mutex.unlock();

        requests.deinit(alloc);
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

    pub fn refresh(self: *Surface) !void {
        if (!self.display_realized) return;
        try self.core_surface.refreshCallback();
    }

    pub fn draw(self: *Surface) !void {
        if (!self.display_realized) {
            if (!self.display_realization_requested) return error.DisplayUnrealized;
            try self.displayRealized();
            if (!self.display_realized) return error.DisplayUnrealized;
        }
        try self.core_surface.draw();
    }

    pub fn displayRealized(self: *Surface) !void {
        self.display_realization_requested = true;
        if (self.display_realized and !self.core_surface.renderer.swap_chain.defunct) return;
        self.display_realized = false;
        self.core_surface.renderer.displayRealized() catch |err| {
            if (displayRealizedContextPending(err)) {
                log.debug("embedded display realization deferred until the host OpenGL context is available", .{});
                return;
            }
            return err;
        };
        self.display_realized = true;
        self.core_surface.refreshCallback() catch |err| {
            log.warn("failed to request embedded display redraw after realization err={}", .{err});
        };
    }

    pub fn displayUnrealized(self: *Surface) !void {
        self.display_realization_requested = false;
        if (!self.hasLiveDisplayResources()) return;
        if (self.core_surface.renderer.swap_chain.defunct) {
            self.deinitDisplayInspectorBackend();
            self.display_realized = false;
            return;
        }
        self.deinitDisplayInspectorBackend();
        self.core_surface.renderer.displayUnrealized() catch |err| {
            if (displayUnrealizedContextLost(err)) {
                log.warn("embedded display unrealized after Linux OpenGL context loss; abandoning GPU resources", .{});
                self.abandonDisplayInspectorBackendAfterContextLoss();
                self.core_surface.renderer.abandonGpuResourcesAfterContextLoss();
                self.display_realized = false;
                return;
            }
            return err;
        };
        self.display_realized = false;
    }

    fn hasLiveDisplayResources(self: *const Surface) bool {
        return self.display_realized or !self.core_surface.renderer.swap_chain.defunct;
    }

    pub fn renderNow(self: *Surface) void {
        self.core_surface.applyPendingResizeIfNeeded();
        self.core_surface.renderer_thread.renderNow();
    }

    pub fn renderNowWithToken(self: *Surface, token: u64) void {
        const callback = self.render_presented_cb orelse {
            self.renderNow();
            return;
        };
        self.core_surface.applyPendingResizeIfNeeded();
        self.core_surface.renderer_thread.renderNowWithPresentation(.{
            .callback = callback,
            .userdata = self.render_presented_userdata,
            .token = token,
        });
    }

    fn deinitDisplayInspectorBackend(self: *Surface) void {
        const inspector = self.inspector orelse return;
        _ = inspector.deinitBackend(
            "ghostty_surface_display_unrealized",
            .abandon_on_context_loss,
        );
    }

    fn abandonDisplayInspectorBackendAfterContextLoss(self: *Surface) void {
        const inspector = self.inspector orelse return;
        inspector.abandonBackendAfterContextLoss("ghostty_surface_display_unrealized");
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) !void {
        self.content_scale = .{
            .x = sanitizeContentScale(x),
            .y = sanitizeContentScale(y),
        };

        try self.core_surface.contentScaleCallback(self.content_scale);
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) !void {
        const size = sanitizeSurfaceSize(width, height);

        // Runtimes sometimes generate superfluous resize events even
        // if the size did not actually change (SwiftUI). We check
        // that the size actually changed from what we last recorded
        // since resizes are expensive.
        if (self.size.eql(&size)) return;

        self.size = size;

        // Call the primary callback.
        try self.core_surface.sizeCallbackPreservePromptHistory(
            self.size,
            builtin.target.os.tag == .linux,
        );
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) !void {
        try self.core_surface.colorSchemeCallback(scheme);
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
    ) bool {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback err={}", .{err});
            return false;
        };
        return true;
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) bool {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback err={}", .{err});
            return false;
        };
        return true;
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) bool {
        // Convert our unscaled x/y to scaled.
        const pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err(
                "error converting cursor pos to scaled pixels in cursor pos callback err={}",
                .{err},
            );
            return false;
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
            self.cursor_pos_mods.equal(mods)) return true;

        self.cursor_pos = pos;
        self.cursor_pos_mods = mods;

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback err={}", .{err});
            return false;
        };
        return true;
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) !void {
        _ = try self.core_surface.preeditCallback(preedit_);
    }

    pub fn textCallback(self: *Surface, text: []const u8) !void {
        _ = try self.core_surface.textCallback(text);
    }

    pub fn textInputCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textInputCallback(text) catch |err| {
            log.err("error in text input callback err={}", .{err});
            return;
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) !void {
        try self.core_surface.focusCallback(focused);
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) !void {
        try self.core_surface.occlusionCallback(visible);
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
            .context = if (comptime builtin.target.os.tag == .linux)
                @intFromEnum(context)
            else
                context,
            .io_mode = if (comptime builtin.target.os.tag == .linux)
                @intFromEnum(self.io_mode)
            else
                self.io_mode,
            .io_write_cb = self.io_write_cb,
            .io_write_userdata = self.io_write_userdata,
            .renderer_event_cb = if (comptime builtin.target.os.tag == .linux) {} else self.renderer_event_cb,
            .initial_output = if (comptime builtin.target.os.tag == .linux) null else {},
            .initial_output_len = if (comptime builtin.target.os.tag == .linux) 0 else {},
            .initial_width_px = if (comptime builtin.target.os.tag == .linux) 0 else {},
            .initial_height_px = if (comptime builtin.target.os.tag == .linux) 0 else {},
        };
    }

    pub fn freeInheritedSurfaceOptions(self: *const Surface, opts: *Options) void {
        freeInheritedSurfaceOptionsFields(self.app.core_app.alloc, opts);
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

/// Sanitize C API content-scale input. Embedders can transiently report bad
/// values while a host surface is being realized; Ghostty only supports scales
/// at or above 1.
fn sanitizeContentScale(value: f64) f32 {
    if (!std.math.isFinite(value) or value < 1) return 1;
    return @floatCast(@min(value, std.math.floatMax(f32)));
}

/// Sanitize the optional C API font-size override. Zero keeps the inherited
/// config/default size; valid overrides use the same bounds as runtime font-size
/// actions and config reloads.
fn sanitizeSurfaceFontSize(value: f32) ?f32 {
    if (value == 0) return null;
    if (!std.math.isFinite(value) or value < 0) return null;
    return std.math.clamp(value, 1.0, 255.0);
}

/// Sanitize C API pixel sizes. Zero-size host allocations can happen while GTK
/// realizes or hides a GLArea, but core surface and inspector state expect a
/// positive drawable size.
fn sanitizeSurfaceSize(width: u32, height: u32) apprt.SurfaceSize {
    return .{
        .width = @max(1, width),
        .height = @max(1, height),
    };
}

const InputPoint = struct {
    x: f64,
    y: f64,
};

/// Sanitize pointer coordinates from C embedders. Negative finite coordinates
/// are meaningful for outside-viewport events, but non-finite values poison
/// hover/selection state and values outside f32 range cannot be represented by
/// Ghostty's cursor position type.
fn sanitizePointerPoint(x: f64, y: f64) ?InputPoint {
    return .{
        .x = sanitizePointerCoordinate(x) orelse return null,
        .y = sanitizePointerCoordinate(y) orelse return null,
    };
}

fn sanitizePointerCoordinate(value: f64) ?f64 {
    if (!std.math.isFinite(value)) return null;
    const max: f64 = std.math.floatMax(f32);
    return std.math.clamp(value, -max, max);
}

/// Sanitize scroll deltas from C embedders. We preserve finite values exactly
/// because host toolkits use both pixel and wheel-unit deltas.
fn sanitizeScrollDelta(x: f64, y: f64) ?InputPoint {
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return null;
    return .{ .x = x, .y = y };
}

fn sanitizeMousePressure(value: f64) f64 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    if (value >= 1) return 1;
    return value;
}

test "embedded content scale sanitizes C API input" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(@as(f32, 1), sanitizeContentScale(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f32, 1), sanitizeContentScale(std.math.inf(f64)));
    try std.testing.expectEqual(@as(f32, 1), sanitizeContentScale(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(f32, 1), sanitizeContentScale(0));
    try std.testing.expectEqual(@as(f32, 1), sanitizeContentScale(0.5));
    try std.testing.expectEqual(@as(f32, 1), sanitizeContentScale(1));
    try std.testing.expectEqual(@as(f32, 1.25), sanitizeContentScale(1.25));
    try std.testing.expectEqual(std.math.floatMax(f32), sanitizeContentScale(std.math.floatMax(f64)));
}

test "embedded font size sanitizes C API input" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?f32, null), sanitizeSurfaceFontSize(std.math.nan(f32)));
    try std.testing.expectEqual(@as(?f32, null), sanitizeSurfaceFontSize(std.math.inf(f32)));
    try std.testing.expectEqual(@as(?f32, null), sanitizeSurfaceFontSize(-std.math.inf(f32)));
    try std.testing.expectEqual(@as(?f32, null), sanitizeSurfaceFontSize(-1));
    try std.testing.expectEqual(@as(?f32, null), sanitizeSurfaceFontSize(0));
    try std.testing.expectEqual(@as(?f32, 1), sanitizeSurfaceFontSize(0.5));
    try std.testing.expectEqual(@as(?f32, 1), sanitizeSurfaceFontSize(1));
    try std.testing.expectEqual(@as(?f32, 13.5), sanitizeSurfaceFontSize(13.5));
    try std.testing.expectEqual(@as(?f32, 255), sanitizeSurfaceFontSize(512));
    try std.testing.expectEqual(@as(?f32, 255), sanitizeSurfaceFontSize(std.math.floatMax(f32)));
}

test "embedded surface size sanitizes C API input" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var size = sanitizeSurfaceSize(0, 0);
    try std.testing.expectEqual(@as(u32, 1), size.width);
    try std.testing.expectEqual(@as(u32, 1), size.height);

    size = sanitizeSurfaceSize(0, 42);
    try std.testing.expectEqual(@as(u32, 1), size.width);
    try std.testing.expectEqual(@as(u32, 42), size.height);

    size = sanitizeSurfaceSize(800, 0);
    try std.testing.expectEqual(@as(u32, 800), size.width);
    try std.testing.expectEqual(@as(u32, 1), size.height);
}

test "embedded pointer input sanitizes C API coordinates" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expect(sanitizePointerPoint(std.math.nan(f64), 1) == null);
    try std.testing.expect(sanitizePointerPoint(1, std.math.inf(f64)) == null);
    try std.testing.expect(sanitizePointerPoint(1, -std.math.inf(f64)) == null);

    var point = sanitizePointerPoint(-12.5, 24.25).?;
    try std.testing.expectEqual(@as(f64, -12.5), point.x);
    try std.testing.expectEqual(@as(f64, 24.25), point.y);

    point = sanitizePointerPoint(std.math.floatMax(f64), -std.math.floatMax(f64)).?;
    try std.testing.expectEqual(@as(f64, std.math.floatMax(f32)), point.x);
    try std.testing.expectEqual(@as(f64, -std.math.floatMax(f32)), point.y);
}

test "embedded scroll input rejects non-finite C API deltas" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expect(sanitizeScrollDelta(std.math.nan(f64), 0) == null);
    try std.testing.expect(sanitizeScrollDelta(0, std.math.inf(f64)) == null);
    try std.testing.expect(sanitizeScrollDelta(0, -std.math.inf(f64)) == null);

    const delta = sanitizeScrollDelta(-0.5, 120.25).?;
    try std.testing.expectEqual(@as(f64, -0.5), delta.x);
    try std.testing.expectEqual(@as(f64, 120.25), delta.y);
}

test "embedded mouse pressure sanitizes C API input" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(@as(f64, 0), sanitizeMousePressure(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 0), sanitizeMousePressure(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(f64, 0), sanitizeMousePressure(-0.5));
    try std.testing.expectEqual(@as(f64, 0), sanitizeMousePressure(0));
    try std.testing.expectEqual(@as(f64, 0.5), sanitizeMousePressure(0.5));
    try std.testing.expectEqual(@as(f64, 1), sanitizeMousePressure(1));
    try std.testing.expectEqual(@as(f64, 0), sanitizeMousePressure(std.math.inf(f64)));
}

test "embedded inspector content scale sanitizes C API input" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const cimgui = Inspector.cimgui;
    const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
    defer cimgui.c.ImGui_DestroyContext(ig_ctx);

    var inspector: Inspector = undefined;
    inspector.ig_ctx = ig_ctx;
    inspector.content_scale = 2;

    inspector.updateContentScale(std.math.nan(f64), 1);
    try std.testing.expectEqual(@as(f64, 1), inspector.content_scale);

    inspector.updateContentScale(std.math.inf(f64), 1);
    try std.testing.expectEqual(@as(f64, 1), inspector.content_scale);

    inspector.updateContentScale(-std.math.inf(f64), 1);
    try std.testing.expectEqual(@as(f64, 1), inspector.content_scale);

    inspector.updateContentScale(0.5, 1);
    try std.testing.expectEqual(@as(f64, 1), inspector.content_scale);

    inspector.updateContentScale(1.25, 1);
    try std.testing.expectEqual(@as(f64, 1.25), inspector.content_scale);
}

test "embedded inspector size sanitizes C API input" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const cimgui = Inspector.cimgui;
    const ig_ctx = cimgui.c.ImGui_CreateContext(null) orelse return error.OutOfMemory;
    defer cimgui.c.ImGui_DestroyContext(ig_ctx);

    var inspector: Inspector = undefined;
    inspector.ig_ctx = ig_ctx;

    inspector.updateSize(0, 0);
    var io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    try std.testing.expectEqual(@as(f32, 1), io.DisplaySize.x);
    try std.testing.expectEqual(@as(f32, 1), io.DisplaySize.y);

    inspector.updateSize(320, 0);
    io = cimgui.c.ImGui_GetIO();
    try std.testing.expectEqual(@as(f32, 320), io.DisplaySize.x);
    try std.testing.expectEqual(@as(f32, 1), io.DisplaySize.y);
}

fn displayUnrealizedContextLost(err: anyerror) bool {
    return builtin.target.os.tag == .linux and err == error.OpenGLContextUnavailable;
}

fn displayRealizedContextPending(err: anyerror) bool {
    return builtin.target.os.tag == .linux and err == error.OpenGLContextUnavailable;
}

test "Linux display unrealize context loss is treated as abandoned" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(
        builtin.target.os.tag == .linux,
        displayUnrealizedContextLost(error.OpenGLContextUnavailable),
    );
    try std.testing.expect(!displayUnrealizedContextLost(error.OutOfMemory));
}

test "Linux display realization remains pending while host context is unavailable" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return false;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }
    };

    const platform: Platform.Linux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = null,
    };

    var surface: Surface = undefined;
    surface.destroying = .init(false);
    surface.display_realization_requested = false;
    surface.display_realized = false;
    surface.core_surface.renderer.swap_chain.defunct = true;
    surface.core_surface.renderer.api.embedded_linux = .{
        .platform = platform,
        .surface = &surface,
    };
    surface.core_surface.renderer.api.embedded_linux_context_current = false;

    try std.testing.expect(CAPI.ghostty_surface_display_realized(&surface));
    try std.testing.expect(surface.display_realization_requested);
    try std.testing.expect(!surface.display_realized);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);

    try std.testing.expectError(error.DisplayUnrealized, surface.draw());
    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);

    try std.testing.expect(CAPI.ghostty_surface_display_unrealized(&surface));
    try std.testing.expect(!surface.display_realization_requested);
    try std.testing.expectError(error.DisplayUnrealized, surface.draw());
    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);
}

test "embedded surface draw C API treats unrealized display as a no-op" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(false);
    surface.display_realization_requested = false;
    surface.display_realized = false;

    try std.testing.expectError(error.DisplayUnrealized, surface.draw());
    try std.testing.expect(CAPI.ghostty_surface_draw(&surface));
    try surface.refresh();
    try std.testing.expect(CAPI.ghostty_surface_refresh(&surface));
}

test "CAPI surface unrealize aliases are idempotent without live display resources" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(false);
    surface.display_realized = false;
    surface.core_surface.renderer.swap_chain.defunct = true;

    try std.testing.expect(CAPI.ghostty_surface_display_unrealized(&surface));
    try std.testing.expect(CAPI.ghostty_surface_set_renderer_realized(&surface, false));
}

fn freeInheritedSurfaceOptionsFields(alloc: Allocator, opts: *Surface.Options) void {
    if (opts.working_directory) |ptr| {
        const len = std.mem.len(ptr);
        alloc.free(@constCast(ptr)[0 .. len + 1]);
    }
    opts.* = .{};
}

fn surfaceOptionsEnvVars(opts: Surface.Options) ![]const EnvVar {
    if (opts.env_var_count == 0) return &.{};
    if (opts.env_var_count > max_surface_env_vars) {
        log.warn(
            "ghostty_surface_new called with env_var_count={} greater than max={}",
            .{ opts.env_var_count, max_surface_env_vars },
        );
        return error.SurfaceEnvVarsTooMany;
    }
    const env_vars = opts.env_vars orelse return error.SurfaceEnvVarsMustBeSet;
    return env_vars[0..opts.env_var_count];
}

fn surfaceOptionsInitialOutput(opts: Surface.Options) ![]const u8 {
    if (opts.initial_output_len == 0) return &.{};
    if (opts.initial_output_len > max_surface_initial_output_bytes) {
        log.warn(
            "ghostty_surface_new called with initial_output_len={} greater than max={}",
            .{ opts.initial_output_len, max_surface_initial_output_bytes },
        );
        return error.SurfaceInitialOutputTooLarge;
    }
    const output = opts.initial_output orelse return error.SurfaceInitialOutputMustBeSet;
    return output[0..opts.initial_output_len];
}

fn surfaceContext(raw: c_int) !apprt.surface.NewSurfaceContext {
    return CAPI.cEnum(
        apprt.surface.NewSurfaceContext,
        raw,
        "ghostty_surface_new",
        "surface context",
    ) orelse error.InvalidSurfaceContext;
}

fn surfaceOptionUtf8String(
    ptr: ?[*:0]const u8,
    comptime field_name: []const u8,
) ![:0]const u8 {
    const value = ptr orelse {
        log.warn("ghostty_surface_new called with null {s}", .{field_name});
        return error.InvalidSurfaceOptionUtf8;
    };
    return CAPI.cUtf8String(value, "ghostty_surface_new", field_name) orelse
        return error.InvalidSurfaceOptionUtf8;
}

fn surfaceOptionEnvKey(ptr: ?[*:0]const u8) ![:0]const u8 {
    const key = try surfaceOptionUtf8String(ptr, "env key");
    if (key.len == 0) {
        log.warn("ghostty_surface_new called with empty env key", .{});
        return error.InvalidSurfaceEnvKey;
    }
    if (std.mem.indexOfScalar(u8, key, '=') != null) {
        log.warn("ghostty_surface_new called with invalid env key key={s}", .{key});
        return error.InvalidSurfaceEnvKey;
    }
    return key;
}

test "inherited surface options free releases owned fields" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    const working_directory = try alloc.dupeZ(u8, "/tmp/cmux");
    var opts: Surface.Options = .{
        .font_size = 14,
        .working_directory = working_directory.ptr,
        .context = @intFromEnum(apprt.surface.NewSurfaceContext.split),
    };

    freeInheritedSurfaceOptionsFields(alloc, &opts);

    try std.testing.expect(opts.working_directory == null);
    try std.testing.expectEqual(@as(f32, 0), opts.font_size);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.surface.NewSurfaceContext.window)),
        opts.context,
    );
}

test "surface options validate C context enum values" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(
        apprt.surface.NewSurfaceContext.window,
        try surfaceContext(@intFromEnum(apprt.surface.NewSurfaceContext.window)),
    );
    try std.testing.expectEqual(
        apprt.surface.NewSurfaceContext.tab,
        try surfaceContext(@intFromEnum(apprt.surface.NewSurfaceContext.tab)),
    );
    try std.testing.expectEqual(
        apprt.surface.NewSurfaceContext.split,
        try surfaceContext(@intFromEnum(apprt.surface.NewSurfaceContext.split)),
    );
    try std.testing.expectError(error.InvalidSurfaceContext, surfaceContext(99));
}

test "surface options env vars require pointer when count is non-zero" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var opts: Surface.Options = .{};
    try std.testing.expectEqual(@as(usize, 0), (try surfaceOptionsEnvVars(opts)).len);

    opts.env_var_count = 1;
    try std.testing.expectError(error.SurfaceEnvVarsMustBeSet, surfaceOptionsEnvVars(opts));

    var env_vars = [_]EnvVar{.{
        .key = "CMUX_TEST",
        .value = "1",
    }};
    opts.env_vars = &env_vars;
    opts.env_var_count = max_surface_env_vars + 1;
    try std.testing.expectError(error.SurfaceEnvVarsTooMany, surfaceOptionsEnvVars(opts));

    opts.env_var_count = 1;
    const result = try surfaceOptionsEnvVars(opts);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("CMUX_TEST", std.mem.sliceTo(result[0].key.?, 0));
    try std.testing.expectEqualStrings("1", std.mem.sliceTo(result[0].value.?, 0));
}

test "surface options initial output validates pointer and size" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var opts: Surface.Options = .{ .initial_output_len = 1 };
    try std.testing.expectError(
        error.SurfaceInitialOutputMustBeSet,
        surfaceOptionsInitialOutput(opts),
    );

    const output = "restored terminal output\n";
    opts.initial_output = output.ptr;
    opts.initial_output_len = output.len;
    try std.testing.expectEqualStrings(output, try surfaceOptionsInitialOutput(opts));

    opts.initial_output_len = max_surface_initial_output_bytes + 1;
    try std.testing.expectError(
        error.SurfaceInitialOutputTooLarge,
        surfaceOptionsInitialOutput(opts),
    );
}

test "surface option strings validate UTF-8" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const working_directory = "/tmp/cmux";
    try std.testing.expectEqualStrings(
        working_directory,
        try surfaceOptionUtf8String(working_directory.ptr, "working_directory"),
    );

    const invalid = [_:0]u8{0xFF};
    try std.testing.expectError(
        error.InvalidSurfaceOptionUtf8,
        surfaceOptionUtf8String(invalid[0..].ptr, "command"),
    );

    try std.testing.expectError(
        error.InvalidSurfaceOptionUtf8,
        surfaceOptionUtf8String(null, "env key"),
    );
}

test "surface env keys reject invalid C env names" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqualStrings(
        "CMUX_TEST",
        try surfaceOptionEnvKey("CMUX_TEST"),
    );

    try std.testing.expectError(
        error.InvalidSurfaceOptionUtf8,
        surfaceOptionEnvKey(null),
    );
    try std.testing.expectError(
        error.InvalidSurfaceEnvKey,
        surfaceOptionEnvKey(""),
    );
    try std.testing.expectError(
        error.InvalidSurfaceEnvKey,
        surfaceOptionEnvKey("BAD=KEY"),
    );
}

/// Inspector is the state required for the terminal inspector. A terminal
/// inspector is 1:1 with a Surface.
pub const Inspector = struct {
    const cimgui = @import("dcimgui");

    surface: *Surface,
    ig_ctx: *cimgui.c.ImGuiContext,
    backend: ?Backend = null,
    content_scale: f64 = 1,
    /// Set before backend teardown invokes host context callbacks. This is
    /// independent from surface teardown because inspectors can be closed
    /// while their surface remains live.
    destroying: std.atomic.Value(bool) = .init(false),

    /// Our previous instant used to calculate delta time for animations.
    instant: ?std.time.Instant = null,

    const Backend = enum {
        metal,
        opengl,

        pub fn deinit(self: Backend) void {
            switch (self) {
                .metal => if (builtin.target.os.tag.isDarwin()) cimgui.ImGui_ImplMetal_Shutdown(),
                .opengl => if (!builtin.target.os.tag.isDarwin()) {
                    if (!cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderTracking()) {
                        log.warn("failed to preserve shared ImGui OpenGL loader during backend shutdown", .{});
                    }
                },
            }
        }
    };

    const BackendDeinitMode = enum {
        preserve_on_context_loss,
        abandon_on_context_loss,
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
            .destroying = .init(false),
        };
    }

    fn beginDestroy(self: *Inspector) bool {
        return !self.destroying.swap(true, .acq_rel);
    }

    fn isDestroying(self: *const Inspector) bool {
        return self.destroying.load(.acquire);
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        _ = self.deinitBackend("ghostty_inspector_free", .abandon_on_context_loss);
        cimgui.c.ImGui_DestroyContext(self.ig_ctx);
    }

    fn deinitBackend(
        self: *Inspector,
        comptime api_name: []const u8,
        mode: BackendDeinitMode,
    ) bool {
        const backend = self.backend orelse return true;

        switch (backend) {
            .opengl => {
                if (!self.makeOpenGLContextCurrent(api_name)) {
                    switch (mode) {
                        .preserve_on_context_loss => {
                            log.warn("{s} preserving OpenGL inspector backend because context is unavailable", .{api_name});
                        },
                        .abandon_on_context_loss => {
                            self.abandonBackendAfterContextLoss(api_name);
                        },
                    }
                    return false;
                }
                defer self.doneOpenGLContext();
            },

            .metal => {},
        }

        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        backend.deinit();
        self.backend = null;
        return true;
    }

    fn abandonBackendAfterContextLoss(self: *Inspector, comptime api_name: []const u8) void {
        switch (self.backend orelse return) {
            .opengl => {
                log.warn("{s} abandoning OpenGL inspector backend after context loss", .{api_name});
                if (!cimgui.ImGui_ImplOpenGL3_AbandonLoaderTracking()) {
                    log.warn("{s} found no tracked ImGui OpenGL loader user to abandon", .{api_name});
                }
                self.backend = null;
            },

            .metal => {},
        }
    }

    fn makeOpenGLContextCurrent(self: *Inspector, comptime api_name: []const u8) bool {
        if (comptime builtin.target.os.tag == .linux) {
            return switch (self.surface.platform) {
                .linux => |platform| {
                    if (platform.make_current(platform.userdata)) return true;
                    log.warn("{s} failed to make Linux OpenGL context current", .{api_name});
                    return false;
                },

                else => {
                    log.warn("{s} requires a Linux OpenGL platform", .{api_name});
                    return false;
                },
            };
        } else {
            return true;
        }
    }

    fn doneOpenGLContext(self: *Inspector) void {
        if (comptime builtin.target.os.tag == .linux) {
            switch (self.surface.platform) {
                .linux => |platform| if (platform.done_current) |func| {
                    func(platform.userdata);
                },

                else => {},
            }
        }
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

    /// Initialize the inspector for an OpenGL backend.
    pub fn initOpenGL(self: *Inspector, glsl_version: ?[*:0]const u8) bool {
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        if (self.backend) |v| {
            v.deinit();
            self.backend = null;
        }

        if (!cimgui.ImGui_ImplOpenGL3_InitWithLoaderTracking(glsl_version)) {
            log.warn("failed to initialize OpenGL backend", .{});
            return false;
        }
        self.backend = .opengl;

        log.debug("initialized OpenGL backend", .{});
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
            try self.renderFrame();
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

    pub fn renderOpenGL(self: *Inspector) !void {
        if (self.backend != .opengl) return error.InspectorOpenGLNotInitialized;
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Setup our imgui frame. We need to render multiple frames to ensure
        // ImGui completes all its state processing. I don't know how to fix
        // this.
        for (0..2) |_| {
            cimgui.ImGui_ImplOpenGL3_NewFrame();
            try self.renderFrame();
        }

        cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = y;
        const scale = sanitizeContentScale(x);
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);

        // Cache our scale because we use it for cursor position calculations.
        self.content_scale = @floatCast(scale);

        // Setup a new style and scale it appropriately. We must use the
        // ImGuiStyle constructor to get proper default values (e.g.,
        // CurveTessellationTol) rather than zero-initialized values.
        var style: cimgui.c.ImGuiStyle = undefined;
        cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
        cimgui.c.ImGuiStyle_ScaleAllSizes(&style, scale);
        const active_style = cimgui.c.ImGui_GetStyle();
        active_style.* = style;
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        const size = sanitizeSurfaceSize(width, height);
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
        io.DisplaySize = .{ .x = @floatFromInt(size.width), .y = @floatFromInt(size.height) };
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        _ = mods;

        self.queueRender();
        cimgui.c.ImGui_SetCurrentContext(self.ig_ctx);
        const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

        const imgui_button = switch (button) {
            .left => cimgui.c.ImGuiMouseButton_Left,
            .middle => cimgui.c.ImGuiMouseButton_Middle,
            .right => cimgui.c.ImGuiMouseButton_Right,
            else => return false,
        };

        cimgui.c.ImGuiIO_AddMouseButtonEvent(io, imgui_button, action == .press);
        return true;
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

    fn renderFrame(self: *Inspector) !void {
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
};

// C API
pub const CAPI = struct {
    const global = &@import("../global.zig").state;

    // ghostty_embedding_info_s
    const EmbeddingInfo = extern struct {
        abi_version: u32,
        platform: c_int,
        renderer_backend: c_int,
        surface_max_env_vars: usize,
        supports_linux_platform: bool,
        must_draw_from_app_thread: bool,
        runtime_config_size: usize,
        surface_config_size: usize,
        platform_linux_size: usize,
        input_key_size: usize,
        target_size: usize,
        action_size: usize,
        text_size: usize,
        selection_size: usize,
        string_size: usize,
        surface_size_size: usize,
        diagnostic_size: usize,
        env_var_size: usize,
        clipboard_content_size: usize,
        input_trigger_size: usize,
        ipc_target_size: usize,
        ipc_action_size: usize,
        runtime_config_align: usize,
        surface_config_align: usize,
        platform_linux_align: usize,
        input_key_align: usize,
        target_align: usize,
        action_align: usize,
        text_align: usize,
        selection_align: usize,
        string_align: usize,
        surface_size_align: usize,
        diagnostic_align: usize,
        env_var_align: usize,
        clipboard_content_align: usize,
        input_trigger_align: usize,
        ipc_target_align: usize,
        ipc_action_align: usize,
        layout_fingerprint: u64,
        constants_fingerprint: u64,
    };

    /// This is the same as Surface.KeyEvent but this is the raw C API version.
    const KeyEvent = extern struct {
        action: c_int,
        mods: c_int,
        consumed_mods: c_int,
        keycode: u32,
        text: ?[*:0]const u8,
        unshifted_codepoint: u32,
        composing: bool,

        /// Convert to Zig key event.
        fn keyEvent(self: KeyEvent, comptime api_name: []const u8) ?App.KeyEvent {
            const action = cEnum(input.Action, self.action, api_name, "key action") orelse return null;
            const text = if (self.text) |ptr|
                cUtf8String(ptr, api_name, "key text") orelse return null
            else
                null;
            return .{
                .action = action,
                .mods = inputMods(self.mods),
                .consumed_mods = inputMods(self.consumed_mods),
                .keycode = self.keycode,
                .text = text,
                .unshifted_codepoint = self.unshifted_codepoint,
                .composing = self.composing,
            };
        }
    };

    fn cEnum(
        comptime T: type,
        raw: c_int,
        comptime api_name: []const u8,
        comptime field_name: []const u8,
    ) ?T {
        return std.meta.intToEnum(T, raw) catch {
            log.warn("{s} called with invalid {s} value={}", .{ api_name, field_name, raw });
            return null;
        };
    }

    fn inputMods(raw: c_int) input.Mods {
        return @bitCast(@as(
            input.Mods.Backing,
            @truncate(@as(c_uint, @bitCast(raw))),
        ));
    }

    fn scrollMods(raw: c_int) input.ScrollMods {
        return @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(raw)))));
    }

    // ghostty_input_mouse_pressure_e
    const MousePressureStage = enum(c_int) {
        none = @intFromEnum(input.MousePressureStage.none),
        normal = @intFromEnum(input.MousePressureStage.normal),
        deep = @intFromEnum(input.MousePressureStage.deep),
        _,

        fn inputStage(self: MousePressureStage) ?input.MousePressureStage {
            return switch (self) {
                .none => .none,
                .normal => .normal,
                .deep => .deep,
                _ => null,
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
    const ClipboardContent = RuntimeClipboardContent;

    // ghostty_diagnostic_s
    const Diagnostic = extern struct {
        message: [*:0]const u8,
    };

    const layout_hash_offset: u64 = 0xcbf29ce484222325;
    const layout_hash_prime: u64 = 0x100000001b3;

    fn layoutHashBytes(hash: *u64, bytes: []const u8) void {
        for (bytes) |byte| {
            hash.* ^= byte;
            hash.* *%= layout_hash_prime;
        }
    }

    fn layoutHashUsize(hash: *u64, value: usize) void {
        var remaining: u64 = @intCast(value);
        inline for (0..8) |_| {
            hash.* ^= @as(u8, @truncate(remaining));
            hash.* *%= layout_hash_prime;
            remaining >>= 8;
        }
    }

    fn layoutHashI64(hash: *u64, value: i64) void {
        var remaining: u64 = @bitCast(value);
        inline for (0..8) |_| {
            hash.* ^= @as(u8, @truncate(remaining));
            hash.* *%= layout_hash_prime;
            remaining >>= 8;
        }
    }

    fn layoutHashType(
        hash: *u64,
        comptime name: []const u8,
        comptime T: type,
        comptime fields: anytype,
    ) void {
        layoutHashBytes(hash, name);
        layoutHashUsize(hash, @sizeOf(T));
        layoutHashUsize(hash, @alignOf(T));
        inline for (fields) |field| {
            layoutHashBytes(hash, field[0]);
            layoutHashUsize(hash, @offsetOf(T, field[1]));
        }
    }

    fn layoutFingerprint() u64 {
        var hash: u64 = layout_hash_offset;
        layoutHashType(&hash, "runtime_config", RuntimeOptions, .{
            .{ "userdata", "userdata" },
            .{ "supports_selection_clipboard", "supports_selection_clipboard" },
            .{ "wakeup_cb", "wakeup" },
            .{ "action_cb", "action" },
            .{ "read_clipboard_cb", "read_clipboard" },
            .{ "confirm_read_clipboard_cb", "confirm_read_clipboard" },
            .{ "write_clipboard_cb", "write_clipboard" },
            .{ "close_surface_cb", "close_surface" },
            .{ "redraw_surface_cb", "redraw_surface" },
        });
        layoutHashType(&hash, "surface_config", apprt.Surface.Options, .{
            .{ "platform_tag", "platform_tag" },
            .{ "platform", "platform" },
            .{ "userdata", "userdata" },
            .{ "scale_factor", "scale_factor" },
            .{ "font_size", "font_size" },
            .{ "working_directory", "working_directory" },
            .{ "command", "command" },
            .{ "env_vars", "env_vars" },
            .{ "env_var_count", "env_var_count" },
            .{ "initial_input", "initial_input" },
            .{ "wait_after_command", "wait_after_command" },
            .{ "context", "context" },
            .{ "io_mode", "io_mode" },
            .{ "io_write_cb", "io_write_cb" },
            .{ "io_write_userdata", "io_write_userdata" },
            .{ "initial_output", "initial_output" },
            .{ "initial_output_len", "initial_output_len" },
            .{ "initial_width_px", "initial_width_px" },
            .{ "initial_height_px", "initial_height_px" },
        });
        if (comptime builtin.target.os.tag == .linux) {
            layoutHashType(&hash, "platform_linux", @FieldType(Platform.C, "linux_gl"), .{
                .{ "userdata", "userdata" },
                .{ "make_current", "make_current" },
                .{ "get_proc_address", "get_proc_address" },
                .{ "done_current", "done_current" },
            });
        } else {
            layoutHashBytes(&hash, "platform_linux");
            layoutHashUsize(&hash, 0);
            layoutHashUsize(&hash, 0);
        }
        layoutHashType(&hash, "input_key", KeyEvent, .{
            .{ "action", "action" },
            .{ "mods", "mods" },
            .{ "consumed_mods", "consumed_mods" },
            .{ "keycode", "keycode" },
            .{ "text", "text" },
            .{ "unshifted_codepoint", "unshifted_codepoint" },
            .{ "composing", "composing" },
        });
        layoutHashType(&hash, "target", apprt.Target.C, .{
            .{ "tag", "key" },
            .{ "target", "value" },
        });
        layoutHashType(&hash, "action", apprt.Action.C, .{
            .{ "tag", "key" },
            .{ "action", "value" },
        });
        layoutHashType(&hash, "action_resize_split", apprt.action.ResizeSplit, .{
            .{ "amount", "amount" },
            .{ "direction", "direction" },
        });
        layoutHashType(&hash, "action_move_tab", apprt.action.MoveTab, .{
            .{ "amount", "amount" },
        });
        layoutHashType(&hash, "action_size_limit", apprt.action.SizeLimit, .{
            .{ "min_width", "min_width" },
            .{ "min_height", "min_height" },
            .{ "max_width", "max_width" },
            .{ "max_height", "max_height" },
        });
        layoutHashType(&hash, "action_initial_size", apprt.action.InitialSize, .{
            .{ "width", "width" },
            .{ "height", "height" },
        });
        layoutHashType(&hash, "action_cell_size", apprt.action.CellSize, .{
            .{ "width", "width" },
            .{ "height", "height" },
        });
        layoutHashType(&hash, "action_mouse_over_link", apprt.action.MouseOverLink.C, .{
            .{ "url", "url" },
            .{ "len", "len" },
        });
        layoutHashType(&hash, "action_set_title", apprt.action.SetTitle.C, .{
            .{ "title", "title" },
        });
        layoutHashType(&hash, "action_pwd", apprt.action.Pwd.C, .{
            .{ "pwd", "pwd" },
        });
        layoutHashType(&hash, "action_desktop_notification", apprt.action.DesktopNotification.C, .{
            .{ "title", "title" },
            .{ "body", "body" },
        });
        layoutHashType(&hash, "action_key_sequence", apprt.action.KeySequence.C, .{
            .{ "active", "active" },
            .{ "trigger", "trigger" },
        });
        layoutHashType(&hash, "action_key_table_activate", @FieldType(apprt.action.KeyTable.CValue, "activate"), .{
            .{ "name", "name" },
            .{ "len", "len" },
        });
        layoutHashType(&hash, "action_key_table", apprt.action.KeyTable.C, .{
            .{ "tag", "tag" },
            .{ "value", "value" },
        });
        layoutHashType(&hash, "action_color_change", apprt.action.ColorChange, .{
            .{ "kind", "kind" },
            .{ "r", "r" },
            .{ "g", "g" },
            .{ "b", "b" },
        });
        layoutHashType(&hash, "action_config_change", apprt.action.ConfigChange.C, .{
            .{ "config", "config" },
        });
        layoutHashType(&hash, "action_reload_config", apprt.action.ReloadConfig, .{
            .{ "soft", "soft" },
        });
        layoutHashType(&hash, "action_open_url", apprt.action.OpenUrl.C, .{
            .{ "kind", "kind" },
            .{ "url", "url" },
            .{ "len", "len" },
        });
        layoutHashType(&hash, "action_child_exited", apprt.surface.Message.ChildExited, .{
            .{ "exit_code", "exit_code" },
            .{ "runtime_ms", "runtime_ms" },
        });
        layoutHashType(&hash, "action_progress_report", terminal.osc.Command.ProgressReport.C, .{
            .{ "state", "state" },
            .{ "progress", "progress" },
        });
        layoutHashType(&hash, "action_command_finished", apprt.action.CommandFinished.C, .{
            .{ "exit_code", "exit_code" },
            .{ "duration", "duration" },
        });
        layoutHashType(&hash, "action_start_search", apprt.action.StartSearch.C, .{
            .{ "needle", "needle" },
        });
        layoutHashType(&hash, "action_search_total", apprt.action.SearchTotal.C, .{
            .{ "total", "total" },
        });
        layoutHashType(&hash, "action_search_selected", apprt.action.SearchSelected.C, .{
            .{ "selected", "selected" },
        });
        layoutHashType(&hash, "action_scrollbar", terminal.Scrollbar.C, .{
            .{ "total", "total" },
            .{ "offset", "offset" },
            .{ "len", "len" },
        });
        layoutHashType(&hash, "text", Text, .{
            .{ "tl_px_x", "tl_px_x" },
            .{ "tl_px_y", "tl_px_y" },
            .{ "offset_start", "offset_start" },
            .{ "offset_len", "offset_len" },
            .{ "text", "text" },
            .{ "text_len", "text_len" },
        });
        layoutHashType(&hash, "point", Point, .{
            .{ "tag", "tag" },
            .{ "coord", "coord_tag" },
            .{ "x", "x" },
            .{ "y", "y" },
        });
        layoutHashType(&hash, "selection", Selection, .{
            .{ "top_left", "tl" },
            .{ "bottom_right", "br" },
            .{ "rectangle", "rectangle" },
        });
        layoutHashType(&hash, "string", String, .{
            .{ "ptr", "ptr" },
            .{ "len", "len" },
            .{ "sentinel", "sentinel" },
        });
        layoutHashType(&hash, "surface_size", SurfaceSize, .{
            .{ "columns", "columns" },
            .{ "rows", "rows" },
            .{ "width_px", "width_px" },
            .{ "height_px", "height_px" },
            .{ "cell_width_px", "cell_width_px" },
            .{ "cell_height_px", "cell_height_px" },
        });
        layoutHashType(&hash, "diagnostic", Diagnostic, .{
            .{ "message", "message" },
        });
        layoutHashType(&hash, "env_var", EnvVar, .{
            .{ "key", "key" },
            .{ "value", "value" },
        });
        layoutHashType(&hash, "clipboard_content", ClipboardContent, .{
            .{ "mime", "mime" },
            .{ "data", "data" },
        });
        layoutHashType(&hash, "input_trigger", input.Binding.Trigger.C, .{
            .{ "tag", "tag" },
            .{ "key", "key" },
            .{ "mods", "mods" },
        });
        layoutHashType(&hash, "ipc_target_payload", apprt.ipc.Target.CValue, .{});
        layoutHashType(&hash, "ipc_target", apprt.ipc.Target.C, .{
            .{ "tag", "key" },
            .{ "target", "value" },
        });
        layoutHashType(&hash, "ipc_action_new_window", apprt.ipc.Action.NewWindow.C, .{
            .{ "arguments", "arguments" },
        });
        layoutHashType(&hash, "ipc_action_payload", apprt.ipc.Action.CValue, .{});
        layoutHashType(&hash, "ipc_action", apprt.ipc.Action.C, .{
            .{ "tag", "key" },
            .{ "action", "value" },
        });
        return hash;
    }

    fn constantsHashInt(hash: *u64, comptime name: []const u8, value: anytype) void {
        layoutHashBytes(hash, name);
        layoutHashI64(hash, @as(i64, @intCast(value)));
    }

    fn constantsFingerprint() u64 {
        var hash: u64 = layout_hash_offset;
        constantsHashInt(&hash, "GHOSTTY_PLATFORM_LINUX", @intFromEnum(PlatformTag.linux));
        constantsHashInt(&hash, "GHOSTTY_RENDERER_BACKEND_UNKNOWN", @intFromEnum(RendererBackend.unknown));
        constantsHashInt(&hash, "GHOSTTY_RENDERER_BACKEND_OPENGL", @intFromEnum(RendererBackend.opengl));
        constantsHashInt(&hash, "GHOSTTY_RENDERER_BACKEND_METAL", @intFromEnum(RendererBackend.metal));
        constantsHashInt(&hash, "GHOSTTY_RENDERER_BACKEND_WEBGL", @intFromEnum(RendererBackend.webgl));
        constantsHashInt(&hash, "GHOSTTY_CLIPBOARD_STANDARD", @intFromEnum(apprt.Clipboard.standard));
        constantsHashInt(&hash, "GHOSTTY_CLIPBOARD_SELECTION", @intFromEnum(apprt.Clipboard.selection));
        constantsHashInt(&hash, "GHOSTTY_CLIPBOARD_PRIMARY", @intFromEnum(apprt.Clipboard.primary));
        constantsHashInt(&hash, "GHOSTTY_CLIPBOARD_REQUEST_PASTE", @intFromEnum(apprt.ClipboardRequestType.paste));
        constantsHashInt(&hash, "GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ", @intFromEnum(apprt.ClipboardRequestType.osc_52_read));
        constantsHashInt(&hash, "GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE", @intFromEnum(apprt.ClipboardRequestType.osc_52_write));
        constantsHashInt(&hash, "GHOSTTY_SURFACE_CONTEXT_WINDOW", @intFromEnum(apprt.surface.NewSurfaceContext.window));
        constantsHashInt(&hash, "GHOSTTY_SURFACE_CONTEXT_TAB", @intFromEnum(apprt.surface.NewSurfaceContext.tab));
        constantsHashInt(&hash, "GHOSTTY_SURFACE_CONTEXT_SPLIT", @intFromEnum(apprt.surface.NewSurfaceContext.split));
        constantsHashInt(&hash, "GHOSTTY_SURFACE_IO_EXEC", @intFromEnum(IoMode.exec));
        constantsHashInt(&hash, "GHOSTTY_SURFACE_IO_MANUAL", @intFromEnum(IoMode.manual));
        constantsHashInt(&hash, "GHOSTTY_SURFACE_MAX_ENV_VARS", max_surface_env_vars);
        constantsHashInt(&hash, "GHOSTTY_ACTION_RELEASE", @intFromEnum(input.Action.release));
        constantsHashInt(&hash, "GHOSTTY_ACTION_PRESS", @intFromEnum(input.Action.press));
        constantsHashInt(&hash, "GHOSTTY_ACTION_REPEAT", @intFromEnum(input.Action.repeat));
        constantsHashInt(&hash, "GHOSTTY_INPUT_KEYCODE_NATIVE_MASK", App.keycode_native_mask);
        constantsHashInt(&hash, "GHOSTTY_INPUT_KEYCODE_PHYSICAL_KEY_FLAG", App.keycode_physical_key_flag);
        constantsHashInt(&hash, "GHOSTTY_TRIGGER_PHYSICAL", @intFromEnum(input.Binding.Trigger.C.Tag.physical));
        constantsHashInt(&hash, "GHOSTTY_TRIGGER_UNICODE", @intFromEnum(input.Binding.Trigger.C.Tag.unicode));
        constantsHashInt(&hash, "GHOSTTY_TRIGGER_CATCH_ALL", @intFromEnum(input.Binding.Trigger.C.Tag.catch_all));
        constantsHashInt(&hash, "GHOSTTY_MODS_SHIFT", @as(input.Mods.Backing, @bitCast(input.Mods{ .shift = true })));
        constantsHashInt(&hash, "GHOSTTY_MODS_CTRL", @as(input.Mods.Backing, @bitCast(input.Mods{ .ctrl = true })));
        constantsHashInt(&hash, "GHOSTTY_MODS_ALT", @as(input.Mods.Backing, @bitCast(input.Mods{ .alt = true })));
        constantsHashInt(&hash, "GHOSTTY_MODS_SUPER", @as(input.Mods.Backing, @bitCast(input.Mods{ .super = true })));
        constantsHashInt(&hash, "GHOSTTY_MODS_CAPS", @as(input.Mods.Backing, @bitCast(input.Mods{ .caps_lock = true })));
        constantsHashInt(&hash, "GHOSTTY_MODS_NUM", @as(input.Mods.Backing, @bitCast(input.Mods{ .num_lock = true })));
        constantsHashInt(&hash, "GHOSTTY_MODS_SHIFT_RIGHT", @as(input.Mods.Backing, @bitCast(input.Mods{ .sides = .{ .shift = .right } })));
        constantsHashInt(&hash, "GHOSTTY_MODS_CTRL_RIGHT", @as(input.Mods.Backing, @bitCast(input.Mods{ .sides = .{ .ctrl = .right } })));
        constantsHashInt(&hash, "GHOSTTY_MODS_ALT_RIGHT", @as(input.Mods.Backing, @bitCast(input.Mods{ .sides = .{ .alt = .right } })));
        constantsHashInt(&hash, "GHOSTTY_MODS_SUPER_RIGHT", @as(input.Mods.Backing, @bitCast(input.Mods{ .sides = .{ .super = .right } })));
        constantsHashInt(&hash, "GHOSTTY_BINDING_FLAGS_CONSUMED", (input.Binding.Flags{ .consumed = true }).cval());
        constantsHashInt(&hash, "GHOSTTY_BINDING_FLAGS_ALL", (input.Binding.Flags{ .consumed = false, .all = true }).cval());
        constantsHashInt(&hash, "GHOSTTY_BINDING_FLAGS_GLOBAL", (input.Binding.Flags{ .consumed = false, .global = true }).cval());
        constantsHashInt(&hash, "GHOSTTY_BINDING_FLAGS_PERFORMABLE", (input.Binding.Flags{ .consumed = false, .performable = true }).cval());
        constantsHashInt(&hash, "GHOSTTY_MOUSE_RELEASE", @intFromEnum(input.MouseButtonState.release));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_PRESS", @intFromEnum(input.MouseButtonState.press));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_UNKNOWN", @intFromEnum(input.MouseButton.unknown));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_LEFT", @intFromEnum(input.MouseButton.left));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_RIGHT", @intFromEnum(input.MouseButton.right));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_MIDDLE", @intFromEnum(input.MouseButton.middle));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_FOUR", @intFromEnum(input.MouseButton.four));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_FIVE", @intFromEnum(input.MouseButton.five));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_SIX", @intFromEnum(input.MouseButton.six));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_SEVEN", @intFromEnum(input.MouseButton.seven));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_EIGHT", @intFromEnum(input.MouseButton.eight));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_NINE", @intFromEnum(input.MouseButton.nine));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_TEN", @intFromEnum(input.MouseButton.ten));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_BUTTON_ELEVEN", @intFromEnum(input.MouseButton.eleven));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_PRESSURE_NONE", @intFromEnum(input.MousePressureStage.none));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_PRESSURE_NORMAL", @intFromEnum(input.MousePressureStage.normal));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_PRESSURE_DEEP", @intFromEnum(input.MousePressureStage.deep));
        constantsHashInt(&hash, "GHOSTTY_COLOR_SCHEME_LIGHT", @intFromEnum(apprt.ColorScheme.light));
        constantsHashInt(&hash, "GHOSTTY_COLOR_SCHEME_DARK", @intFromEnum(apprt.ColorScheme.dark));
        constantsHashInt(&hash, "GHOSTTY_TARGET_APP", @intFromEnum(apprt.Target.Key.app));
        constantsHashInt(&hash, "GHOSTTY_TARGET_SURFACE", @intFromEnum(apprt.Target.Key.surface));
        constantsHashInt(&hash, "GHOSTTY_ACTION_QUIT", @intFromEnum(apprt.Action.Key.quit));
        constantsHashInt(&hash, "GHOSTTY_ACTION_NEW_WINDOW", @intFromEnum(apprt.Action.Key.new_window));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE", @intFromEnum(apprt.Action.Key.toggle_command_palette));
        constantsHashInt(&hash, "GHOSTTY_ACTION_NEW_TAB", @intFromEnum(apprt.Action.Key.new_tab));
        constantsHashInt(&hash, "GHOSTTY_ACTION_CLOSE_TAB", @intFromEnum(apprt.Action.Key.close_tab));
        constantsHashInt(&hash, "GHOSTTY_ACTION_NEW_SPLIT", @intFromEnum(apprt.Action.Key.new_split));
        constantsHashInt(&hash, "GHOSTTY_ACTION_CLOSE_ALL_WINDOWS", @intFromEnum(apprt.Action.Key.close_all_windows));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_MAXIMIZE", @intFromEnum(apprt.Action.Key.toggle_maximize));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_FULLSCREEN", @intFromEnum(apprt.Action.Key.toggle_fullscreen));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW", @intFromEnum(apprt.Action.Key.toggle_tab_overview));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS", @intFromEnum(apprt.Action.Key.toggle_window_decorations));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL", @intFromEnum(apprt.Action.Key.toggle_quick_terminal));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_VISIBILITY", @intFromEnum(apprt.Action.Key.toggle_visibility));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY", @intFromEnum(apprt.Action.Key.toggle_background_opacity));
        constantsHashInt(&hash, "GHOSTTY_ACTION_MOVE_TAB", @intFromEnum(apprt.Action.Key.move_tab));
        constantsHashInt(&hash, "GHOSTTY_ACTION_GOTO_TAB", @intFromEnum(apprt.Action.Key.goto_tab));
        constantsHashInt(&hash, "GHOSTTY_ACTION_GOTO_SPLIT", @intFromEnum(apprt.Action.Key.goto_split));
        constantsHashInt(&hash, "GHOSTTY_ACTION_GOTO_WINDOW", @intFromEnum(apprt.Action.Key.goto_window));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RESIZE_SPLIT", @intFromEnum(apprt.Action.Key.resize_split));
        constantsHashInt(&hash, "GHOSTTY_ACTION_EQUALIZE_SPLITS", @intFromEnum(apprt.Action.Key.equalize_splits));
        constantsHashInt(&hash, "GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM", @intFromEnum(apprt.Action.Key.toggle_split_zoom));
        constantsHashInt(&hash, "GHOSTTY_ACTION_PRESENT_TERMINAL", @intFromEnum(apprt.Action.Key.present_terminal));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SIZE_LIMIT", @intFromEnum(apprt.Action.Key.size_limit));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RESET_WINDOW_SIZE", @intFromEnum(apprt.Action.Key.reset_window_size));
        constantsHashInt(&hash, "GHOSTTY_ACTION_INITIAL_SIZE", @intFromEnum(apprt.Action.Key.initial_size));
        constantsHashInt(&hash, "GHOSTTY_ACTION_CELL_SIZE", @intFromEnum(apprt.Action.Key.cell_size));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SCROLLBAR", @intFromEnum(apprt.Action.Key.scrollbar));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RENDER", @intFromEnum(apprt.Action.Key.render));
        constantsHashInt(&hash, "GHOSTTY_ACTION_INSPECTOR", @intFromEnum(apprt.Action.Key.inspector));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SHOW_GTK_INSPECTOR", @intFromEnum(apprt.Action.Key.show_gtk_inspector));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RENDER_INSPECTOR", @intFromEnum(apprt.Action.Key.render_inspector));
        constantsHashInt(&hash, "GHOSTTY_ACTION_DESKTOP_NOTIFICATION", @intFromEnum(apprt.Action.Key.desktop_notification));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SET_TITLE", @intFromEnum(apprt.Action.Key.set_title));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SET_TAB_TITLE", @intFromEnum(apprt.Action.Key.set_tab_title));
        constantsHashInt(&hash, "GHOSTTY_ACTION_PROMPT_TITLE", @intFromEnum(apprt.Action.Key.prompt_title));
        constantsHashInt(&hash, "GHOSTTY_ACTION_PWD", @intFromEnum(apprt.Action.Key.pwd));
        constantsHashInt(&hash, "GHOSTTY_ACTION_MOUSE_SHAPE", @intFromEnum(apprt.Action.Key.mouse_shape));
        constantsHashInt(&hash, "GHOSTTY_ACTION_MOUSE_VISIBILITY", @intFromEnum(apprt.Action.Key.mouse_visibility));
        constantsHashInt(&hash, "GHOSTTY_ACTION_MOUSE_OVER_LINK", @intFromEnum(apprt.Action.Key.mouse_over_link));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RENDERER_HEALTH", @intFromEnum(apprt.Action.Key.renderer_health));
        constantsHashInt(&hash, "GHOSTTY_ACTION_OPEN_CONFIG", @intFromEnum(apprt.Action.Key.open_config));
        constantsHashInt(&hash, "GHOSTTY_ACTION_QUIT_TIMER", @intFromEnum(apprt.Action.Key.quit_timer));
        constantsHashInt(&hash, "GHOSTTY_ACTION_FLOAT_WINDOW", @intFromEnum(apprt.Action.Key.float_window));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SECURE_INPUT", @intFromEnum(apprt.Action.Key.secure_input));
        constantsHashInt(&hash, "GHOSTTY_ACTION_KEY_SEQUENCE", @intFromEnum(apprt.Action.Key.key_sequence));
        constantsHashInt(&hash, "GHOSTTY_ACTION_KEY_TABLE", @intFromEnum(apprt.Action.Key.key_table));
        constantsHashInt(&hash, "GHOSTTY_ACTION_COLOR_CHANGE", @intFromEnum(apprt.Action.Key.color_change));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RELOAD_CONFIG", @intFromEnum(apprt.Action.Key.reload_config));
        constantsHashInt(&hash, "GHOSTTY_ACTION_CONFIG_CHANGE", @intFromEnum(apprt.Action.Key.config_change));
        constantsHashInt(&hash, "GHOSTTY_ACTION_CLOSE_WINDOW", @intFromEnum(apprt.Action.Key.close_window));
        constantsHashInt(&hash, "GHOSTTY_ACTION_RING_BELL", @intFromEnum(apprt.Action.Key.ring_bell));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SELECTION_CHANGED", @intFromEnum(apprt.Action.Key.selection_changed));
        constantsHashInt(&hash, "GHOSTTY_ACTION_UNDO", @intFromEnum(apprt.Action.Key.undo));
        constantsHashInt(&hash, "GHOSTTY_ACTION_REDO", @intFromEnum(apprt.Action.Key.redo));
        constantsHashInt(&hash, "GHOSTTY_ACTION_CHECK_FOR_UPDATES", @intFromEnum(apprt.Action.Key.check_for_updates));
        constantsHashInt(&hash, "GHOSTTY_ACTION_OPEN_URL", @intFromEnum(apprt.Action.Key.open_url));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SHOW_CHILD_EXITED", @intFromEnum(apprt.Action.Key.show_child_exited));
        constantsHashInt(&hash, "GHOSTTY_ACTION_PROGRESS_REPORT", @intFromEnum(apprt.Action.Key.progress_report));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD", @intFromEnum(apprt.Action.Key.show_on_screen_keyboard));
        constantsHashInt(&hash, "GHOSTTY_ACTION_COMMAND_FINISHED", @intFromEnum(apprt.Action.Key.command_finished));
        constantsHashInt(&hash, "GHOSTTY_ACTION_START_SEARCH", @intFromEnum(apprt.Action.Key.start_search));
        constantsHashInt(&hash, "GHOSTTY_ACTION_END_SEARCH", @intFromEnum(apprt.Action.Key.end_search));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SEARCH_TOTAL", @intFromEnum(apprt.Action.Key.search_total));
        constantsHashInt(&hash, "GHOSTTY_ACTION_SEARCH_SELECTED", @intFromEnum(apprt.Action.Key.search_selected));
        constantsHashInt(&hash, "GHOSTTY_ACTION_READONLY", @intFromEnum(apprt.Action.Key.readonly));
        constantsHashInt(&hash, "GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD", @intFromEnum(apprt.Action.Key.copy_title_to_clipboard));
        constantsHashInt(&hash, "GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN", @intFromEnum(apprt.action.OpenUrl.Kind.unknown));
        constantsHashInt(&hash, "GHOSTTY_ACTION_OPEN_URL_KIND_TEXT", @intFromEnum(apprt.action.OpenUrl.Kind.text));
        constantsHashInt(&hash, "GHOSTTY_ACTION_OPEN_URL_KIND_HTML", @intFromEnum(apprt.action.OpenUrl.Kind.html));
        constantsHashInt(&hash, "GHOSTTY_SPLIT_DIRECTION_RIGHT", @intFromEnum(apprt.action.SplitDirection.right));
        constantsHashInt(&hash, "GHOSTTY_SPLIT_DIRECTION_DOWN", @intFromEnum(apprt.action.SplitDirection.down));
        constantsHashInt(&hash, "GHOSTTY_SPLIT_DIRECTION_LEFT", @intFromEnum(apprt.action.SplitDirection.left));
        constantsHashInt(&hash, "GHOSTTY_SPLIT_DIRECTION_UP", @intFromEnum(apprt.action.SplitDirection.up));
        constantsHashInt(&hash, "GHOSTTY_FULLSCREEN_NATIVE", @intFromEnum(apprt.action.Fullscreen.native));
        constantsHashInt(&hash, "GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE", @intFromEnum(apprt.action.Fullscreen.macos_non_native));
        constantsHashInt(&hash, "GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU", @intFromEnum(apprt.action.Fullscreen.macos_non_native_visible_menu));
        constantsHashInt(&hash, "GHOSTTY_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH", @intFromEnum(apprt.action.Fullscreen.macos_non_native_padded_notch));
        constantsHashInt(&hash, "GHOSTTY_CLOSE_TAB_MODE_THIS", @intFromEnum(apprt.action.CloseTabMode.this));
        constantsHashInt(&hash, "GHOSTTY_CLOSE_TAB_MODE_OTHER", @intFromEnum(apprt.action.CloseTabMode.other));
        constantsHashInt(&hash, "GHOSTTY_CLOSE_TAB_MODE_RIGHT", @intFromEnum(apprt.action.CloseTabMode.right));
        constantsHashInt(&hash, "GHOSTTY_GOTO_TAB_PREVIOUS", @intFromEnum(apprt.action.GotoTab.previous));
        constantsHashInt(&hash, "GHOSTTY_GOTO_TAB_NEXT", @intFromEnum(apprt.action.GotoTab.next));
        constantsHashInt(&hash, "GHOSTTY_GOTO_TAB_LAST", @intFromEnum(apprt.action.GotoTab.last));
        constantsHashInt(&hash, "GHOSTTY_GOTO_SPLIT_PREVIOUS", @intFromEnum(apprt.action.GotoSplit.previous));
        constantsHashInt(&hash, "GHOSTTY_GOTO_SPLIT_NEXT", @intFromEnum(apprt.action.GotoSplit.next));
        constantsHashInt(&hash, "GHOSTTY_GOTO_SPLIT_UP", @intFromEnum(apprt.action.GotoSplit.up));
        constantsHashInt(&hash, "GHOSTTY_GOTO_SPLIT_LEFT", @intFromEnum(apprt.action.GotoSplit.left));
        constantsHashInt(&hash, "GHOSTTY_GOTO_SPLIT_DOWN", @intFromEnum(apprt.action.GotoSplit.down));
        constantsHashInt(&hash, "GHOSTTY_GOTO_SPLIT_RIGHT", @intFromEnum(apprt.action.GotoSplit.right));
        constantsHashInt(&hash, "GHOSTTY_GOTO_WINDOW_PREVIOUS", @intFromEnum(apprt.action.GotoWindow.previous));
        constantsHashInt(&hash, "GHOSTTY_GOTO_WINDOW_NEXT", @intFromEnum(apprt.action.GotoWindow.next));
        constantsHashInt(&hash, "GHOSTTY_RESIZE_SPLIT_UP", @intFromEnum(apprt.action.ResizeSplit.Direction.up));
        constantsHashInt(&hash, "GHOSTTY_RESIZE_SPLIT_DOWN", @intFromEnum(apprt.action.ResizeSplit.Direction.down));
        constantsHashInt(&hash, "GHOSTTY_RESIZE_SPLIT_LEFT", @intFromEnum(apprt.action.ResizeSplit.Direction.left));
        constantsHashInt(&hash, "GHOSTTY_RESIZE_SPLIT_RIGHT", @intFromEnum(apprt.action.ResizeSplit.Direction.right));
        constantsHashInt(&hash, "GHOSTTY_READONLY_OFF", @intFromEnum(apprt.action.Readonly.off));
        constantsHashInt(&hash, "GHOSTTY_READONLY_ON", @intFromEnum(apprt.action.Readonly.on));
        constantsHashInt(&hash, "GHOSTTY_PROGRESS_STATE_REMOVE", @intFromEnum(terminal.osc.Command.ProgressReport.State.remove));
        constantsHashInt(&hash, "GHOSTTY_PROGRESS_STATE_SET", @intFromEnum(terminal.osc.Command.ProgressReport.State.set));
        constantsHashInt(&hash, "GHOSTTY_PROGRESS_STATE_ERROR", @intFromEnum(terminal.osc.Command.ProgressReport.State.@"error"));
        constantsHashInt(&hash, "GHOSTTY_PROGRESS_STATE_INDETERMINATE", @intFromEnum(terminal.osc.Command.ProgressReport.State.indeterminate));
        constantsHashInt(&hash, "GHOSTTY_PROGRESS_STATE_PAUSE", @intFromEnum(terminal.osc.Command.ProgressReport.State.pause));
        constantsHashInt(&hash, "GHOSTTY_RENDERER_HEALTH_HEALTHY", @intFromEnum(renderer.Health.healthy));
        constantsHashInt(&hash, "GHOSTTY_RENDERER_HEALTH_UNHEALTHY", @intFromEnum(renderer.Health.unhealthy));
        constantsHashInt(&hash, "GHOSTTY_PROMPT_TITLE_SURFACE", @intFromEnum(apprt.action.PromptTitle.surface));
        constantsHashInt(&hash, "GHOSTTY_PROMPT_TITLE_TAB", @intFromEnum(apprt.action.PromptTitle.tab));
        constantsHashInt(&hash, "GHOSTTY_QUIT_TIMER_START", @intFromEnum(apprt.action.QuitTimer.start));
        constantsHashInt(&hash, "GHOSTTY_QUIT_TIMER_STOP", @intFromEnum(apprt.action.QuitTimer.stop));
        constantsHashInt(&hash, "GHOSTTY_FLOAT_WINDOW_ON", @intFromEnum(apprt.action.FloatWindow.on));
        constantsHashInt(&hash, "GHOSTTY_FLOAT_WINDOW_OFF", @intFromEnum(apprt.action.FloatWindow.off));
        constantsHashInt(&hash, "GHOSTTY_FLOAT_WINDOW_TOGGLE", @intFromEnum(apprt.action.FloatWindow.toggle));
        constantsHashInt(&hash, "GHOSTTY_SECURE_INPUT_ON", @intFromEnum(apprt.action.SecureInput.on));
        constantsHashInt(&hash, "GHOSTTY_SECURE_INPUT_OFF", @intFromEnum(apprt.action.SecureInput.off));
        constantsHashInt(&hash, "GHOSTTY_SECURE_INPUT_TOGGLE", @intFromEnum(apprt.action.SecureInput.toggle));
        constantsHashInt(&hash, "GHOSTTY_INSPECTOR_TOGGLE", @intFromEnum(apprt.action.Inspector.toggle));
        constantsHashInt(&hash, "GHOSTTY_INSPECTOR_SHOW", @intFromEnum(apprt.action.Inspector.show));
        constantsHashInt(&hash, "GHOSTTY_INSPECTOR_HIDE", @intFromEnum(apprt.action.Inspector.hide));
        constantsHashInt(&hash, "GHOSTTY_KEY_UNIDENTIFIED", @intFromEnum(input.Key.unidentified));
        constantsHashInt(&hash, "GHOSTTY_KEY_BACKSPACE", @intFromEnum(input.Key.backspace));
        constantsHashInt(&hash, "GHOSTTY_KEY_ENTER", @intFromEnum(input.Key.enter));
        constantsHashInt(&hash, "GHOSTTY_KEY_SPACE", @intFromEnum(input.Key.space));
        constantsHashInt(&hash, "GHOSTTY_KEY_TAB", @intFromEnum(input.Key.tab));
        constantsHashInt(&hash, "GHOSTTY_KEY_DELETE", @intFromEnum(input.Key.delete));
        constantsHashInt(&hash, "GHOSTTY_KEY_END", @intFromEnum(input.Key.end));
        constantsHashInt(&hash, "GHOSTTY_KEY_HOME", @intFromEnum(input.Key.home));
        constantsHashInt(&hash, "GHOSTTY_KEY_INSERT", @intFromEnum(input.Key.insert));
        constantsHashInt(&hash, "GHOSTTY_KEY_PAGE_DOWN", @intFromEnum(input.Key.page_down));
        constantsHashInt(&hash, "GHOSTTY_KEY_PAGE_UP", @intFromEnum(input.Key.page_up));
        constantsHashInt(&hash, "GHOSTTY_KEY_ARROW_DOWN", @intFromEnum(input.Key.arrow_down));
        constantsHashInt(&hash, "GHOSTTY_KEY_ARROW_LEFT", @intFromEnum(input.Key.arrow_left));
        constantsHashInt(&hash, "GHOSTTY_KEY_ARROW_RIGHT", @intFromEnum(input.Key.arrow_right));
        constantsHashInt(&hash, "GHOSTTY_KEY_ARROW_UP", @intFromEnum(input.Key.arrow_up));
        constantsHashInt(&hash, "GHOSTTY_KEY_ESCAPE", @intFromEnum(input.Key.escape));
        constantsHashInt(&hash, "GHOSTTY_KEY_F1", @intFromEnum(input.Key.f1));
        constantsHashInt(&hash, "GHOSTTY_KEY_F2", @intFromEnum(input.Key.f2));
        constantsHashInt(&hash, "GHOSTTY_KEY_F3", @intFromEnum(input.Key.f3));
        constantsHashInt(&hash, "GHOSTTY_KEY_F4", @intFromEnum(input.Key.f4));
        constantsHashInt(&hash, "GHOSTTY_KEY_F5", @intFromEnum(input.Key.f5));
        constantsHashInt(&hash, "GHOSTTY_KEY_F6", @intFromEnum(input.Key.f6));
        constantsHashInt(&hash, "GHOSTTY_KEY_F7", @intFromEnum(input.Key.f7));
        constantsHashInt(&hash, "GHOSTTY_KEY_F8", @intFromEnum(input.Key.f8));
        constantsHashInt(&hash, "GHOSTTY_KEY_F9", @intFromEnum(input.Key.f9));
        constantsHashInt(&hash, "GHOSTTY_KEY_F10", @intFromEnum(input.Key.f10));
        constantsHashInt(&hash, "GHOSTTY_KEY_F11", @intFromEnum(input.Key.f11));
        constantsHashInt(&hash, "GHOSTTY_KEY_F12", @intFromEnum(input.Key.f12));
        constantsHashInt(&hash, "GHOSTTY_KEY_F13", @intFromEnum(input.Key.f13));
        constantsHashInt(&hash, "GHOSTTY_KEY_F14", @intFromEnum(input.Key.f14));
        constantsHashInt(&hash, "GHOSTTY_KEY_F15", @intFromEnum(input.Key.f15));
        constantsHashInt(&hash, "GHOSTTY_KEY_F16", @intFromEnum(input.Key.f16));
        constantsHashInt(&hash, "GHOSTTY_KEY_F17", @intFromEnum(input.Key.f17));
        constantsHashInt(&hash, "GHOSTTY_KEY_F18", @intFromEnum(input.Key.f18));
        constantsHashInt(&hash, "GHOSTTY_KEY_F19", @intFromEnum(input.Key.f19));
        constantsHashInt(&hash, "GHOSTTY_KEY_F20", @intFromEnum(input.Key.f20));
        constantsHashInt(&hash, "GHOSTTY_KEY_F21", @intFromEnum(input.Key.f21));
        constantsHashInt(&hash, "GHOSTTY_KEY_F22", @intFromEnum(input.Key.f22));
        constantsHashInt(&hash, "GHOSTTY_KEY_F23", @intFromEnum(input.Key.f23));
        constantsHashInt(&hash, "GHOSTTY_KEY_F24", @intFromEnum(input.Key.f24));
        constantsHashInt(&hash, "GHOSTTY_KEY_F25", @intFromEnum(input.Key.f25));
        constantsHashInt(&hash, "GHOSTTY_KEY_FN", @intFromEnum(input.Key.@"fn"));
        constantsHashInt(&hash, "GHOSTTY_KEY_FN_LOCK", @intFromEnum(input.Key.fn_lock));
        constantsHashInt(&hash, "GHOSTTY_KEY_PRINT_SCREEN", @intFromEnum(input.Key.print_screen));
        constantsHashInt(&hash, "GHOSTTY_KEY_SCROLL_LOCK", @intFromEnum(input.Key.scroll_lock));
        constantsHashInt(&hash, "GHOSTTY_KEY_PAUSE", @intFromEnum(input.Key.pause));
        constantsHashInt(&hash, "GHOSTTY_KEY_TABLE_ACTIVATE", @intFromEnum(apprt.action.KeyTable.Tag.activate));
        constantsHashInt(&hash, "GHOSTTY_KEY_TABLE_DEACTIVATE", @intFromEnum(apprt.action.KeyTable.Tag.deactivate));
        constantsHashInt(&hash, "GHOSTTY_KEY_TABLE_DEACTIVATE_ALL", @intFromEnum(apprt.action.KeyTable.Tag.deactivate_all));
        constantsHashInt(&hash, "GHOSTTY_COLOR_KIND_FOREGROUND", @intFromEnum(apprt.action.ColorKind.foreground));
        constantsHashInt(&hash, "GHOSTTY_COLOR_KIND_BACKGROUND", @intFromEnum(apprt.action.ColorKind.background));
        constantsHashInt(&hash, "GHOSTTY_COLOR_KIND_CURSOR", @intFromEnum(apprt.action.ColorKind.cursor));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_DEFAULT", @intFromEnum(terminal.MouseShape.default));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU", @intFromEnum(terminal.MouseShape.context_menu));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_HELP", @intFromEnum(terminal.MouseShape.help));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_POINTER", @intFromEnum(terminal.MouseShape.pointer));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_PROGRESS", @intFromEnum(terminal.MouseShape.progress));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_WAIT", @intFromEnum(terminal.MouseShape.wait));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_CELL", @intFromEnum(terminal.MouseShape.cell));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_CROSSHAIR", @intFromEnum(terminal.MouseShape.crosshair));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_TEXT", @intFromEnum(terminal.MouseShape.text));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT", @intFromEnum(terminal.MouseShape.vertical_text));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_ALIAS", @intFromEnum(terminal.MouseShape.alias));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_COPY", @intFromEnum(terminal.MouseShape.copy));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_MOVE", @intFromEnum(terminal.MouseShape.move));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NO_DROP", @intFromEnum(terminal.MouseShape.no_drop));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED", @intFromEnum(terminal.MouseShape.not_allowed));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_GRAB", @intFromEnum(terminal.MouseShape.grab));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_GRABBING", @intFromEnum(terminal.MouseShape.grabbing));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_ALL_SCROLL", @intFromEnum(terminal.MouseShape.all_scroll));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_COL_RESIZE", @intFromEnum(terminal.MouseShape.col_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_ROW_RESIZE", @intFromEnum(terminal.MouseShape.row_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_N_RESIZE", @intFromEnum(terminal.MouseShape.n_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_E_RESIZE", @intFromEnum(terminal.MouseShape.e_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_S_RESIZE", @intFromEnum(terminal.MouseShape.s_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_W_RESIZE", @intFromEnum(terminal.MouseShape.w_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NE_RESIZE", @intFromEnum(terminal.MouseShape.ne_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NW_RESIZE", @intFromEnum(terminal.MouseShape.nw_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_SE_RESIZE", @intFromEnum(terminal.MouseShape.se_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_SW_RESIZE", @intFromEnum(terminal.MouseShape.sw_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_EW_RESIZE", @intFromEnum(terminal.MouseShape.ew_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NS_RESIZE", @intFromEnum(terminal.MouseShape.ns_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NESW_RESIZE", @intFromEnum(terminal.MouseShape.nesw_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE", @intFromEnum(terminal.MouseShape.nwse_resize));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_ZOOM_IN", @intFromEnum(terminal.MouseShape.zoom_in));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_SHAPE_ZOOM_OUT", @intFromEnum(terminal.MouseShape.zoom_out));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_VISIBLE", @intFromEnum(apprt.action.MouseVisibility.visible));
        constantsHashInt(&hash, "GHOSTTY_MOUSE_HIDDEN", @intFromEnum(apprt.action.MouseVisibility.hidden));
        constantsHashInt(&hash, "GHOSTTY_POINT_VIEWPORT", @intFromEnum(Point.Tag.viewport));
        constantsHashInt(&hash, "GHOSTTY_POINT_COORD_TOP_LEFT", @intFromEnum(Point.CoordTag.top_left));
        constantsHashInt(&hash, "GHOSTTY_POINT_COORD_BOTTOM_RIGHT", @intFromEnum(Point.CoordTag.bottom_right));
        constantsHashInt(&hash, "GHOSTTY_IPC_TARGET_CLASS", @intFromEnum(apprt.ipc.Target.Key.class));
        constantsHashInt(&hash, "GHOSTTY_IPC_TARGET_DETECT", @intFromEnum(apprt.ipc.Target.Key.detect));
        constantsHashInt(&hash, "GHOSTTY_IPC_ACTION_NEW_WINDOW", @intFromEnum(apprt.ipc.Action.Key.new_window));
        constantsHashInt(&hash, "GHOSTTY_IPC_ACTION_TOGGLE_QUICK_TERMINAL", @intFromEnum(apprt.ipc.Action.Key.toggle_quick_terminal));
        return hash;
    }

    fn embeddingInfo() EmbeddingInfo {
        return .{
            .abi_version = embedding_abi_version,
            .platform = switch (builtin.target.os.tag) {
                .linux => @intFromEnum(PlatformTag.linux),
                .macos => @intFromEnum(PlatformTag.macos),
                .ios => @intFromEnum(PlatformTag.ios),
                else => 0,
            },
            .renderer_backend = @intFromEnum(rendererBackend()),
            .surface_max_env_vars = max_surface_env_vars,
            .supports_linux_platform = builtin.target.os.tag == .linux,
            .must_draw_from_app_thread = App.must_draw_from_app_thread,
            .runtime_config_size = @sizeOf(RuntimeOptions),
            .surface_config_size = @sizeOf(apprt.Surface.Options),
            .platform_linux_size = platformLinuxAbiSize(),
            .input_key_size = @sizeOf(KeyEvent),
            .target_size = @sizeOf(apprt.Target.C),
            .action_size = @sizeOf(apprt.Action.C),
            .text_size = @sizeOf(Text),
            .selection_size = @sizeOf(Selection),
            .string_size = @sizeOf(String),
            .surface_size_size = @sizeOf(SurfaceSize),
            .diagnostic_size = @sizeOf(Diagnostic),
            .env_var_size = @sizeOf(EnvVar),
            .clipboard_content_size = @sizeOf(ClipboardContent),
            .input_trigger_size = @sizeOf(input.Binding.Trigger.C),
            .ipc_target_size = @sizeOf(apprt.ipc.Target.C),
            .ipc_action_size = @sizeOf(apprt.ipc.Action.C),
            .runtime_config_align = @alignOf(RuntimeOptions),
            .surface_config_align = @alignOf(apprt.Surface.Options),
            .platform_linux_align = platformLinuxAbiAlign(),
            .input_key_align = @alignOf(KeyEvent),
            .target_align = @alignOf(apprt.Target.C),
            .action_align = @alignOf(apprt.Action.C),
            .text_align = @alignOf(Text),
            .selection_align = @alignOf(Selection),
            .string_align = @alignOf(String),
            .surface_size_align = @alignOf(SurfaceSize),
            .diagnostic_align = @alignOf(Diagnostic),
            .env_var_align = @alignOf(EnvVar),
            .clipboard_content_align = @alignOf(ClipboardContent),
            .input_trigger_align = @alignOf(input.Binding.Trigger.C),
            .ipc_target_align = @alignOf(apprt.ipc.Target.C),
            .ipc_action_align = @alignOf(apprt.ipc.Action.C),
            .layout_fingerprint = layoutFingerprint(),
            .constants_fingerprint = constantsFingerprint(),
        };
    }

    const RendererBackend = enum(c_int) {
        unknown = 0,
        opengl = 1,
        metal = 2,
        webgl = 3,
    };

    fn rendererBackend() RendererBackend {
        return switch (build_config.renderer) {
            .opengl => .opengl,
            .metal => .metal,
            .webgl => .webgl,
        };
    }

    export fn ghostty_embedding_info() EmbeddingInfo {
        return embeddingInfo();
    }

    export fn ghostty_embedding_info_query(
        info_: ?*EmbeddingInfo,
        len: usize,
    ) bool {
        const info = info_ orelse return false;
        const bytes: [*]u8 = @ptrCast(info);
        if (len > 0) @memset(bytes[0..len], 0);

        // Keep padding deterministic and copy only the prefix owned by this
        // library version. This lets older callers inspect fields that fit in
        // their smaller buffer while the return value still reports that the
        // current full contract did not fit.
        var value = std.mem.zeroes(EmbeddingInfo);
        const current = embeddingInfo();
        inline for (std.meta.fields(EmbeddingInfo)) |field| {
            @field(value, field.name) = @field(current, field.name);
        }
        const value_bytes = std.mem.asBytes(&value);
        const copy_len = @min(len, value_bytes.len);
        if (copy_len > 0) @memcpy(bytes[0..copy_len], value_bytes[0..copy_len]);
        return len >= @sizeOf(EmbeddingInfo);
    }

    // ghostty_text_s
    const Text = extern struct {
        tl_px_x: f64,
        tl_px_y: f64,
        offset_start: u32,
        offset_len: u32,
        text: ?[*:0]const u8,
        text_len: usize,

        pub fn clear(self: *Text) void {
            self.* = std.mem.zeroes(Text);
        }

        pub fn deinit(self: *Text) void {
            if (self.text) |ptr| {
                global.alloc.free(ptr[0..self.text_len :0]);
            }
            self.clear();
        }
    };

    fn platformLinuxAbiSize() usize {
        if (comptime builtin.target.os.tag != .linux) return 0;
        return @sizeOf(@FieldType(Platform.C, "linux_gl"));
    }

    fn platformLinuxAbiAlign() usize {
        if (comptime builtin.target.os.tag != .linux) return 0;
        return @alignOf(@FieldType(Platform.C, "linux_gl"));
    }

    // ghostty_point_s
    const Point = extern struct {
        // Keep enum values as raw C ABI integers until they have been
        // validated. A foreign caller can provide any bit pattern here and
        // switching directly on an invalid Zig enum value can trap.
        tag: c_int,
        coord_tag: c_int,
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
            const point_tag = cEnum(
                Tag,
                self.tag,
                "ghostty_surface_read_text",
                "point tag",
            ) orelse return null;
            const coord_tag = cEnum(
                CoordTag,
                self.coord_tag,
                "ghostty_surface_read_text",
                "point coordinate tag",
            ) orelse return null;

            // The core point tag.
            const tag: terminal.point.Tag = switch (point_tag) {
                inline else => |tag| @field(
                    terminal.point.Tag,
                    @tagName(tag),
                ),
            };

            // Clamp our point to the screen bounds.
            const clamped_x = @min(self.x, screen.pages.cols -| 1);
            const clamped_y = @min(self.y, screen.pages.rows -| 1);

            return switch (coord_tag) {
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

    test "CAPI selection points reject invalid enum values" {
        if (comptime !embedded_runtime_tests) return error.SkipZigTest;

        const fake_screen: *const terminal.Screen = @ptrFromInt(@alignOf(terminal.Screen));
        var point: Point = .{
            .tag = 99,
            .coord_tag = @intFromEnum(Point.CoordTag.exact),
            .x = 0,
            .y = 0,
        };
        try std.testing.expect(point.pin(fake_screen) == null);

        point.tag = @intFromEnum(Point.Tag.viewport);
        point.coord_tag = 99;
        try std.testing.expect(point.pin(fake_screen) == null);
    }

    // Reference the conditional exports based on target platform
    // so they're included in the C API.
    comptime {
        if (builtin.target.os.tag.isDarwin()) {
            _ = Darwin;
        }
        if (builtin.target.os.tag == .linux) {
            _ = Linux;
        }
    }

    /// Create a new app.
    export fn ghostty_app_new(
        opts: ?*const apprt.runtime.App.Options,
        config: ?*const Config,
    ) ?*App {
        return app_new_(opts, config) catch |err| {
            log.err("error initializing app err={}", .{err});
            return null;
        };
    }

    fn app_new_(
        opts_: ?*const apprt.runtime.App.Options,
        config_: ?*const Config,
    ) !*App {
        const opts = opts_ orelse return error.RuntimeOptionsMustBeSet;
        const config = config_ orelse return error.ConfigMustBeSet;

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
    export fn ghostty_app_tick(v_: ?*App) bool {
        const v = appHandle(v_, "ghostty_app_tick") orelse return false;
        v.core_app.tick(v) catch |err| {
            log.err("error app tick err={}", .{err});
            return false;
        };
        return true;
    }

    /// Return the userdata associated with the app.
    export fn ghostty_app_userdata(v_: ?*App) ?*anyopaque {
        const v = appHandle(v_, "ghostty_app_userdata") orelse return null;
        return v.opts.userdata;
    }

    export fn ghostty_app_free(v_: ?*App) void {
        const v = v_ orelse {
            log.warn("ghostty_app_free called with null app", .{});
            return;
        };
        if (!v.beginDestroy()) {
            log.warn("ghostty_app_free called with destroying app", .{});
            return;
        }
        const core_app = v.core_app;

        // Core app destruction tears down surfaces, and embedded surfaces keep
        // a pointer back to the runtime app for host callbacks and allocation.
        // Keep the runtime app alive until all surfaces have been destroyed.
        core_app.destroy();

        v.terminate();
        global.alloc.destroy(v);
    }

    /// Update the focused state of the app.
    export fn ghostty_app_set_focus(
        app_: ?*App,
        focused: bool,
    ) bool {
        const app = appHandle(app_, "ghostty_app_set_focus") orelse return false;
        app.focusEvent(focused);
        return true;
    }

    /// Notify the app of a global keypress capture. This will return
    /// true if the key was captured by the app, in which case the caller
    /// should not process the key.
    export fn ghostty_app_key(
        app_: ?*App,
        event: KeyEvent,
    ) bool {
        const app = appHandle(app_, "ghostty_app_key") orelse return false;
        const key_event = event.keyEvent("ghostty_app_key") orelse return false;
        return app.keyEvent(.app, key_event) catch |err| {
            log.warn("error processing key event err={}", .{err});
            return false;
        };
    }

    /// Returns true if the given key event would trigger a binding
    /// if it were sent to the surface right now. The "right now"
    /// is important because things like trigger sequences are only
    /// valid until the next key event.
    export fn ghostty_config_key_is_binding(
        config_: ?*Config,
        event: KeyEvent,
    ) bool {
        const config = mutableConfigHandle(config_, "ghostty_config_key_is_binding") orelse return false;
        const key_event = event.keyEvent("ghostty_config_key_is_binding") orelse return false;
        const core_event = key_event.core() orelse {
            log.warn("error processing key event", .{});
            return false;
        };

        return config.keyEventIsBinding(core_event);
    }

    /// Notify the app that the keyboard was changed. This causes the
    /// keyboard layout to be reloaded from the OS.
    export fn ghostty_app_keyboard_changed(v_: ?*App) bool {
        const v = appHandle(v_, "ghostty_app_keyboard_changed") orelse return false;
        v.reloadKeymap() catch |err| {
            log.err("error reloading keyboard map err={}", .{err});
            return false;
        };
        return true;
    }

    /// Open the configuration.
    export fn ghostty_app_open_config(v_: ?*App) bool {
        const v = appHandle(v_, "ghostty_app_open_config") orelse return false;
        return v.performAction(.app, .open_config, {}) catch |err| {
            log.err("error opening config err={}", .{err});
            return false;
        };
    }

    /// Reload the configuration.
    export fn ghostty_app_reload_config(v_: ?*App, soft: bool) bool {
        const v = appHandle(v_, "ghostty_app_reload_config") orelse return false;
        return v.performAction(.app, .reload_config, .{ .soft = soft }) catch |err| {
            log.err("error reloading config err={}", .{err});
            return false;
        };
    }

    /// Update the configuration to the provided config. This will propagate
    /// to all surfaces as well.
    export fn ghostty_app_update_config(
        v_: ?*App,
        config_: ?*const Config,
    ) bool {
        const v = appHandle(v_, "ghostty_app_update_config") orelse return false;
        const config = configHandle(config_, "ghostty_app_update_config") orelse return false;
        v.core_app.updateConfig(v, config) catch |err| {
            log.err("error updating config err={}", .{err});
            return false;
        };
        return true;
    }

    /// Returns true if the app needs to confirm quitting.
    export fn ghostty_app_needs_confirm_quit(v_: ?*App) bool {
        const v = appHandle(v_, "ghostty_app_needs_confirm_quit") orelse return false;
        return v.core_app.needsConfirmQuit();
    }

    /// Returns true if the app has global keybinds.
    export fn ghostty_app_has_global_keybinds(v_: ?*App) bool {
        const v = appHandle(v_, "ghostty_app_has_global_keybinds") orelse return false;
        return v.hasGlobalKeybinds();
    }

    /// Returns true if this runtime requires the host application thread to
    /// perform surface drawing.
    export fn ghostty_app_must_draw_from_app_thread(v_: ?*App) bool {
        _ = appHandle(v_, "ghostty_app_must_draw_from_app_thread") orelse return false;
        return App.must_draw_from_app_thread;
    }

    /// Update the color scheme of the app.
    export fn ghostty_app_set_color_scheme(v_: ?*App, scheme_raw: c_int) bool {
        const v = appHandle(v_, "ghostty_app_set_color_scheme") orelse return false;
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_app_set_color_scheme value={}",
                .{scheme_raw},
            );
            return false;
        };

        v.core_app.colorSchemeEvent(v, scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return false;
        };
        return true;
    }

    /// Returns initial surface options.
    export fn ghostty_surface_config_new() apprt.Surface.Options {
        return .{};
    }

    /// Create a new surface as part of an app.
    export fn ghostty_surface_new(
        app: ?*App,
        opts: ?*const apprt.Surface.Options,
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
        app_: ?*App,
        opts_: ?*const apprt.Surface.Options,
        scrollback_limit_bytes: usize,
    ) !*Surface {
        const app = app_ orelse return error.AppMustBeSet;
        if (app.isDestroying()) return error.AppDestroying;
        const opts = opts_ orelse return error.SurfaceOptionsMustBeSet;
        return try app.newSurface(opts.*, scrollback_limit_bytes);
    }

    export fn ghostty_surface_free(ptr_: ?*Surface) void {
        const ptr = ptr_ orelse return;
        if (!ptr.beginDestroy()) {
            log.warn("ghostty_surface_free called with destroying surface", .{});
            return;
        }
        ptr.app.closeSurface(ptr);
    }

    /// Returns the userdata associated with the surface.
    export fn ghostty_surface_userdata(surface_: ?*Surface) ?*anyopaque {
        const surface = surfaceHandle(surface_, "ghostty_surface_userdata") orelse return null;
        return surface.userdata;
    }

    /// Returns the app associated with a surface.
    export fn ghostty_surface_app(surface_: ?*Surface) ?*App {
        const surface = surfaceHandle(surface_, "ghostty_surface_app") orelse return null;
        return surface.app;
    }

    /// Returns the separate embedder cap so inherited surface creation can
    /// preserve it without adding a field to Surface.Options.
    export fn ghostty_surface_scrollback_limit_bytes(surface: *Surface) usize {
        return surface.scrollback_limit_bytes;
    }

    /// Returns the config to use for surfaces that inherit from this one.
    export fn ghostty_surface_inherited_config(
        surface_: ?*Surface,
        source_raw: c_int,
    ) Surface.Options {
        const surface = surfaceHandle(surface_, "ghostty_surface_inherited_config") orelse return .{};
        const source = surfaceContext(source_raw) catch |err| {
            log.warn(
                "ghostty_surface_inherited_config called with invalid surface context value={} err={}",
                .{ source_raw, err },
            );
            return .{};
        };
        return surface.newSurfaceOptions(source);
    }

    /// Free Ghostty-owned fields returned by ghostty_surface_inherited_config.
    export fn ghostty_surface_inherited_config_free(
        surface_: ?*Surface,
        opts_: ?*apprt.Surface.Options,
    ) void {
        const opts = opts_ orelse return;
        const surface = surface_ orelse {
            log.warn("ghostty_surface_inherited_config_free called with null surface", .{});
            opts.* = .{};
            return;
        };

        // This releases ownership and does not enter live surface state. Keep
        // it valid during Surface.deinit so callbacks can return inherited
        // fields after the general surface API teardown gate has closed.
        surface.freeInheritedSurfaceOptions(opts);
    }

    /// Update the configuration to the provided config for only this surface.
    export fn ghostty_surface_update_config(
        surface_: ?*Surface,
        config_: ?*const Config,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_update_config") orelse return false;
        const config = configHandle(config_, "ghostty_surface_update_config") orelse return false;
        surface.core_surface.updateConfig(config) catch |err| {
            log.err("error updating config err={}", .{err});
            return false;
        };
        return true;
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
    export fn ghostty_surface_needs_confirm_quit(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_needs_confirm_quit") orelse return false;
        return surface.core_surface.needsConfirmQuit();
    }

    /// Returns true if the surface process has exited.
    export fn ghostty_surface_process_exited(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_process_exited") orelse return false;
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
    export fn ghostty_surface_has_selection(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_has_selection") orelse return false;
        return surface.core_surface.hasSelection();
    }

    /// Select the terminal cell under the active cursor. Returns true if the
    /// active selection changed.
    export fn ghostty_surface_select_cursor_cell(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_select_cursor_cell") orelse return false;
        return surface.core_surface.selectCursorCell() catch |err| {
            log.err("error selecting cursor cell err={}", .{err});
            return false;
        };
    }

    /// Select complete rows in the visible viewport. Row bounds are inclusive.
    export fn ghostty_surface_select_viewport_rows(
        surface_: ?*Surface,
        start_row: u32,
        end_row: u32,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_select_viewport_rows") orelse return false;
        return surface.core_surface.selectViewportRows(start_row, end_row) catch |err| {
            log.err("error selecting viewport rows err={}", .{err});
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

    /// Clear the current selection. Returns true if a selection was cleared.
    export fn ghostty_surface_clear_selection(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_clear_selection") orelse return false;
        return surface.core_surface.clearSelection() catch |err| {
            log.err("error clearing selection err={}", .{err});
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
        surface_: ?*Surface,
        result_: ?*Text,
    ) bool {
        const result = textResultOutput(result_, "ghostty_surface_read_selection") orelse return false;
        const surface = surfaceHandle(surface_, "ghostty_surface_read_selection") orelse return false;
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
        surface_: ?*Surface,
        sel: Selection,
        result_: ?*Text,
    ) bool {
        const result = textResultOutput(result_, "ghostty_surface_read_text") orelse return false;
        const surface = surfaceHandle(surface_, "ghostty_surface_read_text") orelse return false;
        surface.core_surface.renderer_state.mutex.lock();
        defer surface.core_surface.renderer_state.mutex.unlock();

        const core_sel = sel.core(
            surface.core_surface.renderer_state.terminal.screens.active,
        ) orelse return false;

        return readTextLocked(surface, core_sel, result);
    }

    /// Read a bounded tail of completed terminal history. An active semantic
    /// prompt/input is excluded so restored output can precede a fresh shell.
    export fn ghostty_surface_read_scrollback(
        surface_: ?*Surface,
        max_bytes: usize,
        result_: ?*Text,
    ) bool {
        const result = textResultOutput(result_, "ghostty_surface_read_scrollback") orelse return false;
        const surface = surfaceHandle(surface_, "ghostty_surface_read_scrollback") orelse return false;
        if (max_bytes == 0 or max_bytes > max_surface_scrollback_read_bytes) {
            log.warn(
                "ghostty_surface_read_scrollback called with invalid max_bytes={} max={}",
                .{ max_bytes, max_surface_scrollback_read_bytes },
            );
            return false;
        }

        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = core_surface.io.terminal.screens.active;
        const selection_end = end: {
            // Prefer the nearest prompt marker even when the cursor semantic
            // state is still output. Deferred shell integration can mark the
            // first prompt before the cursor state catches up, and restoring
            // that prompt would duplicate it when the new shell starts.
            var prompts = screen.cursor.page_pin.promptIterator(.left_up, null);
            const prior_pin = if (prompts.next()) |prompt| prompt: {
                const prompt_start = if (prompt.rowAndCell().row.semantic_prompt == .prompt_continuation or
                    (surfaceForegroundIsSessionLeader(core_surface) and
                        terminal.Screen.promptMarkerFollowsUnmarkedText(prompt)))
                    // Some deferred prompt setups mark only continuation
                    // rows. Zsh instant prompts can also paint multiple rows
                    // before a delayed primary marker is emitted at line-init;
                    // those cells retain output semantics. In either case,
                    // treat the preceding unmarked row as the first prompt row.
                    prompt.up(1) orelse prompt
                else
                    prompt;
                break :prompt prompt_start.up(1);
            } else
                // Without semantic shell markers, the cursor row may be an
                // active prompt, input, or partial output. None of those are
                // completed history, so stop at the preceding row.
                screen.cursor.page_pin.up(1);
            var prior = prior_pin orelse {
                const text = global.alloc.allocSentinel(u8, 0, 0) catch |err| {
                    log.warn("error reading empty scrollback text err={}", .{err});
                    return false;
                };
                result.* = .{
                    .tl_px_x = -1,
                    .tl_px_y = -1,
                    .offset_start = 0,
                    .offset_len = 0,
                    .text = text.ptr,
                    .text_len = 0,
                };
                return true;
            };
            prior.x = prior.node.cols() - 1;
            break :end prior;
        };
        const text = screen.selectionStringTail(
            global.alloc,
            .{
                .bounds = .{ .untracked = .{
                    .start = screen.pages.getTopLeft(.screen),
                    .end = selection_end,
                } },
                .rectangle = false,
            },
            max_bytes,
        ) catch |err| {
            log.warn("error reading scrollback text err={}", .{err});
            return false;
        };

        result.* = .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
            .text = text.ptr,
            .text_len = text.len,
        };
        return true;
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

    fn surfaceForegroundIsSessionLeader(surface: *CoreSurface) bool {
        if (comptime builtin.target.os.tag != .linux) return false;

        const foreground = surface.getProcessInfo(.foreground_pid) orelse return false;
        const pid = std.math.cast(std.posix.pid_t, foreground) orelse return false;
        const session = libc.getsid(pid);
        return session > 0 and session == pid;
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

    fn textResultOutput(result_: ?*Text, comptime api_name: []const u8) ?*Text {
        const result = result_ orelse {
            log.warn("{s} called with null result", .{api_name});
            return null;
        };
        result.clear();
        return result;
    }

    export fn ghostty_surface_free_text(_: ?*Surface, ptr_: ?*Text) void {
        const ptr = ptr_ orelse return;
        ptr.deinit();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_refresh(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_refresh") orelse return false;
        surface.refresh() catch |err| {
            log.err("error in refresh callback err={}", .{err});
            return false;
        };
        return true;
    }

    /// Tell the surface that it needs to schedule a render
    /// call as soon as possible (NOW if possible).
    export fn ghostty_surface_draw(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_draw") orelse return false;
        surface.draw() catch |err| {
            switch (err) {
                error.DisplayUnrealized => {
                    log.debug("ghostty_surface_draw ignored while display is unrealized", .{});
                    return true;
                },
                else => log.err("error in draw err={}", .{err}),
            }
            return false;
        };
        return true;
    }

    fn surfaceSetDisplayRealized(
        surface_: ?*Surface,
        realized: bool,
        comptime api_name: []const u8,
    ) bool {
        const surface = surfaceHandle(surface_, api_name) orelse return false;
        const verb: []const u8 = if (realized) "realizing" else "unrealizing";
        const noun: []const u8 = if (std.mem.eql(u8, api_name, "ghostty_surface_set_renderer_realized"))
            "renderer"
        else
            "display";

        if (realized) {
            surface.displayRealized() catch |err| {
                log.err("error {s} surface {s} err={}", .{ verb, noun, err });
                return false;
            };
            return true;
        }

        surface.displayUnrealized() catch |err| {
            log.err("error {s} surface {s} err={}", .{ verb, noun, err });
            return false;
        };
        return true;
    }

    /// Notify the surface that its host display/GL context was realized.
    export fn ghostty_surface_display_realized(surface_: ?*Surface) bool {
        return surfaceSetDisplayRealized(
            surface_,
            true,
            "ghostty_surface_display_realized",
        );
    }

    /// Notify the surface that its host display/GL context was unrealized.
    export fn ghostty_surface_display_unrealized(surface_: ?*Surface) bool {
        return surfaceSetDisplayRealized(
            surface_,
            false,
            "ghostty_surface_display_unrealized",
        );
    }

    /// Compatibility hook for embedders that track renderer/display
    /// realization as a single boolean state.
    export fn ghostty_surface_set_renderer_realized(surface_: ?*Surface, realized: bool) bool {
        return surfaceSetDisplayRealized(
            surface_,
            realized,
            "ghostty_surface_set_renderer_realized",
        );
    }

    /// Perform a full render cycle synchronously from the calling thread.
    export fn ghostty_surface_render_now(surface: *Surface) void {
        surface.renderNow();
    }

    /// Install the completion callback for this surface only. Registration is
    /// one-shot because submitted frames snapshot this userdata. Call before
    /// sharing the surface or submitting tokened work. Inherited surfaces have
    /// distinct embedder userdata and install their own callback after
    /// construction. The embedder keeps userdata alive until surface
    /// destruction returns.
    export fn ghostty_surface_set_render_presented_callback(
        surface: *Surface,
        callback: ?RenderPresentedCallback,
        userdata: ?*anyopaque,
    ) bool {
        const registered_callback = callback orelse return false;
        if (surface.render_presented_cb != null) return false;

        surface.render_presented_cb = registered_callback;
        surface.render_presented_userdata = userdata;
        return true;
    }

    /// Force a render whose exact layer presentation is acknowledged with the
    /// caller-provided token.
    export fn ghostty_surface_render_now_with_token(surface: *Surface, token: u64) void {
        surface.renderNowWithToken(token);
    }

    /// Update the size of a surface. This will trigger resize notifications
    /// to the pty and the renderer.
    export fn ghostty_surface_set_size(surface_: ?*Surface, w: u32, h: u32) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_set_size") orelse return false;
        surface.updateSize(w, h) catch |err| {
            log.err("error in size callback err={}", .{err});
            return false;
        };
        return true;
    }

    /// Return the size information a surface has.
    export fn ghostty_surface_size(surface_: ?*Surface) SurfaceSize {
        const surface = surfaceHandle(surface_, "ghostty_surface_size") orelse return std.mem.zeroes(SurfaceSize);
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
    export fn ghostty_surface_foreground_pid(surface_: ?*Surface) u64 {
        const surface = surfaceHandle(surface_, "ghostty_surface_foreground_pid") orelse return 0;
        return surface.core_surface.getProcessInfo(.foreground_pid) orelse 0;
    }

    /// Returns the PTY name for the surface. The returned string must be
    /// freed by the caller via ghostty_string_free.
    export fn ghostty_surface_tty_name(surface_: ?*Surface) String {
        const surface = surfaceHandle(surface_, "ghostty_surface_tty_name") orelse return .empty;
        const tty_name = surface.core_surface.getProcessInfo(.tty_name) orelse return .empty;
        const copy = global.alloc.dupeZ(u8, tty_name) catch |err| {
            log.err("error allocating tty name err={}", .{err});
            return .empty;
        };

        return .fromSlice(copy);
    }

    /// Returns the current terminal title for the surface. The returned string
    /// must be freed by the caller via ghostty_string_free.
    export fn ghostty_surface_title(surface_: ?*Surface) String {
        const surface = surfaceHandle(surface_, "ghostty_surface_title") orelse return .empty;
        const title = surface.getTitle() orelse return .empty;
        const copy = global.alloc.dupeZ(u8, title) catch |err| {
            log.err("error allocating surface title err={}", .{err});
            return .empty;
        };

        return .fromSlice(copy);
    }

    /// Returns the current terminal working directory for the surface. The
    /// returned string must be freed by the caller via ghostty_string_free.
    export fn ghostty_surface_pwd(surface_: ?*Surface) String {
        const surface = surfaceHandle(surface_, "ghostty_surface_pwd") orelse return .empty;
        const pwd = surface.core_surface.pwd(global.alloc) catch |err| {
            log.err("error allocating surface working directory err={}", .{err});
            return .empty;
        } orelse return .empty;

        return .fromSlice(pwd);
    }

    /// Update the color scheme of the surface.
    export fn ghostty_surface_set_color_scheme(surface_: ?*Surface, scheme_raw: c_int) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_set_color_scheme") orelse return false;
        const scheme = std.meta.intToEnum(apprt.ColorScheme, scheme_raw) catch {
            log.warn(
                "invalid color scheme to ghostty_surface_set_color_scheme value={}",
                .{scheme_raw},
            );
            return false;
        };

        surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme err={}", .{err});
            return false;
        };
        return true;
    }

    /// Update the content scale of the surface.
    export fn ghostty_surface_set_content_scale(surface_: ?*Surface, x: f64, y: f64) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_set_content_scale") orelse return false;
        surface.updateContentScale(x, y) catch |err| {
            log.err("error in content scale callback err={}", .{err});
            return false;
        };
        return true;
    }

    /// Update the focused state of a surface.
    export fn ghostty_surface_set_focus(surface_: ?*Surface, focused: bool) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_set_focus") orelse return false;
        surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback err={}", .{err});
            return false;
        };
        return true;
    }

    fn surfaceSetVisible(
        surface_: ?*Surface,
        visible: bool,
        comptime api_name: []const u8,
    ) bool {
        const surface = surfaceHandle(surface_, api_name) orelse return false;
        surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback err={}", .{err});
            return false;
        };
        return true;
    }

    /// Update surface visibility. The parameter is true when the host surface
    /// is visible, false when it is occluded/hidden.
    export fn ghostty_surface_set_visible(surface_: ?*Surface, visible: bool) bool {
        return surfaceSetVisible(surface_, visible, "ghostty_surface_set_visible");
    }

    /// Compatibility alias for the original Linux embedding slice. The boolean
    /// has the same visibility semantics as ghostty_surface_set_visible.
    export fn ghostty_surface_set_occlusion(surface_: ?*Surface, visible: bool) bool {
        return surfaceSetVisible(surface_, visible, "ghostty_surface_set_occlusion");
    }

    /// Filter the mods if necessary. This handles settings such as
    /// `macos-option-as-alt`. The filtered mods should be used for
    /// key translation but should NOT be sent back via the `_key`
    /// function -- the original mods should be used for that.
    export fn ghostty_surface_key_translation_mods(
        surface_: ?*Surface,
        mods_raw: c_int,
    ) c_int {
        const surface = surfaceHandle(surface_, "ghostty_surface_key_translation_mods") orelse return mods_raw;
        const mods = inputMods(mods_raw);
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
        surface_: ?*Surface,
        event: KeyEvent,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_key") orelse return false;
        const key_event = event.keyEvent("ghostty_surface_key") orelse return false;
        return surface.app.keyEvent(
            .{ .surface = surface },
            key_event,
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
        surface_: ?*Surface,
        event: KeyEvent,
        c_flags: ?*input.Binding.Flags.C,
    ) bool {
        if (c_flags) |ptr| ptr.* = 0;
        const surface = surfaceHandle(surface_, "ghostty_surface_key_is_binding") orelse return false;
        const key_event = event.keyEvent("ghostty_surface_key_is_binding") orelse return false;
        const core_event = key_event.core() orelse {
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
        surface_: ?*Surface,
        ptr: ?[*]const u8,
        len: usize,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_text") orelse return false;
        const text = cUtf8Bytes(ptr, len, "ghostty_surface_text") orelse return false;
        surface.textCallback(text) catch |err| {
            log.err("error in text callback err={}", .{err});
            return false;
        };
        return true;
    }

    /// Process raw bytes as terminal output.
    export fn ghostty_surface_process_output(
        surface_: ?*Surface,
        ptr: ?[*]const u8,
        len: usize,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_process_output") orelse return false;
        const bytes = cBytes(ptr, len, "ghostty_surface_process_output") orelse return false;
        if (bytes.len == 0) return true;
        surface.core_surface.io.processOutput(bytes);
        return true;
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
        surface_: ?*Surface,
        ptr: ?[*]const u8,
        len: usize,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_preedit") orelse return false;
        const preedit = if (len == 0) null else cUtf8Bytes(
            ptr,
            len,
            "ghostty_surface_preedit",
        ) orelse return false;
        surface.preeditCallback(preedit) catch |err| {
            log.err("error in preedit callback err={}", .{err});
            return false;
        };
        return true;
    }

    fn cBytes(ptr: ?[*]const u8, len: usize, comptime api_name: []const u8) ?[]const u8 {
        if (len == 0) return "";
        const raw = ptr orelse {
            log.warn("{s} called with null pointer and non-zero length", .{api_name});
            return null;
        };
        return raw[0..len];
    }

    fn cUtf8Bytes(ptr: ?[*]const u8, len: usize, comptime api_name: []const u8) ?[]const u8 {
        const bytes = cBytes(ptr, len, api_name) orelse return null;
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            log.warn("{s} called with invalid UTF-8 text bytes", .{api_name});
            return null;
        }
        return bytes;
    }

    fn cUtf8String(
        ptr: [*:0]const u8,
        comptime api_name: []const u8,
        comptime field_name: []const u8,
    ) ?[:0]const u8 {
        const text = std.mem.sliceTo(ptr, 0);
        if (!std.unicode.utf8ValidateSlice(text)) {
            log.warn("{s} called with invalid UTF-8 {s}", .{ api_name, field_name });
            return null;
        }
        return text;
    }

    fn appHandle(ptr: ?*App, comptime api_name: []const u8) ?*App {
        const app = ptr orelse {
            log.warn("{s} called with null app", .{api_name});
            return null;
        };
        if (app.isDestroying()) {
            log.warn("{s} called with destroying app", .{api_name});
            return null;
        }
        return app;
    }

    fn surfaceHandle(ptr: ?*Surface, comptime api_name: []const u8) ?*Surface {
        const surface = ptr orelse {
            log.warn("{s} called with null surface", .{api_name});
            return null;
        };
        if (surface.isDestroying()) {
            log.warn("{s} called with destroying surface", .{api_name});
            return null;
        }
        return surface;
    }

    fn configHandle(ptr: ?*const Config, comptime api_name: []const u8) ?*const Config {
        return ptr orelse {
            log.warn("{s} called with null config", .{api_name});
            return null;
        };
    }

    fn mutableConfigHandle(ptr: ?*Config, comptime api_name: []const u8) ?*Config {
        return ptr orelse {
            log.warn("{s} called with null config", .{api_name});
            return null;
        };
    }

    fn inspectorHandle(ptr: ?*Inspector, comptime api_name: []const u8) ?*Inspector {
        const inspector = ptr orelse {
            log.warn("{s} called with null inspector", .{api_name});
            return null;
        };
        if (inspector.surface.isDestroying()) {
            log.warn("{s} called with inspector for destroying surface", .{api_name});
            return null;
        }
        if (inspector.isDestroying()) {
            log.warn("{s} called with destroying inspector", .{api_name});
            return null;
        }
        return inspector;
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
    export fn ghostty_surface_mouse_captured(surface_: ?*Surface) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_mouse_captured") orelse return false;
        return surface.core_surface.mouseCaptured();
    }

    /// Tell the surface that it needs to schedule a render
    export fn ghostty_surface_mouse_button(
        surface_: ?*Surface,
        action_raw: c_int,
        button_raw: c_int,
        mods: c_int,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_mouse_button") orelse return false;
        const action = cEnum(
            input.MouseButtonState,
            action_raw,
            "ghostty_surface_mouse_button",
            "mouse button state",
        ) orelse return false;
        const button = cEnum(
            input.MouseButton,
            button_raw,
            "ghostty_surface_mouse_button",
            "mouse button",
        ) orelse return false;
        return surface.mouseButtonCallback(
            action,
            button,
            inputMods(mods),
        );
    }

    /// Update the mouse position within the view.
    export fn ghostty_surface_mouse_pos(
        surface_: ?*Surface,
        x: f64,
        y: f64,
        mods: c_int,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_mouse_pos") orelse return false;
        const point = sanitizePointerPoint(x, y) orelse {
            log.warn("ghostty_surface_mouse_pos called with non-finite coordinates x={} y={}", .{ x, y });
            return false;
        };
        return surface.cursorPosCallback(
            point.x,
            point.y,
            inputMods(mods),
        );
    }

    export fn ghostty_surface_mouse_scroll(
        surface_: ?*Surface,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_mouse_scroll") orelse return false;
        const delta = sanitizeScrollDelta(x, y) orelse {
            log.warn("ghostty_surface_mouse_scroll called with non-finite deltas x={} y={}", .{ x, y });
            return false;
        };
        return surface.scrollCallback(
            delta.x,
            delta.y,
            scrollMods(scroll_mods),
        );
    }

    export fn ghostty_surface_mouse_pressure(
        surface_: ?*Surface,
        stage_raw: c_int,
        pressure: f64,
    ) bool {
        const surface = surfaceHandle(surface_, "ghostty_surface_mouse_pressure") orelse return false;
        const input_stage = cEnum(
            input.MousePressureStage,
            stage_raw,
            "ghostty_surface_mouse_pressure",
            "mouse pressure stage",
        ) orelse return false;

        return surface.mousePressureCallback(input_stage, sanitizeMousePressure(pressure));
    }

    export fn ghostty_surface_ime_point(
        surface_: ?*Surface,
        x_: ?*f64,
        y_: ?*f64,
        width_: ?*f64,
        height_: ?*f64,
    ) bool {
        if (x_) |x| x.* = 0;
        if (y_) |y| y.* = 0;
        if (width_) |width| width.* = 0;
        if (height_) |height| height.* = 0;
        const surface = surfaceHandle(surface_, "ghostty_surface_ime_point") orelse return false;
        const x = x_ orelse {
            log.warn("ghostty_surface_ime_point called with null x output", .{});
            return false;
        };
        const y = y_ orelse {
            log.warn("ghostty_surface_ime_point called with null y output", .{});
            return false;
        };
        const width = width_ orelse {
            log.warn("ghostty_surface_ime_point called with null width output", .{});
            return false;
        };
        const height = height_ orelse {
            log.warn("ghostty_surface_ime_point called with null height output", .{});
            return false;
        };
        const pos = surface.core_surface.imePoint();
        x.* = pos.x;
        y.* = pos.y;
        width.* = pos.width;
        height.* = pos.height;
        return true;
    }

    /// Request that the surface become closed. This will go through the
    /// normal trigger process that a close surface input binding would.
    export fn ghostty_surface_request_close(ptr_: ?*Surface) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_request_close") orelse return false;
        ptr.core_surface.close();
        return true;
    }

    /// Request that the surface split in the given direction.
    export fn ghostty_surface_split(ptr_: ?*Surface, direction_raw: c_int) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_split") orelse return false;
        const direction = cEnum(
            apprt.action.SplitDirection,
            direction_raw,
            "ghostty_surface_split",
            "split direction",
        ) orelse return false;
        return ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .new_split,
            direction,
        ) catch |err| {
            log.err("error creating new split err={}", .{err});
            return false;
        };
    }

    /// Focus on the next split (if any).
    export fn ghostty_surface_split_focus(
        ptr_: ?*Surface,
        direction_raw: c_int,
    ) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_split_focus") orelse return false;
        const direction = cEnum(
            apprt.action.GotoSplit,
            direction_raw,
            "ghostty_surface_split_focus",
            "split focus direction",
        ) orelse return false;
        return ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .goto_split,
            direction,
        ) catch |err| {
            log.err("error focusing split err={}", .{err});
            return false;
        };
    }

    /// Resize the current split by moving the split divider in the given
    /// direction. `direction` specifies which direction the split divider will
    /// move relative to the focused split. `amount` is a fractional value
    /// between 0 and 1 that specifies by how much the divider will move.
    export fn ghostty_surface_split_resize(
        ptr_: ?*Surface,
        direction_raw: c_int,
        amount: u16,
    ) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_split_resize") orelse return false;
        const direction = cEnum(
            apprt.action.ResizeSplit.Direction,
            direction_raw,
            "ghostty_surface_split_resize",
            "split resize direction",
        ) orelse return false;
        return ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .resize_split,
            .{ .direction = direction, .amount = amount },
        ) catch |err| {
            log.err("error resizing split err={}", .{err});
            return false;
        };
    }

    /// Equalize the size of all splits in the current window.
    export fn ghostty_surface_split_equalize(ptr_: ?*Surface) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_split_equalize") orelse return false;
        return ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .equalize_splits,
            {},
        ) catch |err| {
            log.err("error equalizing splits err={}", .{err});
            return false;
        };
    }

    /// Toggle whether the current split is zoomed.
    export fn ghostty_surface_split_toggle_zoom(ptr_: ?*Surface) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_split_toggle_zoom") orelse return false;
        return ptr.app.performAction(
            .{ .surface = &ptr.core_surface },
            .toggle_split_zoom,
            {},
        ) catch |err| {
            log.err("error toggling split zoom err={}", .{err});
            return false;
        };
    }

    /// Invoke an action on the surface.
    export fn ghostty_surface_binding_action(
        ptr_: ?*Surface,
        action_ptr: ?[*]const u8,
        action_len: usize,
    ) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_binding_action") orelse return false;
        const action_str = cUtf8Bytes(action_ptr, action_len, "ghostty_surface_binding_action") orelse return false;
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
        ptr_: ?*Surface,
        str: ?[*:0]const u8,
        state_: ?*anyopaque,
        confirmed: bool,
    ) bool {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_complete_clipboard_request") orelse return false;
        const request_opaque = state_ orelse {
            log.warn("ghostty_surface_complete_clipboard_request called with null request", .{});
            return false;
        };

        if (comptime builtin.target.os.tag == .linux) {
            const request = ptr.takeClipboardRequestOpaque(request_opaque) orelse {
                log.warn(
                    "ghostty_surface_complete_clipboard_request called with unknown request",
                    .{},
                );
                return false;
            };

            // A completion consumes the pending request token. If the
            // embedder provides invalid text, reject the contents without
            // leaving a token that can be completed a second time.
            const text_ptr = str orelse {
                log.warn("ghostty_surface_complete_clipboard_request called with null text", .{});
                return false;
            };
            const text = cUtf8String(
                text_ptr,
                "ghostty_surface_complete_clipboard_request",
                "clipboard text",
            ) orelse return false;
            return ptr.completeClipboardRequestLinux(text, request, confirmed);
        }

        const text_ptr = str orelse {
            log.warn("ghostty_surface_complete_clipboard_request called with null text", .{});
            return false;
        };
        const text = cUtf8String(
            text_ptr,
            "ghostty_surface_complete_clipboard_request",
            "clipboard text",
        ) orelse return false;
        const request: *apprt.ClipboardRequest = @ptrCast(@alignCast(request_opaque));
        ptr.completeClipboardRequestNative(text, request, confirmed);
        return true;
    }

    export fn ghostty_surface_inspector(ptr_: ?*Surface) ?*Inspector {
        const ptr = surfaceHandle(ptr_, "ghostty_surface_inspector") orelse return null;
        return ptr.initInspector() catch |err| {
            switch (err) {
                error.InspectorDestroying => log.warn("ghostty_surface_inspector called while inspector is destroying", .{}),
                else => log.err("error initializing inspector err={}", .{err}),
            }
            return null;
        };
    }

    export fn ghostty_inspector_free(ptr_: ?*Inspector) void {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_free") orelse return;
        ptr.surface.freeInspector();
    }

    export fn ghostty_inspector_set_size(ptr_: ?*Inspector, w: u32, h: u32) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_set_size") orelse return false;
        ptr.updateSize(w, h);
        return true;
    }

    export fn ghostty_inspector_set_content_scale(ptr_: ?*Inspector, x: f64, y: f64) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_set_content_scale") orelse return false;
        ptr.updateContentScale(x, y);
        return true;
    }

    export fn ghostty_inspector_mouse_button(
        ptr_: ?*Inspector,
        action_raw: c_int,
        button_raw: c_int,
        mods: c_int,
    ) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_mouse_button") orelse return false;
        const action = cEnum(
            input.MouseButtonState,
            action_raw,
            "ghostty_inspector_mouse_button",
            "mouse button state",
        ) orelse return false;
        const button = cEnum(
            input.MouseButton,
            button_raw,
            "ghostty_inspector_mouse_button",
            "mouse button",
        ) orelse return false;
        return ptr.mouseButtonCallback(
            action,
            button,
            inputMods(mods),
        );
    }

    export fn ghostty_inspector_mouse_pos(ptr_: ?*Inspector, x: f64, y: f64) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_mouse_pos") orelse return false;
        const point = sanitizePointerPoint(x, y) orelse {
            log.warn("ghostty_inspector_mouse_pos called with non-finite coordinates x={} y={}", .{ x, y });
            return false;
        };
        ptr.cursorPosCallback(point.x, point.y);
        return true;
    }

    export fn ghostty_inspector_mouse_scroll(
        ptr_: ?*Inspector,
        x: f64,
        y: f64,
        scroll_mods: c_int,
    ) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_mouse_scroll") orelse return false;
        const delta = sanitizeScrollDelta(x, y) orelse {
            log.warn("ghostty_inspector_mouse_scroll called with non-finite deltas x={} y={}", .{ x, y });
            return false;
        };
        ptr.scrollCallback(
            delta.x,
            delta.y,
            scrollMods(scroll_mods),
        );
        return true;
    }

    export fn ghostty_inspector_key(
        ptr_: ?*Inspector,
        action_raw: c_int,
        key_raw: c_int,
        c_mods: c_int,
    ) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_key") orelse return false;
        const action = cEnum(
            input.Action,
            action_raw,
            "ghostty_inspector_key",
            "key action",
        ) orelse return false;
        const key = cEnum(
            input.Key,
            key_raw,
            "ghostty_inspector_key",
            "key",
        ) orelse return false;
        ptr.keyCallback(
            action,
            key,
            inputMods(c_mods),
        ) catch |err| {
            log.err("error processing key event err={}", .{err});
            return false;
        };
        return true;
    }

    export fn ghostty_inspector_text(
        ptr_: ?*Inspector,
        str: ?[*:0]const u8,
    ) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_text") orelse return false;
        const text_ptr = str orelse {
            log.warn("ghostty_inspector_text called with null text", .{});
            return false;
        };
        const text = cUtf8String(text_ptr, "ghostty_inspector_text", "text") orelse return false;
        ptr.textCallback(text);
        return true;
    }

    export fn ghostty_inspector_set_focus(ptr_: ?*Inspector, focused: bool) bool {
        const ptr = inspectorHandle(ptr_, "ghostty_inspector_set_focus") orelse return false;
        ptr.focusCallback(focused);
        return true;
    }

    // Darwin-only C APIs.
    const Darwin = struct {
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

        export fn ghostty_inspector_metal_shutdown(ptr: *Inspector) bool {
            if (ptr.backend) |v| {
                v.deinit();
                ptr.backend = null;
            }
            return true;
        }
    };

    // Linux-only C APIs.
    const Linux = struct {
        export fn ghostty_inspector_opengl_init(
            ptr_: ?*Inspector,
            glsl_version: ?[*:0]const u8,
        ) bool {
            const ptr = inspectorHandle(ptr_, "ghostty_inspector_opengl_init") orelse return false;
            if (!ptr.makeOpenGLContextCurrent("ghostty_inspector_opengl_init")) return false;
            defer ptr.doneOpenGLContext();
            return ptr.initOpenGL(glsl_version);
        }

        export fn ghostty_inspector_opengl_render(ptr_: ?*Inspector) bool {
            const ptr = inspectorHandle(ptr_, "ghostty_inspector_opengl_render") orelse return false;
            if (!ptr.makeOpenGLContextCurrent("ghostty_inspector_opengl_render")) return false;
            defer ptr.doneOpenGLContext();
            ptr.renderOpenGL() catch |err| {
                switch (err) {
                    error.InspectorOpenGLNotInitialized => log.warn("OpenGL inspector render requested before backend initialization", .{}),
                    else => log.err("error rendering OpenGL inspector err={}", .{err}),
                }
                return false;
            };
            return true;
        }

        export fn ghostty_inspector_opengl_shutdown(ptr_: ?*Inspector) bool {
            const ptr = inspectorHandle(ptr_, "ghostty_inspector_opengl_shutdown") orelse return false;
            return ptr.deinitBackend("ghostty_inspector_opengl_shutdown", .preserve_on_context_loss);
        }
    };
};

test "CAPI cBytes accepts null only for empty input" {
    if (comptime embedded_runtime_tests) {
        const bytes = "hello";
        try std.testing.expectEqualStrings(bytes, CAPI.cBytes(bytes.ptr, bytes.len, "test").?);
        try std.testing.expectEqualStrings("", CAPI.cBytes(null, 0, "test").?);
        try std.testing.expect(CAPI.cBytes(null, 1, "test") == null);
    } else return error.SkipZigTest;
}

test "CAPI UTF-8 helpers validate text inputs" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const valid = "hello";
    try std.testing.expectEqualStrings(
        valid,
        CAPI.cUtf8Bytes(valid.ptr, valid.len, "test").?,
    );
    try std.testing.expectEqualStrings(
        valid,
        CAPI.cUtf8String(valid.ptr, "test", "text").?,
    );

    const invalid_bytes = [_]u8{0xFF};
    try std.testing.expect(CAPI.cUtf8Bytes(
        invalid_bytes[0..].ptr,
        invalid_bytes.len,
        "test",
    ) == null);

    const invalid_string = [_:0]u8{0xFF};
    try std.testing.expect(CAPI.cUtf8String(
        invalid_string[0..].ptr,
        "test",
        "text",
    ) == null);

    const binding_action = "copy_title_to_clipboard";
    try std.testing.expectEqualStrings(
        binding_action,
        CAPI.cUtf8Bytes(
            binding_action.ptr,
            binding_action.len,
            "ghostty_surface_binding_action",
        ).?,
    );
}

test "CAPI validates raw key event action enum values" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var event = std.mem.zeroes(CAPI.KeyEvent);
    event.action = @intFromEnum(input.Action.press);
    try std.testing.expect(event.keyEvent("test").?.action == .press);

    const valid_text = "a";
    event.text = valid_text.ptr;
    try std.testing.expectEqualStrings(valid_text, event.keyEvent("test").?.text.?);

    const invalid_text = [_:0]u8{0xFF};
    event.text = invalid_text[0..].ptr;
    try std.testing.expect(event.keyEvent("test") == null);

    event.text = null;
    event.action = 99;
    try std.testing.expect(event.keyEvent("test") == null);
}

test "CAPI key events accept encoded physical key values" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const c = @import("ghostty.h");
    try std.testing.expectEqual(
        App.keycode_native_mask,
        @as(u32, @intCast(c.GHOSTTY_INPUT_KEYCODE_NATIVE_MASK)),
    );
    try std.testing.expectEqual(
        App.keycode_physical_key_flag,
        @as(u32, @intCast(c.GHOSTTY_INPUT_KEYCODE_PHYSICAL_KEY_FLAG)),
    );

    var event = std.mem.zeroes(CAPI.KeyEvent);
    event.action = @intFromEnum(input.Action.press);
    event.keycode = App.keycode_physical_key_flag |
        @as(u32, @intCast(@intFromEnum(input.Key.f25)));
    try std.testing.expectEqual(input.Key.f25, event.keyEvent("test").?.core().?.key);

    event.keycode = App.keycode_physical_key_flag |
        @as(u32, @intCast(@intFromEnum(input.Key.enter)));
    try std.testing.expectEqual(input.Key.enter, event.keyEvent("test").?.core().?.key);

    event.keycode = App.keycode_physical_key_flag | App.keycode_native_mask;
    try std.testing.expectEqual(input.Key.unidentified, event.keyEvent("test").?.core().?.key);
}

test "CAPI validates raw mouse and split enum values" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(
        input.MouseButton.left,
        CAPI.cEnum(input.MouseButton, @intFromEnum(input.MouseButton.left), "test", "mouse button").?,
    );
    try std.testing.expect(CAPI.cEnum(input.MouseButton, 99, "test", "mouse button") == null);

    try std.testing.expectEqual(
        input.MousePressureStage.normal,
        CAPI.cEnum(
            input.MousePressureStage,
            @intFromEnum(input.MousePressureStage.normal),
            "test",
            "mouse pressure stage",
        ).?,
    );
    try std.testing.expect(CAPI.cEnum(
        input.MousePressureStage,
        99,
        "test",
        "mouse pressure stage",
    ) == null);

    try std.testing.expectEqual(
        apprt.action.SplitDirection.right,
        CAPI.cEnum(
            apprt.action.SplitDirection,
            @intFromEnum(apprt.action.SplitDirection.right),
            "test",
            "split direction",
        ).?,
    );
    try std.testing.expect(CAPI.cEnum(
        apprt.action.ResizeSplit.Direction,
        -1,
        "test",
        "split resize direction",
    ) == null);
}

test "ghostty.h mouse button ABI aliases cover terminal tracking range" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const c = @import("ghostty.h");
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_UNKNOWN, @intFromEnum(input.MouseButton.unknown));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_LEFT, @intFromEnum(input.MouseButton.left));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_RIGHT, @intFromEnum(input.MouseButton.right));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_MIDDLE, @intFromEnum(input.MouseButton.middle));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_FOUR, @intFromEnum(input.MouseButton.four));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_FIVE, @intFromEnum(input.MouseButton.five));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_SIX, @intFromEnum(input.MouseButton.six));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_SEVEN, @intFromEnum(input.MouseButton.seven));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_EIGHT, @intFromEnum(input.MouseButton.eight));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_NINE, @intFromEnum(input.MouseButton.nine));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_TEN, @intFromEnum(input.MouseButton.ten));
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_BUTTON_ELEVEN, @intFromEnum(input.MouseButton.eleven));
}

test "ghostty.h function key ABI constants cover Linux inspector range" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const c = @import("ghostty.h");
    try std.testing.expectEqual(c.GHOSTTY_KEY_ESCAPE, @intFromEnum(input.Key.escape));
    try std.testing.expectEqual(c.GHOSTTY_KEY_F1, @intFromEnum(input.Key.f1));
    try std.testing.expectEqual(c.GHOSTTY_KEY_F12, @intFromEnum(input.Key.f12));
    try std.testing.expectEqual(c.GHOSTTY_KEY_F13, @intFromEnum(input.Key.f13));
    try std.testing.expectEqual(c.GHOSTTY_KEY_F24, @intFromEnum(input.Key.f24));
    try std.testing.expectEqual(c.GHOSTTY_KEY_F25, @intFromEnum(input.Key.f25));
    try std.testing.expectEqual(c.GHOSTTY_KEY_FN, @intFromEnum(input.Key.@"fn"));
    try std.testing.expectEqual(c.GHOSTTY_KEY_FN_LOCK, @intFromEnum(input.Key.fn_lock));
    try std.testing.expectEqual(c.GHOSTTY_KEY_PRINT_SCREEN, @intFromEnum(input.Key.print_screen));
    try std.testing.expectEqual(c.GHOSTTY_KEY_SCROLL_LOCK, @intFromEnum(input.Key.scroll_lock));
    try std.testing.expectEqual(c.GHOSTTY_KEY_PAUSE, @intFromEnum(input.Key.pause));
}

test "CAPI embedding info reports runtime contract" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const c = @import("ghostty.h");
    const info = CAPI.ghostty_embedding_info();
    var queried = std.mem.zeroes(CAPI.EmbeddingInfo);
    try std.testing.expect(CAPI.ghostty_embedding_info_query(
        &queried,
        @sizeOf(CAPI.EmbeddingInfo),
    ));
    try std.testing.expectEqualDeep(info, queried);
    var expected_bytes: [@sizeOf(CAPI.EmbeddingInfo)]u8 = undefined;
    @memcpy(&expected_bytes, std.mem.asBytes(&queried));
    @memset(std.mem.asBytes(&queried), 0xA5);
    try std.testing.expect(!CAPI.ghostty_embedding_info_query(
        &queried,
        @sizeOf(CAPI.EmbeddingInfo) - 1,
    ));
    try std.testing.expectEqualSlices(
        u8,
        expected_bytes[0 .. @sizeOf(CAPI.EmbeddingInfo) - 1],
        std.mem.asBytes(&queried)[0 .. @sizeOf(CAPI.EmbeddingInfo) - 1],
    );
    try std.testing.expectEqual(@as(u8, 0xA5), std.mem.asBytes(&queried)[@sizeOf(CAPI.EmbeddingInfo) - 1]);
    const OversizedEmbeddingInfo = extern struct {
        info: CAPI.EmbeddingInfo,
        future_field: u64,
    };
    var oversized: OversizedEmbeddingInfo = undefined;
    @memset(std.mem.asBytes(&oversized), 0xA5);
    try std.testing.expect(CAPI.ghostty_embedding_info_query(
        &oversized.info,
        @sizeOf(OversizedEmbeddingInfo),
    ));
    try std.testing.expectEqualDeep(info, oversized.info);
    try std.testing.expectEqual(@as(u64, 0), oversized.future_field);
    try std.testing.expect(!CAPI.ghostty_embedding_info_query(
        null,
        @sizeOf(CAPI.EmbeddingInfo),
    ));
    try std.testing.expectEqual(@as(u32, embedding_abi_version), info.abi_version);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(CAPI.rendererBackend())), info.renderer_backend);
    try std.testing.expectEqual(@as(usize, max_surface_env_vars), info.surface_max_env_vars);
    try std.testing.expectEqual(builtin.target.os.tag == .linux, info.supports_linux_platform);
    try std.testing.expectEqual(App.must_draw_from_app_thread, info.must_draw_from_app_thread);
    try std.testing.expectEqual(@as(usize, @sizeOf(RuntimeOptions)), info.runtime_config_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(apprt.Surface.Options)), info.surface_config_size);
    try std.testing.expectEqual(
        @as(usize, if (builtin.target.os.tag == .linux) @sizeOf(c.ghostty_platform_linux_s) else 0),
        info.platform_linux_size,
    );
    try std.testing.expectEqual(CAPI.platformLinuxAbiSize(), info.platform_linux_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(CAPI.KeyEvent)), info.input_key_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(apprt.Target.C)), info.target_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(apprt.Action.C)), info.action_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(CAPI.Text)), info.text_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(CAPI.Selection)), info.selection_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(String)), info.string_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(CAPI.SurfaceSize)), info.surface_size_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(CAPI.Diagnostic)), info.diagnostic_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(EnvVar)), info.env_var_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(CAPI.ClipboardContent)), info.clipboard_content_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(input.Binding.Trigger.C)), info.input_trigger_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(apprt.ipc.Target.C)), info.ipc_target_size);
    try std.testing.expectEqual(@as(usize, @sizeOf(apprt.ipc.Action.C)), info.ipc_action_size);
    try std.testing.expectEqual(@as(usize, @alignOf(RuntimeOptions)), info.runtime_config_align);
    try std.testing.expectEqual(@as(usize, @alignOf(apprt.Surface.Options)), info.surface_config_align);
    try std.testing.expectEqual(
        @as(usize, if (builtin.target.os.tag == .linux) @alignOf(c.ghostty_platform_linux_s) else 0),
        info.platform_linux_align,
    );
    try std.testing.expectEqual(CAPI.platformLinuxAbiAlign(), info.platform_linux_align);
    try std.testing.expectEqual(CAPI.layoutFingerprint(), info.layout_fingerprint);
    try std.testing.expectEqual(CAPI.constantsFingerprint(), info.constants_fingerprint);
    try std.testing.expectEqual(@as(usize, @alignOf(CAPI.KeyEvent)), info.input_key_align);
    try std.testing.expectEqual(@as(usize, @alignOf(apprt.Target.C)), info.target_align);
    try std.testing.expectEqual(@as(usize, @alignOf(apprt.Action.C)), info.action_align);
    try std.testing.expectEqual(@as(usize, @alignOf(CAPI.Text)), info.text_align);
    try std.testing.expectEqual(@as(usize, @alignOf(CAPI.Selection)), info.selection_align);
    try std.testing.expectEqual(@as(usize, @alignOf(String)), info.string_align);
    try std.testing.expectEqual(@as(usize, @alignOf(CAPI.SurfaceSize)), info.surface_size_align);
    try std.testing.expectEqual(@as(usize, @alignOf(CAPI.Diagnostic)), info.diagnostic_align);
    try std.testing.expectEqual(@as(usize, @alignOf(EnvVar)), info.env_var_align);
    try std.testing.expectEqual(@as(usize, @alignOf(CAPI.ClipboardContent)), info.clipboard_content_align);
    try std.testing.expectEqual(@as(usize, @alignOf(input.Binding.Trigger.C)), info.input_trigger_align);
    try std.testing.expectEqual(@as(usize, @alignOf(apprt.ipc.Target.C)), info.ipc_target_align);
    try std.testing.expectEqual(@as(usize, @alignOf(apprt.ipc.Action.C)), info.ipc_action_align);
    try std.testing.expectEqual(
        switch (builtin.target.os.tag) {
            .linux => @as(c_int, @intFromEnum(PlatformTag.linux)),
            .macos => @as(c_int, @intFromEnum(PlatformTag.macos)),
            .ios => @as(c_int, @intFromEnum(PlatformTag.ios)),
            else => 0,
        },
        info.platform,
    );
}

const CmuxRequiredExportOwner = enum {
    main_c,
    config_capi,
    embedded_capi,
    linux_capi,
};

const CmuxRequiredExport = struct {
    name: []const u8,
    owner: CmuxRequiredExportOwner,
};

const cmux_linux_required_exports = [_]CmuxRequiredExport{
    .{ .name = "ghostty_init", .owner = .main_c },
    .{ .name = "ghostty_string_free", .owner = .main_c },
    .{ .name = "ghostty_embedding_info", .owner = .embedded_capi },
    .{ .name = "ghostty_embedding_info_query", .owner = .embedded_capi },
    .{ .name = "ghostty_config_new", .owner = .config_capi },
    .{ .name = "ghostty_config_free", .owner = .config_capi },
    .{ .name = "ghostty_config_load_cli_args", .owner = .config_capi },
    .{ .name = "ghostty_config_load_file", .owner = .config_capi },
    .{ .name = "ghostty_config_load_string", .owner = .config_capi },
    .{ .name = "ghostty_config_load_default_files", .owner = .config_capi },
    .{ .name = "ghostty_config_load_recursive_files", .owner = .config_capi },
    .{ .name = "ghostty_config_finalize", .owner = .config_capi },
    .{ .name = "ghostty_config_get", .owner = .config_capi },
    .{ .name = "ghostty_config_diagnostics_count", .owner = .config_capi },
    .{ .name = "ghostty_config_get_diagnostic", .owner = .config_capi },
    .{ .name = "ghostty_config_open_path", .owner = .config_capi },
    .{ .name = "ghostty_resources_dir", .owner = .main_c },
    .{ .name = "ghostty_app_new", .owner = .embedded_capi },
    .{ .name = "ghostty_app_free", .owner = .embedded_capi },
    .{ .name = "ghostty_app_tick", .owner = .embedded_capi },
    .{ .name = "ghostty_app_userdata", .owner = .embedded_capi },
    .{ .name = "ghostty_app_set_focus", .owner = .embedded_capi },
    .{ .name = "ghostty_app_key", .owner = .embedded_capi },
    .{ .name = "ghostty_app_keyboard_changed", .owner = .embedded_capi },
    .{ .name = "ghostty_app_open_config", .owner = .embedded_capi },
    .{ .name = "ghostty_app_reload_config", .owner = .embedded_capi },
    .{ .name = "ghostty_app_update_config", .owner = .embedded_capi },
    .{ .name = "ghostty_app_needs_confirm_quit", .owner = .embedded_capi },
    .{ .name = "ghostty_app_has_global_keybinds", .owner = .embedded_capi },
    .{ .name = "ghostty_app_must_draw_from_app_thread", .owner = .embedded_capi },
    .{ .name = "ghostty_app_set_color_scheme", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_config_new", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_new", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_free", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_userdata", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_app", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_inherited_config", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_inherited_config_free", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_update_config", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_refresh", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_draw", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_display_realized", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_display_unrealized", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_renderer_realized", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_content_scale", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_focus", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_visible", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_occlusion", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_size", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_set_color_scheme", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_needs_confirm_quit", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_size", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_process_exited", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_foreground_pid", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_tty_name", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_title", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_pwd", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_key_translation_mods", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_key", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_key_is_binding", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_text", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_process_output", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_preedit", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_mouse_captured", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_mouse_button", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_mouse_pos", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_mouse_scroll", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_mouse_pressure", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_ime_point", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_request_close", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_split", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_split_focus", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_split_resize", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_split_equalize", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_split_toggle_zoom", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_binding_action", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_has_selection", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_select_cursor_cell", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_select_viewport_rows", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_clear_selection", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_read_selection", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_complete_clipboard_request", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_read_text", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_read_scrollback", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_free_text", .owner = .embedded_capi },
    .{ .name = "ghostty_surface_inspector", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_free", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_set_focus", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_set_content_scale", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_set_size", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_mouse_button", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_mouse_pos", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_mouse_scroll", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_key", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_text", .owner = .embedded_capi },
    .{ .name = "ghostty_inspector_opengl_init", .owner = .linux_capi },
    .{ .name = "ghostty_inspector_opengl_render", .owner = .linux_capi },
    .{ .name = "ghostty_inspector_opengl_shutdown", .owner = .linux_capi },
};

fn expectCmuxRequiredExportsAreUnique() !void {
    for (cmux_linux_required_exports, 0..) |symbol, index| {
        for (cmux_linux_required_exports, 0..) |other, other_index| {
            if (index < other_index) {
                try std.testing.expect(!std.mem.eql(u8, symbol.name, other.name));
            }
        }
    }
}

fn expectCmuxRequiredExportDeclared(
    comptime header: anytype,
    comptime main_c: anytype,
    comptime symbol: CmuxRequiredExport,
) !void {
    try std.testing.expect(@hasDecl(header, symbol.name));
    switch (symbol.owner) {
        .main_c => try std.testing.expect(@hasDecl(main_c, symbol.name)),
        .config_capi => try std.testing.expect(@hasDecl(configpkg.CApi, symbol.name)),
        .embedded_capi => try std.testing.expect(@hasDecl(CAPI, symbol.name)),
        .linux_capi => try std.testing.expect(@hasDecl(CAPI.Linux, symbol.name)),
    }
}

test "cmux Linux embedding required exports stay declared" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;
    if (comptime builtin.target.os.tag != .linux) return error.SkipZigTest;

    const c = @import("ghostty.h");
    const main_c = @import("../main_c.zig");

    try std.testing.expectEqual(@as(usize, 98), cmux_linux_required_exports.len);
    try expectCmuxRequiredExportsAreUnique();
    inline for (cmux_linux_required_exports) |symbol| {
        try expectCmuxRequiredExportDeclared(c, main_c, symbol);
    }
}

test "CAPI exported config handles reject null" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expect(!CAPI.ghostty_config_key_is_binding(
        null,
        std.mem.zeroes(CAPI.KeyEvent),
    ));
}

test "CAPI exported app handles reject null" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expect(!CAPI.ghostty_app_tick(null));
    try std.testing.expect(CAPI.ghostty_app_userdata(null) == null);
    CAPI.ghostty_app_free(null);
    try std.testing.expect(!CAPI.ghostty_app_set_focus(null, true));
    try std.testing.expect(!CAPI.ghostty_app_keyboard_changed(null));
    try std.testing.expect(!CAPI.ghostty_app_open_config(null));
    try std.testing.expect(!CAPI.ghostty_app_reload_config(null, true));
    try std.testing.expect(!CAPI.ghostty_app_update_config(null, null));
    try std.testing.expect(!CAPI.ghostty_app_needs_confirm_quit(null));
    try std.testing.expect(!CAPI.ghostty_app_has_global_keybinds(null));
    try std.testing.expect(!CAPI.ghostty_app_must_draw_from_app_thread(null));
    try std.testing.expect(!CAPI.ghostty_app_set_color_scheme(
        null,
        @intFromEnum(apprt.ColorScheme.dark),
    ));
}

test "embedded app teardown gate rejects reentrant surface creation" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var app: App = undefined;
    app.destroying = .init(false);

    try std.testing.expect(!app.isDestroying());
    try std.testing.expect(app.beginDestroy());
    try std.testing.expect(app.isDestroying());
    try std.testing.expect(!app.beginDestroy());

    const opts: Surface.Options = .{};
    try std.testing.expectError(
        error.AppDestroying,
        CAPI.surface_new_(&app, &opts, 0),
    );
}

test "CAPI app draw thread requirement reflects runtime" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var app: App = undefined;
    app.destroying = .init(false);
    try std.testing.expectEqual(
        builtin.target.os.tag == .linux,
        CAPI.ghostty_app_must_draw_from_app_thread(&app),
    );
}

test "CAPI exported app handles reject destroying apps" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var app: App = undefined;
    app.destroying = .init(true);

    try std.testing.expect(!CAPI.ghostty_app_tick(&app));
    try std.testing.expect(CAPI.ghostty_app_userdata(&app) == null);
    CAPI.ghostty_app_free(&app);
    try std.testing.expect(!CAPI.ghostty_app_set_focus(&app, true));
    try std.testing.expect(!CAPI.ghostty_app_key(
        &app,
        std.mem.zeroes(CAPI.KeyEvent),
    ));
    try std.testing.expect(!CAPI.ghostty_app_keyboard_changed(&app));
    try std.testing.expect(!CAPI.ghostty_app_open_config(&app));
    try std.testing.expect(!CAPI.ghostty_app_reload_config(&app, true));
    try std.testing.expect(!CAPI.ghostty_app_update_config(&app, null));
    try std.testing.expect(!CAPI.ghostty_app_needs_confirm_quit(&app));
    try std.testing.expect(!CAPI.ghostty_app_has_global_keybinds(&app));
    try std.testing.expect(!CAPI.ghostty_app_must_draw_from_app_thread(&app));
    try std.testing.expect(!CAPI.ghostty_app_set_color_scheme(
        &app,
        @intFromEnum(apprt.ColorScheme.dark),
    ));
}

test "CAPI action helpers propagate embedder handled result" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const Callbacks = struct {
        var accepted: bool = false;
        var last_action: ?apprt.Action.Key = null;

        fn wakeup(_: ?*anyopaque) callconv(.c) void {}

        fn action(
            _: ?*anyopaque,
            _: apprt.Target.C,
            value: apprt.Action.C,
        ) callconv(.c) bool {
            last_action = value.key;
            return accepted;
        }

        fn readClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: ?*anyopaque,
        ) callconv(.c) bool {
            return false;
        }

        fn confirmReadClipboard(
            _: ?*anyopaque,
            _: [*c]const u8,
            _: ?*anyopaque,
            _: c_int,
        ) callconv(.c) void {}

        fn writeClipboard(
            _: ?*anyopaque,
            _: c_int,
            _: [*c]const RuntimeClipboardContent,
            _: usize,
            _: bool,
        ) callconv(.c) void {}

        fn redrawSurface(_: ?*anyopaque) callconv(.c) void {}
    };

    var app: App = undefined;
    app.destroying = .init(false);
    app.opts = try ValidatedRuntimeOptions.init(.{
        .wakeup = Callbacks.wakeup,
        .action = Callbacks.action,
        .read_clipboard = Callbacks.readClipboard,
        .confirm_read_clipboard = Callbacks.confirmReadClipboard,
        .write_clipboard = Callbacks.writeClipboard,
        .redraw_surface = if (builtin.target.os.tag == .linux) Callbacks.redrawSurface else null,
    });

    var surface: Surface = undefined;
    surface.app = &app;
    surface.destroying = .init(false);
    surface.core_surface.rt_surface = &surface;

    const expected_actions = [_]apprt.Action.Key{
        .open_config,
        .reload_config,
        .new_split,
        .goto_split,
        .resize_split,
        .equalize_splits,
        .toggle_split_zoom,
    };

    inline for ([_]bool{ false, true }) |accepted| {
        Callbacks.accepted = accepted;

        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_app_open_config(&app),
        );
        try std.testing.expectEqual(expected_actions[0], Callbacks.last_action.?);
        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_app_reload_config(&app, true),
        );
        try std.testing.expectEqual(expected_actions[1], Callbacks.last_action.?);
        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_surface_split(
                &surface,
                @intFromEnum(apprt.action.SplitDirection.right),
            ),
        );
        try std.testing.expectEqual(expected_actions[2], Callbacks.last_action.?);
        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_surface_split_focus(
                &surface,
                @intFromEnum(apprt.action.GotoSplit.next),
            ),
        );
        try std.testing.expectEqual(expected_actions[3], Callbacks.last_action.?);
        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_surface_split_resize(
                &surface,
                @intFromEnum(apprt.action.ResizeSplit.Direction.right),
                1,
            ),
        );
        try std.testing.expectEqual(expected_actions[4], Callbacks.last_action.?);
        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_surface_split_equalize(&surface),
        );
        try std.testing.expectEqual(expected_actions[5], Callbacks.last_action.?);
        try std.testing.expectEqual(
            accepted,
            CAPI.ghostty_surface_split_toggle_zoom(&surface),
        );
        try std.testing.expectEqual(expected_actions[6], Callbacks.last_action.?);
    }
}

test "CAPI surface config initializer clears platform union" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const config = CAPI.ghostty_surface_config_new();

    try std.testing.expectEqual(@as(c_int, 0), config.platform_tag);
    try std.testing.expect(config.platform.linux_gl.userdata == null);
    try std.testing.expect(config.platform.linux_gl.make_current == null);
    try std.testing.expect(config.platform.linux_gl.get_proc_address == null);
    try std.testing.expect(config.platform.linux_gl.done_current == null);
    try std.testing.expectEqual(@as(f64, 1), config.scale_factor);
    try std.testing.expectEqual(@as(f32, 0), config.font_size);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.surface.NewSurfaceContext.window)),
        config.context,
    );
}

test "CAPI exported surface handles reject null" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expect(CAPI.ghostty_surface_userdata(null) == null);
    try std.testing.expect(CAPI.ghostty_surface_app(null) == null);

    var inherited = CAPI.ghostty_surface_inherited_config(
        null,
        @intFromEnum(apprt.surface.NewSurfaceContext.window),
    );
    try std.testing.expect(inherited.working_directory == null);
    CAPI.ghostty_surface_inherited_config_free(null, &inherited);

    const stale_wd: [:0]const u8 = "/tmp/cmux-stale-inherited-config";
    var stale_inherited: apprt.Surface.Options = .{
        .font_size = 13,
        .working_directory = stale_wd.ptr,
        .wait_after_command = true,
    };
    CAPI.ghostty_surface_inherited_config_free(null, &stale_inherited);
    try std.testing.expect(stale_inherited.working_directory == null);
    try std.testing.expectEqual(@as(f32, 0), stale_inherited.font_size);
    try std.testing.expect(!stale_inherited.wait_after_command);

    try std.testing.expect(!CAPI.ghostty_surface_update_config(null, null));
    try std.testing.expect(!CAPI.ghostty_surface_needs_confirm_quit(null));
    try std.testing.expect(!CAPI.ghostty_surface_process_exited(null));
    try std.testing.expect(!CAPI.ghostty_surface_has_selection(null));
    try std.testing.expect(!CAPI.ghostty_surface_select_cursor_cell(null));
    try std.testing.expect(!CAPI.ghostty_surface_select_viewport_rows(null, 0, 0));
    try std.testing.expect(!CAPI.ghostty_surface_clear_selection(null));

    const stale_text: [:0]const u8 = "cmux stale ghostty text";
    var text: CAPI.Text = .{
        .tl_px_x = 12,
        .tl_px_y = 24,
        .offset_start = 1,
        .offset_len = 4,
        .text = stale_text.ptr,
        .text_len = stale_text.len,
    };
    try std.testing.expect(!CAPI.ghostty_surface_read_selection(null, &text));
    try std.testing.expectEqual(std.mem.zeroes(CAPI.Text), text);

    text = .{
        .tl_px_x = 12,
        .tl_px_y = 24,
        .offset_start = 1,
        .offset_len = 4,
        .text = stale_text.ptr,
        .text_len = stale_text.len,
    };
    try std.testing.expect(!CAPI.ghostty_surface_read_text(
        null,
        std.mem.zeroes(CAPI.Selection),
        &text,
    ));
    try std.testing.expectEqual(std.mem.zeroes(CAPI.Text), text);
    text = .{
        .tl_px_x = 12,
        .tl_px_y = 24,
        .offset_start = 1,
        .offset_len = 4,
        .text = stale_text.ptr,
        .text_len = stale_text.len,
    };
    try std.testing.expect(!CAPI.ghostty_surface_read_scrollback(null, 4096, &text));
    try std.testing.expectEqual(std.mem.zeroes(CAPI.Text), text);
    CAPI.ghostty_surface_free_text(null, null);

    try std.testing.expect(!CAPI.ghostty_surface_refresh(null));
    try std.testing.expect(!CAPI.ghostty_surface_draw(null));
    try std.testing.expect(!CAPI.ghostty_surface_display_realized(null));
    try std.testing.expect(!CAPI.ghostty_surface_display_unrealized(null));
    try std.testing.expect(!CAPI.ghostty_surface_set_renderer_realized(null, true));
    try std.testing.expect(!CAPI.ghostty_surface_set_size(null, 80, 24));
    try std.testing.expectEqual(
        std.mem.zeroes(CAPI.SurfaceSize),
        CAPI.ghostty_surface_size(null),
    );
    try std.testing.expectEqual(@as(u64, 0), CAPI.ghostty_surface_foreground_pid(null));
    const tty_name = CAPI.ghostty_surface_tty_name(null);
    try std.testing.expect(tty_name.ptr == null);
    try std.testing.expectEqual(@as(usize, 0), tty_name.len);
    const title = CAPI.ghostty_surface_title(null);
    try std.testing.expect(title.ptr == null);
    try std.testing.expectEqual(@as(usize, 0), title.len);
    const pwd = CAPI.ghostty_surface_pwd(null);
    try std.testing.expect(pwd.ptr == null);
    try std.testing.expectEqual(@as(usize, 0), pwd.len);
    try std.testing.expect(!CAPI.ghostty_surface_set_color_scheme(
        null,
        @intFromEnum(apprt.ColorScheme.dark),
    ));
    try std.testing.expect(!CAPI.ghostty_surface_set_content_scale(null, 1, 1));
    try std.testing.expect(!CAPI.ghostty_surface_set_focus(null, true));
    try std.testing.expect(!CAPI.ghostty_surface_set_visible(null, true));
    try std.testing.expect(!CAPI.ghostty_surface_set_occlusion(null, true));
    try std.testing.expectEqual(@as(c_int, 123), CAPI.ghostty_surface_key_translation_mods(null, 123));
    var binding_flags: input.Binding.Flags.C = 0xFF;
    try std.testing.expect(!CAPI.ghostty_surface_key_is_binding(
        null,
        std.mem.zeroes(CAPI.KeyEvent),
        &binding_flags,
    ));
    try std.testing.expectEqual(@as(input.Binding.Flags.C, 0), binding_flags);
    try std.testing.expect(!CAPI.ghostty_surface_text(null, null, 0));
    try std.testing.expect(!CAPI.ghostty_surface_preedit(null, null, 0));
    try std.testing.expect(!CAPI.ghostty_surface_mouse_captured(null));
    try std.testing.expect(!CAPI.ghostty_surface_mouse_button(
        null,
        @intFromEnum(input.MouseButtonState.release),
        @intFromEnum(input.MouseButton.left),
        0,
    ));
    try std.testing.expect(!CAPI.ghostty_surface_mouse_pos(null, 0, 0, 0));
    try std.testing.expect(!CAPI.ghostty_surface_mouse_scroll(null, 0, 0, 0));
    try std.testing.expect(!CAPI.ghostty_surface_mouse_pressure(
        null,
        @intFromEnum(input.MousePressureStage.none),
        0,
    ));
    var ime_x: f64 = 1;
    var ime_y: f64 = 2;
    var ime_width: f64 = 3;
    var ime_height: f64 = 4;
    try std.testing.expect(!CAPI.ghostty_surface_ime_point(
        null,
        &ime_x,
        &ime_y,
        &ime_width,
        &ime_height,
    ));
    try std.testing.expectEqual(@as(f64, 0), ime_x);
    try std.testing.expectEqual(@as(f64, 0), ime_y);
    try std.testing.expectEqual(@as(f64, 0), ime_width);
    try std.testing.expectEqual(@as(f64, 0), ime_height);
    try std.testing.expect(!CAPI.ghostty_surface_ime_point(null, null, null, null, null));
    try std.testing.expect(!CAPI.ghostty_surface_request_close(null));
    try std.testing.expect(!CAPI.ghostty_surface_split(
        null,
        @intFromEnum(apprt.action.SplitDirection.right),
    ));
    try std.testing.expect(!CAPI.ghostty_surface_split_focus(
        null,
        @intFromEnum(apprt.action.GotoSplit.next),
    ));
    try std.testing.expect(!CAPI.ghostty_surface_split_resize(
        null,
        @intFromEnum(apprt.action.ResizeSplit.Direction.right),
        1,
    ));
    try std.testing.expect(!CAPI.ghostty_surface_split_equalize(null));
    try std.testing.expect(!CAPI.ghostty_surface_split_toggle_zoom(null));
    try std.testing.expect(!CAPI.ghostty_surface_binding_action(null, null, 0));
    try std.testing.expect(!CAPI.ghostty_surface_complete_clipboard_request(null, null, null, false));
    try std.testing.expect(CAPI.ghostty_surface_inspector(null) == null);
}

test "CAPI exported surface handles reject destroying surfaces" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(true);

    CAPI.ghostty_surface_free(&surface);
    try std.testing.expect(CAPI.ghostty_surface_userdata(&surface) == null);
    try std.testing.expect(!CAPI.ghostty_surface_refresh(&surface));
    try std.testing.expect(!CAPI.ghostty_surface_draw(&surface));
    try std.testing.expect(!CAPI.ghostty_surface_display_realized(&surface));
    try std.testing.expect(!CAPI.ghostty_surface_display_unrealized(&surface));
    try std.testing.expect(!CAPI.ghostty_surface_set_renderer_realized(&surface, true));
    try std.testing.expectEqual(
        std.mem.zeroes(CAPI.SurfaceSize),
        CAPI.ghostty_surface_size(&surface),
    );
    try std.testing.expectEqual(@as(c_int, 123), CAPI.ghostty_surface_key_translation_mods(&surface, 123));
    try std.testing.expect(!CAPI.ghostty_surface_text(&surface, null, 0));
    try std.testing.expect(CAPI.ghostty_surface_inspector(&surface) == null);
}

test "embedded surface teardown gate rejects duplicate claims" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(false);

    try std.testing.expect(!surface.isDestroying());
    try std.testing.expect(surface.beginDestroy());
    try std.testing.expect(surface.isDestroying());
    try std.testing.expect(!surface.beginDestroy());
}

test "CAPI inherited config cleanup remains valid during surface teardown" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var core_app: CoreApp = undefined;
    core_app.alloc = std.testing.allocator;

    var app: App = undefined;
    app.core_app = &core_app;

    var surface: Surface = undefined;
    surface.app = &app;
    surface.destroying = .init(true);

    const working_directory = try std.testing.allocator.dupeZ(
        u8,
        "/tmp/cmux-destroying-surface",
    );
    var opts: Surface.Options = .{
        .font_size = 14,
        .working_directory = working_directory.ptr,
        .context = @intFromEnum(apprt.surface.NewSurfaceContext.split),
    };

    CAPI.ghostty_surface_inherited_config_free(&surface, &opts);

    try std.testing.expect(opts.working_directory == null);
    try std.testing.expectEqual(@as(f32, 0), opts.font_size);
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.surface.NewSurfaceContext.window)),
        opts.context,
    );
}

test "CAPI exported inspector handles reject null" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    CAPI.ghostty_inspector_free(null);
    try std.testing.expect(!CAPI.ghostty_inspector_set_size(null, 1, 1));
    try std.testing.expect(!CAPI.ghostty_inspector_set_content_scale(null, 1, 1));
    try std.testing.expect(!CAPI.ghostty_inspector_mouse_button(
        null,
        @intFromEnum(input.MouseButtonState.release),
        @intFromEnum(input.MouseButton.left),
        0,
    ));
    try std.testing.expect(!CAPI.ghostty_inspector_mouse_pos(null, 0, 0));
    try std.testing.expect(!CAPI.ghostty_inspector_mouse_scroll(null, 0, 0, 0));
    try std.testing.expect(!CAPI.ghostty_inspector_key(
        null,
        @intFromEnum(input.Action.release),
        @intFromEnum(input.Key.unidentified),
        0,
    ));
    try std.testing.expect(!CAPI.ghostty_inspector_text(null, null));
    try std.testing.expect(!CAPI.ghostty_inspector_set_focus(null, true));

    if (builtin.target.os.tag == .linux) {
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_init(null, null));
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_render(null));
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_shutdown(null));
    }
}

test "CAPI exported inspector handles reject destroying surfaces" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(true);

    var inspector: Inspector = .{
        .surface = &surface,
        .ig_ctx = undefined,
    };

    CAPI.ghostty_inspector_free(&inspector);
    try std.testing.expect(!CAPI.ghostty_inspector_set_size(&inspector, 1, 1));
    try std.testing.expect(!CAPI.ghostty_inspector_set_content_scale(&inspector, 1, 1));
    try std.testing.expect(!CAPI.ghostty_inspector_mouse_button(
        &inspector,
        @intFromEnum(input.MouseButtonState.release),
        @intFromEnum(input.MouseButton.left),
        0,
    ));
    try std.testing.expect(!CAPI.ghostty_inspector_mouse_pos(&inspector, 0, 0));
    try std.testing.expect(!CAPI.ghostty_inspector_mouse_scroll(&inspector, 0, 0, 0));
    try std.testing.expect(!CAPI.ghostty_inspector_key(
        &inspector,
        @intFromEnum(input.Action.release),
        @intFromEnum(input.Key.unidentified),
        0,
    ));
    try std.testing.expect(!CAPI.ghostty_inspector_text(&inspector, "late"));
    try std.testing.expect(!CAPI.ghostty_inspector_set_focus(&inspector, true));

    if (builtin.target.os.tag == .linux) {
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_init(&inspector, null));
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_render(&inspector));
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_shutdown(&inspector));
    }
}

test "embedded inspector teardown gate blocks recreation during backend callbacks" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(false);

    var inspector: Inspector = .{
        .surface = &surface,
        .ig_ctx = undefined,
    };
    surface.inspector = &inspector;

    try std.testing.expect(surface.claimInspectorForDestroy().? == &inspector);
    try std.testing.expect(surface.inspector.? == &inspector);
    try std.testing.expect(inspector.isDestroying());
    try std.testing.expect(!inspector.beginDestroy());
    try std.testing.expect(surface.claimInspectorForDestroy() == null);
    try std.testing.expectError(error.InspectorDestroying, surface.initInspector());
    try std.testing.expect(CAPI.ghostty_surface_inspector(&surface) == null);

    CAPI.ghostty_inspector_free(&inspector);
    try std.testing.expect(!CAPI.ghostty_inspector_set_size(&inspector, 1, 1));
    if (builtin.target.os.tag == .linux) {
        try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_render(&inspector));
    }
}

test "CAPI clipboard completion consumes request on rejected text" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const testing = std.testing;

    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;

    var app: App = undefined;
    app.core_app = &core_app;

    var surface: Surface = undefined;
    surface.app = &app;
    surface.destroying = .init(false);
    surface.clipboard_request_mutex = .{};
    surface.clipboard_requests = .{};
    surface.next_clipboard_request_token = 1;
    defer surface.clipboard_requests.deinit(testing.allocator);

    var request = try surface.registerClipboardRequest(.paste);
    try testing.expect(!CAPI.ghostty_surface_complete_clipboard_request(
        &surface,
        null,
        request,
        false,
    ));

    const invalid = [_:0]u8{0xFF};
    request = try surface.registerClipboardRequest(.paste);
    try testing.expect(!CAPI.ghostty_surface_complete_clipboard_request(
        &surface,
        invalid[0..].ptr,
        request,
        false,
    ));
    try testing.expectEqual(@as(usize, 0), surface.clipboard_requests.items.len);
}

test "CAPI clipboard completion rejects unknown request without consuming it" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const testing = std.testing;

    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;

    var app: App = undefined;
    app.core_app = &core_app;

    var surface: Surface = undefined;
    surface.app = &app;
    surface.destroying = .init(false);
    surface.clipboard_request_mutex = .{};
    surface.clipboard_requests = .{};
    surface.next_clipboard_request_token = 1;
    defer surface.clipboard_requests.deinit(testing.allocator);

    const request: *anyopaque = @ptrFromInt(99);

    const text = "clipboard text";
    try testing.expect(!CAPI.ghostty_surface_complete_clipboard_request(
        &surface,
        text,
        request,
        false,
    ));
}

test "embedded surface drains pending clipboard requests" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const testing = std.testing;

    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;

    var app: App = undefined;
    app.core_app = &core_app;

    var surface: Surface = undefined;
    surface.app = &app;
    surface.destroying = .init(false);
    surface.clipboard_request_mutex = .{};
    surface.clipboard_requests = .{};
    surface.next_clipboard_request_token = 1;
    defer surface.clipboard_requests.deinit(testing.allocator);

    _ = try surface.registerClipboardRequest(.paste);
    try testing.expectEqual(@as(usize, 1), surface.clipboard_requests.items.len);

    surface.drainClipboardRequests();
    try testing.expectEqual(@as(usize, 0), surface.clipboard_requests.items.len);
}

test "embedded clipboard tokens do not reuse completed request identity" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const testing = std.testing;

    var core_app: CoreApp = undefined;
    core_app.alloc = testing.allocator;

    var app: App = undefined;
    app.core_app = &core_app;

    var surface: Surface = undefined;
    surface.app = &app;
    surface.destroying = .init(false);
    surface.clipboard_request_mutex = .{};
    surface.clipboard_requests = .{};
    surface.next_clipboard_request_token = 1;
    defer surface.clipboard_requests.deinit(testing.allocator);

    const stale = try surface.registerClipboardRequest(.paste);
    const first = surface.takeClipboardRequestOpaque(stale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), first.token);
    try surface.restoreClipboardRequest(first);
    const restored = surface.takeClipboardRequestOpaque(stale) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), restored.token);

    const current = try surface.registerClipboardRequest(.paste);
    try testing.expect(@intFromPtr(stale) != @intFromPtr(current));
    try testing.expect(surface.takeClipboardRequestOpaque(stale) == null);
    try testing.expect(surface.takeClipboardRequestOpaque(current) != null);
}

test "Linux inspector OpenGL APIs use host context callbacks" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;
        var make_current_result: bool = false;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return make_current_result;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    var surface: Surface = undefined;
    surface.destroying = .init(false);
    surface.platform = .{ .linux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    } };

    var inspector: Inspector = .{
        .surface = &surface,
        .ig_ctx = undefined,
    };

    try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_init(&inspector, null));
    try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_render(&inspector));
    try std.testing.expect(CAPI.Linux.ghostty_inspector_opengl_shutdown(&inspector));
    try std.testing.expectEqual(@as(usize, 2), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);

    inspector.backend = .opengl;
    try std.testing.expect(!inspector.deinitBackend(
        "test_inspector_shutdown",
        .preserve_on_context_loss,
    ));
    try std.testing.expectEqual(@as(usize, 3), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);
    try std.testing.expectEqual(@as(?Inspector.Backend, .opengl), inspector.backend);

    try std.testing.expect(!inspector.deinitBackend(
        "test_inspector_free",
        .abandon_on_context_loss,
    ));
    try std.testing.expectEqual(@as(usize, 4), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);
    try std.testing.expectEqual(@as(?Inspector.Backend, null), inspector.backend);

    Context.make_current_result = true;
    try std.testing.expect(!CAPI.Linux.ghostty_inspector_opengl_render(&inspector));
    try std.testing.expectEqual(@as(usize, 5), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);

    inspector.backend = .opengl;
    inspector.abandonBackendAfterContextLoss("test_inspector_context_loss");
    try std.testing.expectEqual(@as(?Inspector.Backend, null), inspector.backend);
    try std.testing.expect(CAPI.Linux.ghostty_inspector_opengl_shutdown(&inspector));
    try std.testing.expectEqual(@as(usize, 5), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 1), Context.done_current_calls);
}

test "Linux surface free unrealizes display before inspector object free" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    const Context = struct {
        var make_current_calls: usize = 0;
        var done_current_calls: usize = 0;

        fn makeCurrent(_: ?*anyopaque) callconv(.c) bool {
            make_current_calls += 1;
            return false;
        }

        fn getProcAddress(_: ?*anyopaque, _: [*c]const u8) callconv(.c) ?*anyopaque {
            return null;
        }

        fn doneCurrent(_: ?*anyopaque) callconv(.c) void {
            done_current_calls += 1;
        }
    };

    var surface: Surface = undefined;
    surface.destroying = .init(false);
    surface.platform = .{ .linux = .{
        .userdata = null,
        .make_current = Context.makeCurrent,
        .get_proc_address = Context.getProcAddress,
        .done_current = Context.doneCurrent,
    } };
    surface.display_realized = true;
    surface.core_surface.renderer.swap_chain.defunct = true;

    var inspector: Inspector = .{
        .surface = &surface,
        .ig_ctx = undefined,
        .backend = .opengl,
    };
    surface.inspector = &inspector;

    surface.unrealizeDisplayForDeinit();

    try std.testing.expect(!surface.display_realized);
    try std.testing.expect(surface.inspector.? == &inspector);
    try std.testing.expectEqual(@as(?Inspector.Backend, null), inspector.backend);
    try std.testing.expectEqual(@as(usize, 1), Context.make_current_calls);
    try std.testing.expectEqual(@as(usize, 0), Context.done_current_calls);
}

test "Linux unrealize required for live swap chain before display realization" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;

    var surface: Surface = undefined;
    surface.destroying = .init(false);

    surface.display_realized = false;
    surface.core_surface.renderer.swap_chain.defunct = false;
    try std.testing.expect(surface.hasLiveDisplayResources());

    surface.display_realized = false;
    surface.core_surface.renderer.swap_chain.defunct = true;
    try std.testing.expect(!surface.hasLiveDisplayResources());

    surface.display_realized = true;
    surface.core_surface.renderer.swap_chain.defunct = true;
    try std.testing.expect(surface.hasLiveDisplayResources());
}

test "CAPI mouse pressure stage maps to input enum" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    try std.testing.expectEqual(
        input.MousePressureStage.none,
        CAPI.MousePressureStage.none.inputStage().?,
    );
    try std.testing.expectEqual(
        input.MousePressureStage.normal,
        CAPI.MousePressureStage.normal.inputStage().?,
    );
    try std.testing.expectEqual(
        input.MousePressureStage.deep,
        CAPI.MousePressureStage.deep.inputStage().?,
    );

    const invalid: CAPI.MousePressureStage = @enumFromInt(99);
    try std.testing.expect(invalid.inputStage() == null);
}

test "CAPI text deinit clears released result" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    CAPI.global.alloc = std.testing.allocator;

    const text = try std.testing.allocator.dupeZ(u8, "cmux ghostty text");
    var result: CAPI.Text = .{
        .tl_px_x = 12,
        .tl_px_y = 24,
        .offset_start = 1,
        .offset_len = 4,
        .text = text.ptr,
        .text_len = text.len,
    };

    result.deinit();

    try std.testing.expectEqual(@as(f64, 0), result.tl_px_x);
    try std.testing.expectEqual(@as(f64, 0), result.tl_px_y);
    try std.testing.expectEqual(@as(u32, 0), result.offset_start);
    try std.testing.expectEqual(@as(u32, 0), result.offset_len);
    try std.testing.expect(result.text == null);
    try std.testing.expectEqual(@as(usize, 0), result.text_len);

    result.deinit();
}

test "ghostty.h text and selection ABI" {
    if (comptime !embedded_runtime_tests) return error.SkipZigTest;

    const c = @import("ghostty.h");

    try std.testing.expect(@hasDecl(c, "ghostty_ipc_target_s"));
    try std.testing.expect(@hasDecl(c, "ghostty_ipc_target_u"));
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.ipc.Target.Key.class)),
        c.GHOSTTY_IPC_TARGET_CLASS,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.ipc.Target.Key.detect)),
        c.GHOSTTY_IPC_TARGET_DETECT,
    );
    try std.testing.expect(@FieldType(c.ghostty_ipc_target_u, "klass") == [*c]const u8);
    try std.testing.expectEqual(
        @as(usize, @sizeOf(apprt.ipc.Target.CValue)),
        @as(usize, @sizeOf(c.ghostty_ipc_target_u)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(apprt.ipc.Target.CValue)),
        @as(usize, @alignOf(c.ghostty_ipc_target_u)),
    );
    try std.testing.expectEqual(
        @as(usize, @sizeOf(apprt.ipc.Target.C)),
        @as(usize, @sizeOf(c.ghostty_ipc_target_s)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(apprt.ipc.Target.C)),
        @as(usize, @alignOf(c.ghostty_ipc_target_s)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_ipc_target_s, "tag")),
        @as(usize, @offsetOf(apprt.ipc.Target.C, "key")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_ipc_target_s, "target")),
        @as(usize, @offsetOf(apprt.ipc.Target.C, "value")),
    );

    try std.testing.expect(@hasDecl(c, "ghostty_ipc_action_s"));
    try std.testing.expect(@hasDecl(c, "ghostty_ipc_action_u"));
    try std.testing.expect(@hasDecl(c, "ghostty_ipc_action_new_window_s"));
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.ipc.Action.Key.new_window)),
        c.GHOSTTY_IPC_ACTION_NEW_WINDOW,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(apprt.ipc.Action.Key.toggle_quick_terminal)),
        c.GHOSTTY_IPC_ACTION_TOGGLE_QUICK_TERMINAL,
    );
    try std.testing.expect(@FieldType(c.ghostty_ipc_action_new_window_s, "arguments") == [*c]const [*c]const u8);
    try std.testing.expectEqual(
        @as(usize, @sizeOf(apprt.ipc.Action.NewWindow.C)),
        @as(usize, @sizeOf(c.ghostty_ipc_action_new_window_s)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(apprt.ipc.Action.NewWindow.C)),
        @as(usize, @alignOf(c.ghostty_ipc_action_new_window_s)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_ipc_action_new_window_s, "arguments")),
        @as(usize, @offsetOf(apprt.ipc.Action.NewWindow.C, "arguments")),
    );
    try std.testing.expectEqual(
        @as(usize, @sizeOf(apprt.ipc.Action.CValue)),
        @as(usize, @sizeOf(c.ghostty_ipc_action_u)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(apprt.ipc.Action.CValue)),
        @as(usize, @alignOf(c.ghostty_ipc_action_u)),
    );
    try std.testing.expectEqual(
        @as(usize, @sizeOf(apprt.ipc.Action.C)),
        @as(usize, @sizeOf(c.ghostty_ipc_action_s)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(apprt.ipc.Action.C)),
        @as(usize, @alignOf(c.ghostty_ipc_action_s)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_ipc_action_s, "tag")),
        @as(usize, @offsetOf(apprt.ipc.Action.C, "key")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_ipc_action_s, "action")),
        @as(usize, @offsetOf(apprt.ipc.Action.C, "value")),
    );

    try std.testing.expectEqual(@sizeOf(c.ghostty_input_key_s), @sizeOf(CAPI.KeyEvent));
    try std.testing.expectEqual(@alignOf(c.ghostty_input_key_s), @alignOf(CAPI.KeyEvent));
    const key_event_fields = .{
        .{ "action", "action" },
        .{ "mods", "mods" },
        .{ "consumed_mods", "consumed_mods" },
        .{ "keycode", "keycode" },
        .{ "text", "text" },
        .{ "unshifted_codepoint", "unshifted_codepoint" },
        .{ "composing", "composing" },
    };
    inline for (key_event_fields) |field| {
        try std.testing.expectEqual(
            @offsetOf(c.ghostty_input_key_s, field[0]),
            @offsetOf(CAPI.KeyEvent, field[1]),
        );
    }

    try std.testing.expectEqual(
        @sizeOf(c.ghostty_surface_size_s),
        @sizeOf(CAPI.SurfaceSize),
    );
    try std.testing.expectEqual(
        @alignOf(c.ghostty_surface_size_s),
        @alignOf(CAPI.SurfaceSize),
    );
    const size_fields = .{
        .{ "columns", "columns" },
        .{ "rows", "rows" },
        .{ "width_px", "width_px" },
        .{ "height_px", "height_px" },
        .{ "cell_width_px", "cell_width_px" },
        .{ "cell_height_px", "cell_height_px" },
    };
    inline for (size_fields) |field| {
        try std.testing.expectEqual(
            @offsetOf(c.ghostty_surface_size_s, field[0]),
            @offsetOf(CAPI.SurfaceSize, field[1]),
        );
    }

    try std.testing.expectEqual(@sizeOf(c.ghostty_text_s), @sizeOf(CAPI.Text));
    try std.testing.expectEqual(@alignOf(c.ghostty_text_s), @alignOf(CAPI.Text));
    const text_fields = .{
        .{ "tl_px_x", "tl_px_x" },
        .{ "tl_px_y", "tl_px_y" },
        .{ "offset_start", "offset_start" },
        .{ "offset_len", "offset_len" },
        .{ "text", "text" },
        .{ "text_len", "text_len" },
    };
    inline for (text_fields) |field| {
        try std.testing.expectEqual(
            @offsetOf(c.ghostty_text_s, field[0]),
            @offsetOf(CAPI.Text, field[1]),
        );
    }

    try std.testing.expectEqual(@sizeOf(c.ghostty_point_s), @sizeOf(CAPI.Point));
    try std.testing.expectEqual(@alignOf(c.ghostty_point_s), @alignOf(CAPI.Point));
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.Point.Tag.active)),
        c.GHOSTTY_POINT_ACTIVE,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.Point.Tag.viewport)),
        c.GHOSTTY_POINT_VIEWPORT,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.Point.Tag.screen)),
        c.GHOSTTY_POINT_SCREEN,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.Point.Tag.history)),
        c.GHOSTTY_POINT_HISTORY,
    );
    try std.testing.expectEqual(c.GHOSTTY_POINT_HISTORY, c.GHOSTTY_POINT_SURFACE);
    const point_fields = .{
        .{ "tag", "tag" },
        .{ "coord", "coord_tag" },
        .{ "x", "x" },
        .{ "y", "y" },
    };
    inline for (point_fields) |field| {
        try std.testing.expectEqual(
            @offsetOf(c.ghostty_point_s, field[0]),
            @offsetOf(CAPI.Point, field[1]),
        );
    }

    try std.testing.expectEqual(
        @sizeOf(c.ghostty_selection_s),
        @sizeOf(CAPI.Selection),
    );
    try std.testing.expectEqual(
        @alignOf(c.ghostty_selection_s),
        @alignOf(CAPI.Selection),
    );
    try std.testing.expect(@hasDecl(c, "ghostty_init"));
    const ghostty_init = @typeInfo(@TypeOf(c.ghostty_init)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), ghostty_init.params.len);
    try std.testing.expect(ghostty_init.return_type.? == c_int);
    try std.testing.expect(ghostty_init.params[0].type.? == usize);
    try std.testing.expect(ghostty_init.params[1].type.? == [*c]const [*c]const u8);
    try std.testing.expect(@hasDecl(c, "ghostty_string_free"));
    const string_free = @typeInfo(@TypeOf(c.ghostty_string_free)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), string_free.params.len);
    try std.testing.expect(string_free.return_type.? == void);
    try std.testing.expect(string_free.params[0].type.? == c.ghostty_string_s);
    try std.testing.expect(@hasDecl(c, "ghostty_resources_dir"));
    const resources_dir = @typeInfo(@TypeOf(c.ghostty_resources_dir)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), resources_dir.params.len);
    try std.testing.expect(resources_dir.return_type.? == c.ghostty_string_s);
    try std.testing.expectEqual(
        @as(c_int, c.GHOSTTY_EMBEDDING_ABI_VERSION),
        @as(c_int, embedding_abi_version),
    );
    try std.testing.expectEqual(
        @as(usize, c.GHOSTTY_SURFACE_MAX_ENV_VARS),
        @as(usize, max_surface_env_vars),
    );
    try std.testing.expect(@hasDecl(c, "ghostty_embedding_info_s"));
    try std.testing.expectEqual(
        @as(usize, @sizeOf(c.ghostty_embedding_info_s)),
        @as(usize, @sizeOf(CAPI.EmbeddingInfo)),
    );
    try std.testing.expectEqual(
        @as(usize, @alignOf(c.ghostty_embedding_info_s)),
        @as(usize, @alignOf(CAPI.EmbeddingInfo)),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_embedding_info_s, "abi_version")),
        @as(usize, @offsetOf(CAPI.EmbeddingInfo, "abi_version")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_embedding_info_s, "platform")),
        @as(usize, @offsetOf(CAPI.EmbeddingInfo, "platform")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_embedding_info_s, "renderer_backend")),
        @as(usize, @offsetOf(CAPI.EmbeddingInfo, "renderer_backend")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_embedding_info_s, "surface_max_env_vars")),
        @as(usize, @offsetOf(CAPI.EmbeddingInfo, "surface_max_env_vars")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_embedding_info_s, "supports_linux_platform")),
        @as(usize, @offsetOf(CAPI.EmbeddingInfo, "supports_linux_platform")),
    );
    try std.testing.expectEqual(
        @as(usize, @offsetOf(c.ghostty_embedding_info_s, "must_draw_from_app_thread")),
        @as(usize, @offsetOf(CAPI.EmbeddingInfo, "must_draw_from_app_thread")),
    );
    const embedding_info_size_fields = .{
        "runtime_config_size",
        "surface_config_size",
        "platform_linux_size",
        "input_key_size",
        "target_size",
        "action_size",
        "text_size",
        "selection_size",
        "string_size",
        "surface_size_size",
        "diagnostic_size",
        "env_var_size",
        "clipboard_content_size",
        "input_trigger_size",
        "ipc_target_size",
        "ipc_action_size",
        "runtime_config_align",
        "surface_config_align",
        "platform_linux_align",
        "input_key_align",
        "target_align",
        "action_align",
        "text_align",
        "selection_align",
        "string_align",
        "surface_size_align",
        "diagnostic_align",
        "env_var_align",
        "clipboard_content_align",
        "input_trigger_align",
        "ipc_target_align",
        "ipc_action_align",
        "layout_fingerprint",
        "constants_fingerprint",
    };
    inline for (embedding_info_size_fields) |field| {
        try std.testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_embedding_info_s, field)),
            @as(usize, @offsetOf(CAPI.EmbeddingInfo, field)),
        );
    }
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.RendererBackend.unknown)),
        c.GHOSTTY_RENDERER_BACKEND_UNKNOWN,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.RendererBackend.opengl)),
        c.GHOSTTY_RENDERER_BACKEND_OPENGL,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.RendererBackend.metal)),
        c.GHOSTTY_RENDERER_BACKEND_METAL,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.RendererBackend.webgl)),
        c.GHOSTTY_RENDERER_BACKEND_WEBGL,
    );
    try std.testing.expect(@hasDecl(c, "ghostty_embedding_info"));
    const embedding_info = @typeInfo(@TypeOf(c.ghostty_embedding_info)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), embedding_info.params.len);
    try std.testing.expect(embedding_info.return_type.? == c.ghostty_embedding_info_s);
    try std.testing.expect(@hasDecl(c, "ghostty_embedding_info_query"));
    const embedding_info_query = @typeInfo(@TypeOf(c.ghostty_embedding_info_query)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), embedding_info_query.params.len);
    try std.testing.expect(embedding_info_query.return_type.? == bool);
    try std.testing.expect(embedding_info_query.params[0].type.? == [*c]c.ghostty_embedding_info_s);
    try std.testing.expect(embedding_info_query.params[1].type.? == usize);
    try std.testing.expect(@hasDecl(c, "ghostty_config_new"));
    const config_new = @typeInfo(@TypeOf(c.ghostty_config_new)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), config_new.params.len);
    try std.testing.expect(config_new.return_type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_free"));
    const config_free = @typeInfo(@TypeOf(c.ghostty_config_free)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_free.params.len);
    try std.testing.expect(config_free.return_type.? == void);
    try std.testing.expect(config_free.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_clone"));
    const config_clone = @typeInfo(@TypeOf(c.ghostty_config_clone)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_clone.params.len);
    try std.testing.expect(config_clone.return_type.? == c.ghostty_config_t);
    try std.testing.expect(config_clone.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_load_cli_args"));
    const config_load_cli_args = @typeInfo(@TypeOf(c.ghostty_config_load_cli_args)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_load_cli_args.params.len);
    try std.testing.expect(config_load_cli_args.return_type.? == bool);
    try std.testing.expect(config_load_cli_args.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_load_file"));
    const config_load_file = @typeInfo(@TypeOf(c.ghostty_config_load_file)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), config_load_file.params.len);
    try std.testing.expect(config_load_file.return_type.? == bool);
    try std.testing.expect(config_load_file.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(config_load_file.params[1].type.? == [*c]const u8);
    try std.testing.expect(@hasDecl(c, "ghostty_config_load_string"));
    const config_load_string = @typeInfo(@TypeOf(c.ghostty_config_load_string)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), config_load_string.params.len);
    try std.testing.expect(config_load_string.return_type.? == bool);
    try std.testing.expect(config_load_string.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(config_load_string.params[1].type.? == [*c]const u8);
    try std.testing.expect(config_load_string.params[2].type.? == usize);
    try std.testing.expect(@hasDecl(c, "ghostty_config_load_default_files"));
    const config_load_default_files =
        @typeInfo(@TypeOf(c.ghostty_config_load_default_files)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_load_default_files.params.len);
    try std.testing.expect(config_load_default_files.return_type.? == bool);
    try std.testing.expect(config_load_default_files.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_load_recursive_files"));
    const config_load_recursive_files =
        @typeInfo(@TypeOf(c.ghostty_config_load_recursive_files)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_load_recursive_files.params.len);
    try std.testing.expect(config_load_recursive_files.return_type.? == bool);
    try std.testing.expect(config_load_recursive_files.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_finalize"));
    const config_finalize = @typeInfo(@TypeOf(c.ghostty_config_finalize)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_finalize.params.len);
    try std.testing.expect(config_finalize.return_type.? == bool);
    try std.testing.expect(config_finalize.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_get"));
    const config_get = @typeInfo(@TypeOf(c.ghostty_config_get)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), config_get.params.len);
    try std.testing.expect(config_get.return_type.? == bool);
    try std.testing.expect(config_get.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(config_get.params[1].type.? == ?*anyopaque);
    try std.testing.expect(config_get.params[2].type.? == [*c]const u8);
    try std.testing.expect(config_get.params[3].type.? == usize);
    try std.testing.expect(@hasDecl(c, "ghostty_config_trigger"));
    const config_trigger = @typeInfo(@TypeOf(c.ghostty_config_trigger)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), config_trigger.params.len);
    try std.testing.expect(config_trigger.return_type.? == c.ghostty_input_trigger_s);
    try std.testing.expect(config_trigger.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(config_trigger.params[1].type.? == [*c]const u8);
    try std.testing.expect(config_trigger.params[2].type.? == usize);
    try std.testing.expect(@hasDecl(c, "ghostty_config_key_is_binding"));
    const config_key_is_binding = @typeInfo(@TypeOf(c.ghostty_config_key_is_binding)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), config_key_is_binding.params.len);
    try std.testing.expect(config_key_is_binding.return_type.? == bool);
    try std.testing.expect(config_key_is_binding.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(config_key_is_binding.params[1].type.? == c.ghostty_input_key_s);
    try std.testing.expect(@hasDecl(c, "ghostty_config_diagnostics_count"));
    const config_diagnostics_count =
        @typeInfo(@TypeOf(c.ghostty_config_diagnostics_count)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), config_diagnostics_count.params.len);
    try std.testing.expect(config_diagnostics_count.return_type.? == u32);
    try std.testing.expect(config_diagnostics_count.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_config_get_diagnostic"));
    const config_get_diagnostic =
        @typeInfo(@TypeOf(c.ghostty_config_get_diagnostic)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), config_get_diagnostic.params.len);
    try std.testing.expect(config_get_diagnostic.return_type.? == c.ghostty_diagnostic_s);
    try std.testing.expect(config_get_diagnostic.params[0].type.? == c.ghostty_config_t);
    try std.testing.expect(config_get_diagnostic.params[1].type.? == u32);
    try std.testing.expect(@hasDecl(c, "ghostty_config_open_path"));
    const config_open_path = @typeInfo(@TypeOf(c.ghostty_config_open_path)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), config_open_path.params.len);
    try std.testing.expect(config_open_path.return_type.? == c.ghostty_string_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_clear_selection"));
    try std.testing.expect(@hasDecl(c, "ghostty_surface_split_toggle_zoom"));
    try std.testing.expect(@hasDecl(c, "ghostty_app_tick"));
    const app_tick = @typeInfo(@TypeOf(c.ghostty_app_tick)).@"fn";
    try std.testing.expect(app_tick.return_type.? == bool);
    try std.testing.expect(app_tick.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_new"));
    const app_new = @typeInfo(@TypeOf(c.ghostty_app_new)).@"fn";
    try std.testing.expect(app_new.return_type.? == c.ghostty_app_t);
    try std.testing.expect(app_new.params[0].type.? == [*c]const c.ghostty_runtime_config_s);
    try std.testing.expect(app_new.params[1].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_free"));
    const app_free = @typeInfo(@TypeOf(c.ghostty_app_free)).@"fn";
    try std.testing.expect(app_free.return_type.? == void);
    try std.testing.expect(app_free.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_userdata"));
    const app_userdata = @typeInfo(@TypeOf(c.ghostty_app_userdata)).@"fn";
    try std.testing.expect(app_userdata.return_type.? == ?*anyopaque);
    try std.testing.expect(app_userdata.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_set_focus"));
    const app_set_focus = @typeInfo(@TypeOf(c.ghostty_app_set_focus)).@"fn";
    try std.testing.expect(app_set_focus.return_type.? == bool);
    try std.testing.expect(app_set_focus.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(app_set_focus.params[1].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_app_key"));
    const app_key = @typeInfo(@TypeOf(c.ghostty_app_key)).@"fn";
    try std.testing.expect(app_key.return_type.? == bool);
    try std.testing.expect(app_key.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(app_key.params[1].type.? == c.ghostty_input_key_s);
    try std.testing.expect(@hasDecl(c, "ghostty_app_keyboard_changed"));
    const app_keyboard_changed = @typeInfo(@TypeOf(c.ghostty_app_keyboard_changed)).@"fn";
    try std.testing.expect(app_keyboard_changed.return_type.? == bool);
    try std.testing.expect(app_keyboard_changed.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_open_config"));
    const app_open_config = @typeInfo(@TypeOf(c.ghostty_app_open_config)).@"fn";
    try std.testing.expect(app_open_config.return_type.? == bool);
    try std.testing.expect(app_open_config.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_reload_config"));
    const app_reload_config = @typeInfo(@TypeOf(c.ghostty_app_reload_config)).@"fn";
    try std.testing.expect(app_reload_config.return_type.? == bool);
    try std.testing.expect(app_reload_config.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(app_reload_config.params[1].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_app_update_config"));
    const app_update_config = @typeInfo(@TypeOf(c.ghostty_app_update_config)).@"fn";
    try std.testing.expect(app_update_config.return_type.? == bool);
    try std.testing.expect(app_update_config.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(app_update_config.params[1].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_needs_confirm_quit"));
    const app_needs_confirm_quit = @typeInfo(@TypeOf(c.ghostty_app_needs_confirm_quit)).@"fn";
    try std.testing.expect(app_needs_confirm_quit.return_type.? == bool);
    try std.testing.expect(app_needs_confirm_quit.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_has_global_keybinds"));
    const app_has_global_keybinds = @typeInfo(@TypeOf(c.ghostty_app_has_global_keybinds)).@"fn";
    try std.testing.expect(app_has_global_keybinds.return_type.? == bool);
    try std.testing.expect(app_has_global_keybinds.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_must_draw_from_app_thread"));
    const app_must_draw_from_app_thread =
        @typeInfo(@TypeOf(c.ghostty_app_must_draw_from_app_thread)).@"fn";
    try std.testing.expect(app_must_draw_from_app_thread.return_type.? == bool);
    try std.testing.expect(app_must_draw_from_app_thread.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_config_new"));
    try std.testing.expect(@FieldType(c.ghostty_surface_config_s, "env_vars") == [*c]const c.ghostty_env_var_s);
    const surface_config_new = @typeInfo(@TypeOf(c.ghostty_surface_config_new)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), surface_config_new.params.len);
    try std.testing.expect(surface_config_new.return_type.? == c.ghostty_surface_config_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_inherited_config_free"));
    const inherited_config_free =
        @typeInfo(@TypeOf(c.ghostty_surface_inherited_config_free)).@"fn";
    try std.testing.expect(inherited_config_free.return_type.? == void);
    try std.testing.expect(inherited_config_free.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(inherited_config_free.params[1].type.? == [*c]c.ghostty_surface_config_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_new"));
    const surface_new = @typeInfo(@TypeOf(c.ghostty_surface_new)).@"fn";
    try std.testing.expect(surface_new.return_type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_new.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(surface_new.params[1].type.? == [*c]const c.ghostty_surface_config_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_free"));
    const surface_free = @typeInfo(@TypeOf(c.ghostty_surface_free)).@"fn";
    try std.testing.expect(surface_free.return_type.? == void);
    try std.testing.expect(surface_free.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_userdata"));
    const surface_userdata = @typeInfo(@TypeOf(c.ghostty_surface_userdata)).@"fn";
    try std.testing.expect(surface_userdata.return_type.? == ?*anyopaque);
    try std.testing.expect(surface_userdata.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_app"));
    const surface_app = @typeInfo(@TypeOf(c.ghostty_surface_app)).@"fn";
    try std.testing.expect(surface_app.return_type.? == c.ghostty_app_t);
    try std.testing.expect(surface_app.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_inherited_config"));
    const inherited_config =
        @typeInfo(@TypeOf(c.ghostty_surface_inherited_config)).@"fn";
    try std.testing.expect(inherited_config.return_type.? == c.ghostty_surface_config_s);
    try std.testing.expect(inherited_config.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(inherited_config.params[1].type.? == c.ghostty_surface_context_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_update_config"));
    const surface_update_config = @typeInfo(@TypeOf(c.ghostty_surface_update_config)).@"fn";
    try std.testing.expect(surface_update_config.return_type.? == bool);
    try std.testing.expect(surface_update_config.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_update_config.params[1].type.? == c.ghostty_config_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_needs_confirm_quit"));
    const surface_needs_confirm_quit =
        @typeInfo(@TypeOf(c.ghostty_surface_needs_confirm_quit)).@"fn";
    try std.testing.expect(surface_needs_confirm_quit.return_type.? == bool);
    try std.testing.expect(surface_needs_confirm_quit.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_process_exited"));
    const surface_process_exited = @typeInfo(@TypeOf(c.ghostty_surface_process_exited)).@"fn";
    try std.testing.expect(surface_process_exited.return_type.? == bool);
    try std.testing.expect(surface_process_exited.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_size"));
    const surface_size = @typeInfo(@TypeOf(c.ghostty_surface_size)).@"fn";
    try std.testing.expect(surface_size.return_type.? == c.ghostty_surface_size_s);
    try std.testing.expect(surface_size.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_foreground_pid"));
    const surface_foreground_pid = @typeInfo(@TypeOf(c.ghostty_surface_foreground_pid)).@"fn";
    try std.testing.expect(surface_foreground_pid.return_type.? == u64);
    try std.testing.expect(surface_foreground_pid.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_tty_name"));
    const surface_tty_name = @typeInfo(@TypeOf(c.ghostty_surface_tty_name)).@"fn";
    try std.testing.expect(surface_tty_name.return_type.? == c.ghostty_string_s);
    try std.testing.expect(surface_tty_name.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_title"));
    const surface_title = @typeInfo(@TypeOf(c.ghostty_surface_title)).@"fn";
    try std.testing.expect(surface_title.return_type.? == c.ghostty_string_s);
    try std.testing.expect(surface_title.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_pwd"));
    const surface_pwd = @typeInfo(@TypeOf(c.ghostty_surface_pwd)).@"fn";
    try std.testing.expect(surface_pwd.return_type.? == c.ghostty_string_s);
    try std.testing.expect(surface_pwd.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_app_set_color_scheme"));
    const app_set_color_scheme = @typeInfo(@TypeOf(c.ghostty_app_set_color_scheme)).@"fn";
    try std.testing.expect(app_set_color_scheme.return_type.? == bool);
    try std.testing.expect(app_set_color_scheme.params[0].type.? == c.ghostty_app_t);
    try std.testing.expect(app_set_color_scheme.params[1].type.? == c.ghostty_color_scheme_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_content_scale"));
    const surface_set_content_scale =
        @typeInfo(@TypeOf(c.ghostty_surface_set_content_scale)).@"fn";
    try std.testing.expect(surface_set_content_scale.return_type.? == bool);
    try std.testing.expect(surface_set_content_scale.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_set_content_scale.params[1].type.? == f64);
    try std.testing.expect(surface_set_content_scale.params[2].type.? == f64);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_focus"));
    const surface_set_focus = @typeInfo(@TypeOf(c.ghostty_surface_set_focus)).@"fn";
    try std.testing.expect(surface_set_focus.return_type.? == bool);
    try std.testing.expect(surface_set_focus.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_set_focus.params[1].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_visible"));
    const surface_set_visible = @typeInfo(@TypeOf(c.ghostty_surface_set_visible)).@"fn";
    try std.testing.expect(surface_set_visible.return_type.? == bool);
    try std.testing.expect(surface_set_visible.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_set_visible.params[1].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_occlusion"));
    const surface_set_occlusion = @typeInfo(@TypeOf(c.ghostty_surface_set_occlusion)).@"fn";
    try std.testing.expect(surface_set_occlusion.return_type.? == bool);
    try std.testing.expect(surface_set_occlusion.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_set_occlusion.params[1].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_size"));
    const surface_set_size = @typeInfo(@TypeOf(c.ghostty_surface_set_size)).@"fn";
    try std.testing.expect(surface_set_size.return_type.? == bool);
    try std.testing.expect(surface_set_size.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_set_size.params[1].type.? == u32);
    try std.testing.expect(surface_set_size.params[2].type.? == u32);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_color_scheme"));
    const surface_set_color_scheme =
        @typeInfo(@TypeOf(c.ghostty_surface_set_color_scheme)).@"fn";
    try std.testing.expect(surface_set_color_scheme.return_type.? == bool);
    try std.testing.expect(surface_set_color_scheme.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_set_color_scheme.params[1].type.? == c.ghostty_color_scheme_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_text"));
    const surface_text = @typeInfo(@TypeOf(c.ghostty_surface_text)).@"fn";
    try std.testing.expect(surface_text.return_type.? == bool);
    try std.testing.expect(surface_text.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_text.params[1].type.? == [*c]const u8);
    try std.testing.expect(surface_text.params[2].type.? == usize);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_preedit"));
    const surface_preedit = @typeInfo(@TypeOf(c.ghostty_surface_preedit)).@"fn";
    try std.testing.expect(surface_preedit.return_type.? == bool);
    try std.testing.expect(surface_preedit.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_preedit.params[1].type.? == [*c]const u8);
    try std.testing.expect(surface_preedit.params[2].type.? == usize);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_complete_clipboard_request"));
    const complete_clipboard_request =
        @typeInfo(@TypeOf(c.ghostty_surface_complete_clipboard_request)).@"fn";
    try std.testing.expect(complete_clipboard_request.return_type.? == bool);
    try std.testing.expect(complete_clipboard_request.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(complete_clipboard_request.params[1].type.? == [*c]const u8);
    try std.testing.expect(complete_clipboard_request.params[2].type.? == ?*anyopaque);
    try std.testing.expect(complete_clipboard_request.params[3].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_key"));
    const surface_key = @typeInfo(@TypeOf(c.ghostty_surface_key)).@"fn";
    try std.testing.expect(surface_key.return_type.? == bool);
    try std.testing.expect(surface_key.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_key.params[1].type.? == c.ghostty_input_key_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_key_is_binding"));
    const surface_key_is_binding = @typeInfo(@TypeOf(c.ghostty_surface_key_is_binding)).@"fn";
    try std.testing.expect(surface_key_is_binding.return_type.? == bool);
    try std.testing.expect(surface_key_is_binding.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_key_is_binding.params[1].type.? == c.ghostty_input_key_s);
    try std.testing.expect(surface_key_is_binding.params[2].type.? == [*c]c.ghostty_binding_flags_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_key_translation_mods"));
    const surface_key_translation_mods =
        @typeInfo(@TypeOf(c.ghostty_surface_key_translation_mods)).@"fn";
    try std.testing.expect(surface_key_translation_mods.return_type.? == c.ghostty_input_mods_e);
    try std.testing.expect(surface_key_translation_mods.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_key_translation_mods.params[1].type.? == c.ghostty_input_mods_e);
    try std.testing.expectEqual(@as(c_int, 1 << 0), c.GHOSTTY_MODS_SHIFT);
    try std.testing.expectEqual(@as(c_int, 1 << 1), c.GHOSTTY_MODS_CTRL);
    try std.testing.expectEqual(@as(c_int, 1 << 2), c.GHOSTTY_MODS_ALT);
    try std.testing.expectEqual(@as(c_int, 1 << 3), c.GHOSTTY_MODS_SUPER);
    try std.testing.expectEqual(@as(c_int, 1 << 4), c.GHOSTTY_MODS_CAPS);
    try std.testing.expectEqual(@as(c_int, 1 << 5), c.GHOSTTY_MODS_NUM);
    try std.testing.expectEqual(@as(c_int, 1 << 6), c.GHOSTTY_MODS_SHIFT_RIGHT);
    try std.testing.expectEqual(@as(c_int, 1 << 7), c.GHOSTTY_MODS_CTRL_RIGHT);
    try std.testing.expectEqual(@as(c_int, 1 << 8), c.GHOSTTY_MODS_ALT_RIGHT);
    try std.testing.expectEqual(@as(c_int, 1 << 9), c.GHOSTTY_MODS_SUPER_RIGHT);
    try std.testing.expectEqual(@as(c_int, 1 << 0), c.GHOSTTY_BINDING_FLAGS_CONSUMED);
    try std.testing.expectEqual(@as(c_int, 1 << 1), c.GHOSTTY_BINDING_FLAGS_ALL);
    try std.testing.expectEqual(@as(c_int, 1 << 2), c.GHOSTTY_BINDING_FLAGS_GLOBAL);
    try std.testing.expectEqual(@as(c_int, 1 << 3), c.GHOSTTY_BINDING_FLAGS_PERFORMABLE);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_mouse_captured"));
    const mouse_captured = @typeInfo(@TypeOf(c.ghostty_surface_mouse_captured)).@"fn";
    try std.testing.expect(mouse_captured.return_type.? == bool);
    try std.testing.expect(mouse_captured.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_mouse_button"));
    const mouse_button = @typeInfo(@TypeOf(c.ghostty_surface_mouse_button)).@"fn";
    try std.testing.expect(mouse_button.return_type.? == bool);
    try std.testing.expect(mouse_button.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(mouse_button.params[1].type.? == c.ghostty_input_mouse_state_e);
    try std.testing.expect(mouse_button.params[2].type.? == c.ghostty_input_mouse_button_e);
    try std.testing.expect(mouse_button.params[3].type.? == c.ghostty_input_mods_e);
    try std.testing.expect(@hasDecl(c, "ghostty_input_mouse_pressure_e"));
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.MousePressureStage.none)),
        c.GHOSTTY_MOUSE_PRESSURE_NONE,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.MousePressureStage.normal)),
        c.GHOSTTY_MOUSE_PRESSURE_NORMAL,
    );
    try std.testing.expectEqual(
        @as(c_int, @intFromEnum(CAPI.MousePressureStage.deep)),
        c.GHOSTTY_MOUSE_PRESSURE_DEEP,
    );
    try std.testing.expect(@hasDecl(c, "ghostty_surface_mouse_pos"));
    const mouse_pos = @typeInfo(@TypeOf(c.ghostty_surface_mouse_pos)).@"fn";
    try std.testing.expect(mouse_pos.return_type.? == bool);
    try std.testing.expect(mouse_pos.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(mouse_pos.params[1].type.? == f64);
    try std.testing.expect(mouse_pos.params[2].type.? == f64);
    try std.testing.expect(mouse_pos.params[3].type.? == c.ghostty_input_mods_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_mouse_scroll"));
    const mouse_scroll = @typeInfo(@TypeOf(c.ghostty_surface_mouse_scroll)).@"fn";
    try std.testing.expect(mouse_scroll.return_type.? == bool);
    try std.testing.expect(mouse_scroll.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(mouse_scroll.params[1].type.? == f64);
    try std.testing.expect(mouse_scroll.params[2].type.? == f64);
    try std.testing.expect(mouse_scroll.params[3].type.? == c.ghostty_input_scroll_mods_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_mouse_pressure"));
    const mouse_pressure = @typeInfo(@TypeOf(c.ghostty_surface_mouse_pressure)).@"fn";
    try std.testing.expect(mouse_pressure.return_type.? == bool);
    try std.testing.expect(mouse_pressure.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(mouse_pressure.params[1].type.? == c.ghostty_input_mouse_pressure_e);
    try std.testing.expect(mouse_pressure.params[2].type.? == f64);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_has_selection"));
    const surface_has_selection = @typeInfo(@TypeOf(c.ghostty_surface_has_selection)).@"fn";
    try std.testing.expect(surface_has_selection.return_type.? == bool);
    try std.testing.expect(surface_has_selection.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_select_cursor_cell"));
    const surface_select_cursor_cell = @typeInfo(@TypeOf(c.ghostty_surface_select_cursor_cell)).@"fn";
    try std.testing.expect(surface_select_cursor_cell.return_type.? == bool);
    try std.testing.expect(surface_select_cursor_cell.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_select_viewport_rows"));
    const surface_select_viewport_rows =
        @typeInfo(@TypeOf(c.ghostty_surface_select_viewport_rows)).@"fn";
    try std.testing.expect(surface_select_viewport_rows.return_type.? == bool);
    try std.testing.expect(surface_select_viewport_rows.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_select_viewport_rows.params[1].type.? == u32);
    try std.testing.expect(surface_select_viewport_rows.params[2].type.? == u32);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_clear_selection"));
    const surface_clear_selection = @typeInfo(@TypeOf(c.ghostty_surface_clear_selection)).@"fn";
    try std.testing.expect(surface_clear_selection.return_type.? == bool);
    try std.testing.expect(surface_clear_selection.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_read_selection"));
    const surface_read_selection = @typeInfo(@TypeOf(c.ghostty_surface_read_selection)).@"fn";
    try std.testing.expect(surface_read_selection.return_type.? == bool);
    try std.testing.expect(surface_read_selection.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_read_selection.params[1].type.? == [*c]c.ghostty_text_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_read_text"));
    const surface_read_text = @typeInfo(@TypeOf(c.ghostty_surface_read_text)).@"fn";
    try std.testing.expect(surface_read_text.return_type.? == bool);
    try std.testing.expect(surface_read_text.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_read_text.params[1].type.? == c.ghostty_selection_s);
    try std.testing.expect(surface_read_text.params[2].type.? == [*c]c.ghostty_text_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_read_scrollback"));
    const surface_read_scrollback = @typeInfo(@TypeOf(c.ghostty_surface_read_scrollback)).@"fn";
    try std.testing.expect(surface_read_scrollback.return_type.? == bool);
    try std.testing.expect(surface_read_scrollback.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_read_scrollback.params[1].type.? == usize);
    try std.testing.expect(surface_read_scrollback.params[2].type.? == [*c]c.ghostty_text_s);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_free_text"));
    const surface_free_text = @typeInfo(@TypeOf(c.ghostty_surface_free_text)).@"fn";
    try std.testing.expect(surface_free_text.return_type.? == void);
    try std.testing.expect(surface_free_text.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_free_text.params[1].type.? == [*c]c.ghostty_text_s);
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_UNKNOWN, c.GHOSTTY_MOUSE_BUTTON_UNKNOWN);
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_LEFT, c.GHOSTTY_MOUSE_BUTTON_LEFT);
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_RIGHT, c.GHOSTTY_MOUSE_BUTTON_RIGHT);
    try std.testing.expectEqual(c.GHOSTTY_MOUSE_MIDDLE, c.GHOSTTY_MOUSE_BUTTON_MIDDLE);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_ime_point"));
    const surface_ime_point = @typeInfo(@TypeOf(c.ghostty_surface_ime_point)).@"fn";
    try std.testing.expect(surface_ime_point.return_type.? == bool);
    try std.testing.expect(surface_ime_point.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_ime_point.params[1].type.? == [*c]f64);
    try std.testing.expect(surface_ime_point.params[2].type.? == [*c]f64);
    try std.testing.expect(surface_ime_point.params[3].type.? == [*c]f64);
    try std.testing.expect(surface_ime_point.params[4].type.? == [*c]f64);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_request_close"));
    const request_close = @typeInfo(@TypeOf(c.ghostty_surface_request_close)).@"fn";
    try std.testing.expect(request_close.return_type.? == bool);
    try std.testing.expect(request_close.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_split"));
    const surface_split = @typeInfo(@TypeOf(c.ghostty_surface_split)).@"fn";
    try std.testing.expect(surface_split.return_type.? == bool);
    try std.testing.expect(surface_split.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(surface_split.params[1].type.? == c.ghostty_action_split_direction_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_split_focus"));
    const split_focus = @typeInfo(@TypeOf(c.ghostty_surface_split_focus)).@"fn";
    try std.testing.expect(split_focus.return_type.? == bool);
    try std.testing.expect(split_focus.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(split_focus.params[1].type.? == c.ghostty_action_goto_split_e);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_split_resize"));
    const split_resize = @typeInfo(@TypeOf(c.ghostty_surface_split_resize)).@"fn";
    try std.testing.expect(split_resize.return_type.? == bool);
    try std.testing.expect(split_resize.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(split_resize.params[1].type.? == c.ghostty_action_resize_split_direction_e);
    try std.testing.expect(split_resize.params[2].type.? == u16);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_split_equalize"));
    const split_equalize = @typeInfo(@TypeOf(c.ghostty_surface_split_equalize)).@"fn";
    try std.testing.expect(split_equalize.return_type.? == bool);
    try std.testing.expect(split_equalize.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_split_toggle_zoom"));
    const split_toggle_zoom = @typeInfo(@TypeOf(c.ghostty_surface_split_toggle_zoom)).@"fn";
    try std.testing.expect(split_toggle_zoom.return_type.? == bool);
    try std.testing.expect(split_toggle_zoom.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_binding_action"));
    const binding_action = @typeInfo(@TypeOf(c.ghostty_surface_binding_action)).@"fn";
    try std.testing.expect(binding_action.return_type.? == bool);
    try std.testing.expect(binding_action.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(binding_action.params[1].type.? == [*c]const u8);
    try std.testing.expect(binding_action.params[2].type.? == usize);
    try std.testing.expectEqual(
        c.GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS,
        c.GHOSTTY_CLOSE_TAB_MODE_THIS,
    );
    try std.testing.expectEqual(
        c.GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER,
        c.GHOSTTY_CLOSE_TAB_MODE_OTHER,
    );
    try std.testing.expectEqual(
        c.GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT,
        c.GHOSTTY_CLOSE_TAB_MODE_RIGHT,
    );
    try std.testing.expectEqual(
        c.GHOSTTY_ACTION_COLOR_KIND_FOREGROUND,
        c.GHOSTTY_COLOR_KIND_FOREGROUND,
    );
    try std.testing.expectEqual(
        c.GHOSTTY_ACTION_COLOR_KIND_BACKGROUND,
        c.GHOSTTY_COLOR_KIND_BACKGROUND,
    );
    try std.testing.expectEqual(
        c.GHOSTTY_ACTION_COLOR_KIND_CURSOR,
        c.GHOSTTY_COLOR_KIND_CURSOR,
    );
    try std.testing.expect(@hasDecl(c, "ghostty_surface_refresh"));
    const refresh = @typeInfo(@TypeOf(c.ghostty_surface_refresh)).@"fn";
    try std.testing.expect(refresh.return_type.? == bool);
    try std.testing.expect(refresh.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_draw"));
    const draw = @typeInfo(@TypeOf(c.ghostty_surface_draw)).@"fn";
    try std.testing.expect(draw.return_type.? == bool);
    try std.testing.expect(draw.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_display_realized"));
    const display_realized = @typeInfo(@TypeOf(c.ghostty_surface_display_realized)).@"fn";
    try std.testing.expect(display_realized.return_type.? == bool);
    try std.testing.expect(display_realized.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_display_unrealized"));
    const display_unrealized = @typeInfo(@TypeOf(c.ghostty_surface_display_unrealized)).@"fn";
    try std.testing.expect(display_unrealized.return_type.? == bool);
    try std.testing.expect(display_unrealized.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_surface_set_renderer_realized"));
    const set_renderer_realized = @typeInfo(@TypeOf(c.ghostty_surface_set_renderer_realized)).@"fn";
    try std.testing.expect(set_renderer_realized.return_type.? == bool);
    try std.testing.expect(set_renderer_realized.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(set_renderer_realized.params[1].type.? == bool);
    if (builtin.target.os.tag == .linux) {
        try std.testing.expect(@hasDecl(c, "ghostty_inspector_opengl_init"));
        const opengl_init = @typeInfo(@TypeOf(c.ghostty_inspector_opengl_init)).@"fn";
        try std.testing.expect(opengl_init.return_type.? == bool);
        try std.testing.expect(opengl_init.params[0].type.? == c.ghostty_inspector_t);
        try std.testing.expect(opengl_init.params[1].type.? == [*c]const u8);
        try std.testing.expect(@hasDecl(c, "ghostty_inspector_opengl_render"));
        const opengl_render = @typeInfo(@TypeOf(c.ghostty_inspector_opengl_render)).@"fn";
        try std.testing.expect(opengl_render.return_type.? == bool);
        try std.testing.expect(opengl_render.params[0].type.? == c.ghostty_inspector_t);
        try std.testing.expect(@hasDecl(c, "ghostty_inspector_opengl_shutdown"));
        const opengl_shutdown = @typeInfo(@TypeOf(c.ghostty_inspector_opengl_shutdown)).@"fn";
        try std.testing.expect(opengl_shutdown.return_type.? == bool);
        try std.testing.expect(opengl_shutdown.params[0].type.? == c.ghostty_inspector_t);

        try std.testing.expect(!@hasDecl(c, "ghostty_surface_set_display_id"));
        try std.testing.expect(!@hasDecl(c, "ghostty_surface_quicklook_font"));
        try std.testing.expect(!@hasDecl(c, "ghostty_surface_quicklook_word"));
        try std.testing.expect(!@hasDecl(c, "ghostty_inspector_metal_init"));
        try std.testing.expect(!@hasDecl(c, "ghostty_inspector_metal_render"));
        try std.testing.expect(!@hasDecl(c, "ghostty_inspector_metal_shutdown"));
        try std.testing.expect(!@hasDecl(c, "ghostty_set_window_background_blur"));
    }
    try std.testing.expect(@hasDecl(c, "ghostty_surface_inspector"));
    const surface_inspector = @typeInfo(@TypeOf(c.ghostty_surface_inspector)).@"fn";
    try std.testing.expect(surface_inspector.return_type.? == c.ghostty_inspector_t);
    try std.testing.expect(surface_inspector.params[0].type.? == c.ghostty_surface_t);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_free"));
    const inspector_free = @typeInfo(@TypeOf(c.ghostty_inspector_free)).@"fn";
    try std.testing.expect(inspector_free.return_type.? == void);
    try std.testing.expect(inspector_free.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_set_focus"));
    const inspector_set_focus = @typeInfo(@TypeOf(c.ghostty_inspector_set_focus)).@"fn";
    try std.testing.expect(inspector_set_focus.return_type.? == bool);
    try std.testing.expect(inspector_set_focus.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_set_focus.params[1].type.? == bool);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_set_content_scale"));
    const inspector_set_content_scale = @typeInfo(@TypeOf(c.ghostty_inspector_set_content_scale)).@"fn";
    try std.testing.expect(inspector_set_content_scale.return_type.? == bool);
    try std.testing.expect(inspector_set_content_scale.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_set_content_scale.params[1].type.? == f64);
    try std.testing.expect(inspector_set_content_scale.params[2].type.? == f64);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_set_size"));
    const inspector_set_size = @typeInfo(@TypeOf(c.ghostty_inspector_set_size)).@"fn";
    try std.testing.expect(inspector_set_size.return_type.? == bool);
    try std.testing.expect(inspector_set_size.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_set_size.params[1].type.? == u32);
    try std.testing.expect(inspector_set_size.params[2].type.? == u32);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_mouse_button"));
    const inspector_mouse_button = @typeInfo(@TypeOf(c.ghostty_inspector_mouse_button)).@"fn";
    try std.testing.expect(inspector_mouse_button.return_type.? == bool);
    try std.testing.expect(inspector_mouse_button.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_mouse_button.params[1].type.? == c.ghostty_input_mouse_state_e);
    try std.testing.expect(inspector_mouse_button.params[2].type.? == c.ghostty_input_mouse_button_e);
    try std.testing.expect(inspector_mouse_button.params[3].type.? == c.ghostty_input_mods_e);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_mouse_pos"));
    const inspector_mouse_pos = @typeInfo(@TypeOf(c.ghostty_inspector_mouse_pos)).@"fn";
    try std.testing.expect(inspector_mouse_pos.return_type.? == bool);
    try std.testing.expect(inspector_mouse_pos.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_mouse_pos.params[1].type.? == f64);
    try std.testing.expect(inspector_mouse_pos.params[2].type.? == f64);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_mouse_scroll"));
    const inspector_mouse_scroll = @typeInfo(@TypeOf(c.ghostty_inspector_mouse_scroll)).@"fn";
    try std.testing.expect(inspector_mouse_scroll.return_type.? == bool);
    try std.testing.expect(inspector_mouse_scroll.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_mouse_scroll.params[1].type.? == f64);
    try std.testing.expect(inspector_mouse_scroll.params[2].type.? == f64);
    try std.testing.expect(inspector_mouse_scroll.params[3].type.? == c.ghostty_input_scroll_mods_t);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_key"));
    const inspector_key = @typeInfo(@TypeOf(c.ghostty_inspector_key)).@"fn";
    try std.testing.expect(inspector_key.return_type.? == bool);
    try std.testing.expect(inspector_key.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_key.params[1].type.? == c.ghostty_input_action_e);
    try std.testing.expect(inspector_key.params[2].type.? == c.ghostty_input_key_e);
    try std.testing.expect(inspector_key.params[3].type.? == c.ghostty_input_mods_e);
    try std.testing.expect(@hasDecl(c, "ghostty_inspector_text"));
    const inspector_text = @typeInfo(@TypeOf(c.ghostty_inspector_text)).@"fn";
    try std.testing.expect(inspector_text.return_type.? == bool);
    try std.testing.expect(inspector_text.params[0].type.? == c.ghostty_inspector_t);
    try std.testing.expect(inspector_text.params[1].type.? == [*c]const u8);
    const selection_fields = .{
        .{ "top_left", "tl" },
        .{ "bottom_right", "br" },
        .{ "rectangle", "rectangle" },
    };
    inline for (selection_fields) |field| {
        try std.testing.expectEqual(
            @offsetOf(c.ghostty_selection_s, field[0]),
            @offsetOf(CAPI.Selection, field[1]),
        );
    }
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

test "render presentation callback setter is per surface" {
    const Callbacks = struct {
        fn renderPresented(_: ?*anyopaque, _: u64) callconv(.c) void {}
    };

    var parent_userdata: u8 = 0;
    var child_userdata: u8 = 0;
    var parent: Surface = undefined;
    parent.render_presented_cb = null;
    parent.render_presented_userdata = null;
    var child: Surface = undefined;
    child.render_presented_cb = null;
    child.render_presented_userdata = null;

    try std.testing.expect(CAPI.ghostty_surface_set_render_presented_callback(
        &parent,
        Callbacks.renderPresented,
        &parent_userdata,
    ));
    try std.testing.expectEqual(Callbacks.renderPresented, parent.render_presented_cb);
    try std.testing.expectEqual(
        @as(?*anyopaque, &parent_userdata),
        parent.render_presented_userdata,
    );
    try std.testing.expectEqual(null, child.render_presented_cb);
    try std.testing.expectEqual(null, child.render_presented_userdata);

    try std.testing.expect(CAPI.ghostty_surface_set_render_presented_callback(
        &child,
        Callbacks.renderPresented,
        &child_userdata,
    ));
    try std.testing.expectEqual(Callbacks.renderPresented, child.render_presented_cb);
    try std.testing.expectEqual(
        @as(?*anyopaque, &child_userdata),
        child.render_presented_userdata,
    );
    try std.testing.expectEqual(
        @as(?*anyopaque, &parent_userdata),
        parent.render_presented_userdata,
    );

    // Registration is one-shot because already-submitted frames snapshot the
    // callback and userdata. Replacing either value could otherwise let an
    // asynchronous presentation dereference userdata the embedder has freed.
    try std.testing.expect(!CAPI.ghostty_surface_set_render_presented_callback(
        &parent,
        Callbacks.renderPresented,
        &child_userdata,
    ));
    try std.testing.expectEqual(Callbacks.renderPresented, parent.render_presented_cb);
    try std.testing.expectEqual(
        @as(?*anyopaque, &parent_userdata),
        parent.render_presented_userdata,
    );
}
