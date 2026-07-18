//! C ABI for the standalone semantic-scene Metal renderer.
//!
//! A handle is single-threaded. Event callbacks must not block or re-enter the
//! handle. No function creates a Surface, apprt.Surface, termio, PTY, parser,
//! mailbox, or terminal IO thread.

const std = @import("std");
const state = &@import("../../global.zig").state;
const configpkg = @import("../../config.zig");
const font = @import("../../font/main.zig");
const rendererpkg = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const Scene = rendererpkg.Scene;
const Renderer = rendererpkg.Renderer;

const log = std.log.scoped(.scene_renderer_c_api);

pub const Status = enum(c_int) {
    success = 0,
    invalid_argument = 1,
    unsupported = 2,
    out_of_memory = 3,
    invalid_scene = 4,
    replay_rejected = 5,
    unsupported_capability = 6,
    limit_exceeded = 7,
    no_scene = 8,
    busy = 9,
    lease_mismatch = 10,
    gpu_error = 11,
    outstanding_leases = 12,
    internal_error = 13,
};

pub const Event = enum(c_int) {
    frame_ready = 1,
    renderer_healthy = 2,
    renderer_unhealthy = 3,
};

pub const PaddingMode = enum(c_int) {
    explicit = 0,
    config = 1,
};

pub const Frame = extern struct {
    renderer_epoch: u64,
    terminal_id: [16]u8,
    terminal_epoch: u64,
    content_sequence: u64,
    presentation_id: [16]u8,
    presentation_generation: u64,
    presentation_sequence: u64,
    frame_sequence: u64,
    iosurface_id: u32,
    width: u32,
    height: u32,
};

pub const EventCallback = *const fn (
    ?*anyopaque,
    Event,
    ?*const Frame,
) callconv(.c) void;

pub const Options = extern struct {
    config: ?*configpkg.Config,
    width: u32,
    height: u32,
    padding_top: u32,
    padding_right: u32,
    padding_bottom: u32,
    padding_left: u32,
    padding_mode: PaddingMode,
    content_scale: f64,
    renderer_epoch: u64,
    terminal_id: [16]u8,
    terminal_epoch: u64,
    presentation_id: [16]u8,
    presentation_generation: u64,
    max_scene_bytes: usize,
    max_allocation_bytes: usize,
    userdata: ?*anyopaque,
    event_callback: ?EventCallback,
};

pub const Metrics = extern struct {
    columns: u32,
    rows: u32,
    cell_width: u32,
    cell_height: u32,
    padding_top: u32,
    padding_right: u32,
    padding_bottom: u32,
    padding_left: u32,
};

pub const Configure = extern struct {
    width: u32,
    height: u32,
    padding_top: u32,
    padding_right: u32,
    padding_bottom: u32,
    padding_left: u32,
    renderer_epoch: u64,
    terminal_id: [16]u8,
    terminal_epoch: u64,
    presentation_id: [16]u8,
    presentation_generation: u64,
};

const SceneRenderer = struct {
    alloc: std.mem.Allocator,
    font_set: font.SharedGridSet,
    font_key: font.SharedGridSet.Key,
    renderer: Renderer,
    receiver: Scene.Receiver,
    renderer_epoch: u64,
    next_frame_sequence: u64 = 1,
    userdata: ?*anyopaque,
    event_callback: ?EventCallback,
    published_count: u64 = 0,

    fn eventSink(context: ?*anyopaque, event: Scene.Export.Event) void {
        const self: *SceneRenderer = @ptrCast(@alignCast(context orelse return));
        switch (event) {
            .renderer_health => |health| if (self.event_callback) |callback|
                callback(
                    self.userdata,
                    switch (health) {
                        .healthy => .renderer_healthy,
                        .unhealthy => .renderer_unhealthy,
                    },
                    null,
                ),
            .frame_ready => |lease| {
                const frame = frameFromLease(lease);
                self.published_count += 1;
                if (self.event_callback) |callback|
                    callback(self.userdata, .frame_ready, &frame);
            },
        }
    }

    fn deinit(self: *SceneRenderer) void {
        self.receiver.deinit();
        self.renderer.deinit();
        self.font_set.deref(self.font_key);
        self.font_set.deinit();
    }
};

pub export fn ghostty_scene_renderer_new(
    options_ptr: ?*const Options,
    status_out: ?*Status,
) ?*SceneRenderer {
    const options = options_ptr orelse {
        setStatus(status_out, .invalid_argument);
        return null;
    };
    _ = options.config orelse {
        setStatus(status_out, .invalid_argument);
        return null;
    };
    const result = newImpl(options) catch |err| {
        setStatus(status_out, statusForError(err));
        return null;
    };
    setStatus(status_out, .success);
    return result;
}

fn newImpl(options: *const Options) !*SceneRenderer {
    const config = options.config orelse return error.InvalidArgument;
    try validateOptions(options);
    const alloc = state.alloc;
    const self = try alloc.create(SceneRenderer);
    errdefer alloc.destroy(self);

    var font_set = try font.SharedGridSet.init(alloc);
    errdefer font_set.deinit();
    var font_config = try font.SharedGridSet.DerivedConfig.init(
        alloc,
        config,
    );
    defer font_config.deinit();
    const dpi: u16 = @intFromFloat(@round(
        options.content_scale * font.face.default_dpi,
    ));
    const font_key, const font_grid = try font_set.ref(&font_config, .{
        .points = config.@"font-size",
        .xdpi = dpi,
        .ydpi = dpi,
    });
    errdefer font_set.deref(font_key);

    var derived = try Renderer.DerivedConfig.init(alloc, config);
    errdefer derived.deinit();
    const size = renderSize(options, config, font_grid);
    var receiver = try Scene.Receiver.init(
        alloc,
        receiverOptions(options, config),
    );
    errdefer receiver.deinit();
    var renderer = try Renderer.initScene(alloc, .{
        .config = derived,
        .font_grid = font_grid,
        .size = size,
        .event_sink = .{
            .context = self,
            .callback = &SceneRenderer.eventSink,
        },
    });
    errdefer renderer.deinit();

    self.* = .{
        .alloc = alloc,
        .font_set = font_set,
        .font_key = font_key,
        .renderer = renderer,
        .receiver = receiver,
        .renderer_epoch = options.renderer_epoch,
        .userdata = options.userdata,
        .event_callback = options.event_callback,
    };
    return self;
}

/// Destruction is retryable. Outstanding frame leases leave the handle alive.
pub export fn ghostty_scene_renderer_destroy(
    self: ?*SceneRenderer,
) Status {
    const value = self orelse return .invalid_argument;
    if (!value.renderer.sceneCanDestroy()) return .outstanding_leases;
    const alloc = value.alloc;
    value.deinit();
    alloc.destroy(value);
    return .success;
}

/// Reset route identity and pixel size. The renderer epoch must advance.
/// Existing leases from the older epoch remain valid until exactly released.
pub export fn ghostty_scene_renderer_configure(
    self: ?*SceneRenderer,
    configure_ptr: ?*const Configure,
) Status {
    const value = self orelse return .invalid_argument;
    const configure = configure_ptr orelse return .invalid_argument;
    validateConfigure(value, configure) catch |err|
        return statusForError(err);
    value.receiver.reset(.{
        .terminal_id = configure.terminal_id,
        .terminal_epoch = configure.terminal_epoch,
        .presentation_id = configure.presentation_id,
        .presentation_generation = configure.presentation_generation,
        .supported_capabilities = .baseline,
        .limits = value.receiver.limits,
        .color_defaults = value.receiver.color_defaults,
    }) catch |err| return statusForError(err);
    value.renderer.size.padding = .{
        .top = configure.padding_top,
        .right = configure.padding_right,
        .bottom = configure.padding_bottom,
        .left = configure.padding_left,
    };
    value.renderer.setSceneSize(
        configure.width,
        configure.height,
    ) catch |err| return statusForError(err);
    value.renderer_epoch = configure.renderer_epoch;
    value.next_frame_sequence = 1;
    return .success;
}

/// Return the exact font-grid and padding geometry owned by this renderer.
/// The result changes only after a successful configure call.
pub export fn ghostty_scene_renderer_get_metrics(
    self: ?*SceneRenderer,
    metrics_out: ?*Metrics,
) Status {
    const value = self orelse return .invalid_argument;
    const out = metrics_out orelse return .invalid_argument;
    const size = value.renderer.size;
    const grid = size.grid();
    out.* = .{
        .columns = @intCast(grid.columns),
        .rows = @intCast(grid.rows),
        .cell_width = size.cell.width,
        .cell_height = size.cell.height,
        .padding_top = size.padding.top,
        .padding_right = size.padding.right,
        .padding_bottom = size.padding.bottom,
        .padding_left = size.padding.left,
    };
    return .success;
}

/// Decode and atomically replace the retained latest scene. This never queues
/// byte payloads, so updates remain bounded even while all frame slots are
/// leased by the host.
pub export fn ghostty_scene_renderer_apply(
    self: ?*SceneRenderer,
    bytes: ?[*]const u8,
    len: usize,
) Status {
    const value = self orelse return .invalid_argument;
    const ptr = bytes orelse return .invalid_argument;
    const kind = value.receiver.apply(ptr[0..len]) catch |err|
        return statusForError(err);
    const projection = value.receiver.projection() catch |err|
        return statusForError(err);
    switch (kind) {
        .initial, .rematerialized => value.renderer.projectScene(projection) catch |err|
            return statusForError(err),
        .presentation_metadata => value.renderer.projectPresentationScene(projection) catch |err|
            return statusForError(err),
    }
    return .success;
}

pub export fn ghostty_scene_renderer_render(
    self: ?*SceneRenderer,
) Status {
    const value = self orelse return .invalid_argument;
    const scene = value.receiver.current() catch return .no_scene;
    const sequence = value.next_frame_sequence;
    if (sequence == 0) return .internal_error;
    const published_before = value.published_count;
    value.renderer.drawSceneFrame(.{
        .renderer_epoch = value.renderer_epoch,
        .terminal_id = scene.canonical.ref.terminal_id,
        .terminal_epoch = scene.canonical.ref.terminal_epoch,
        .content_sequence = scene.canonical.ref.content_sequence,
        .presentation_id = scene.presentation.ref.presentation_id,
        .presentation_generation = scene.presentation.ref.generation,
        .presentation_sequence = scene.presentation.ref.sequence,
        .frame_sequence = sequence,
    }) catch |err| return statusForError(err);
    if (value.published_count == published_before) return .gpu_error;
    value.next_frame_sequence = Scene.nextSequence(sequence) catch
        return .internal_error;
    return .success;
}

/// Borrowed IOSurfaceRef. It remains valid and immutable only while the exact
/// lease is held. This call does not transfer Core Foundation ownership.
pub export fn ghostty_scene_renderer_borrow_iosurface(
    self: ?*SceneRenderer,
    frame_ptr: ?*const Frame,
    surface_out: ?*?*anyopaque,
) Status {
    const value = self orelse return .invalid_argument;
    const frame = frame_ptr orelse return .invalid_argument;
    const out = surface_out orelse return .invalid_argument;
    const target = value.renderer.sceneTarget(leaseFromFrame(frame.*)) catch |err|
        return statusForError(err);
    out.* = @ptrCast(target.surface);
    return .success;
}

/// Retained IOSurfaceRef. Retention extends object lifetime, not pixel
/// immutability. The exact frame lease must still remain held until the host's
/// GPU copy completes.
pub export fn ghostty_scene_renderer_retain_iosurface(
    self: ?*SceneRenderer,
    frame_ptr: ?*const Frame,
    surface_out: ?*?*anyopaque,
) Status {
    const status = ghostty_scene_renderer_borrow_iosurface(
        self,
        frame_ptr,
        surface_out,
    );
    if (status != .success) return status;
    const surface = surface_out.?.* orelse return .internal_error;
    const IOSurface = @import("macos").iosurface.IOSurface;
    const typed: *IOSurface = @ptrCast(@alignCast(surface));
    typed.retain();
    return .success;
}

pub export fn ghostty_scene_renderer_release_retained_iosurface(
    surface: ?*anyopaque,
) void {
    const value = surface orelse return;
    const IOSurface = @import("macos").iosurface.IOSurface;
    const typed: *IOSurface = @ptrCast(@alignCast(value));
    typed.release();
}

pub export fn ghostty_scene_renderer_release_frame(
    self: ?*SceneRenderer,
    frame_ptr: ?*const Frame,
) Status {
    const value = self orelse return .invalid_argument;
    const frame = frame_ptr orelse return .invalid_argument;
    value.renderer.releaseSceneFrame(leaseFromFrame(frame.*)) catch |err|
        return statusForError(err);
    return .success;
}

fn receiverOptions(
    options: *const Options,
    config: *const configpkg.Config,
) Scene.Receiver.Options {
    var limits: Scene.Limits = .{};
    if (options.max_scene_bytes != 0)
        limits.max_encoded_bytes = options.max_scene_bytes;
    if (options.max_allocation_bytes != 0)
        limits.max_allocation_bytes = options.max_allocation_bytes;
    return .{
        .terminal_id = options.terminal_id,
        .terminal_epoch = options.terminal_epoch,
        .presentation_id = options.presentation_id,
        .presentation_generation = options.presentation_generation,
        .supported_capabilities = .baseline,
        .limits = limits,
        .color_defaults = configuredColors(config),
    };
}

fn configuredColors(config: *const configpkg.Config) terminal.RenderState.Colors {
    var result = terminal.RenderState.empty.colors;
    result.background = config.background.toTerminalRGB();
    result.foreground = config.foreground.toTerminalRGB();
    // A null cursor lets Renderer.DerivedConfig apply cursor-color or its
    // cell-relative rules. Canonical OSC 12 state overrides it when present.
    result.cursor = null;
    result.palette = config.terminalPalette();
    return result;
}

fn renderSize(
    options: *const Options,
    config: *const configpkg.Config,
    grid: *font.SharedGrid,
) rendererpkg.Size {
    var result: rendererpkg.Size = .{
        .screen = .{ .width = options.width, .height = options.height },
        .cell = grid.cellSize(),
        .padding = .{},
    };
    const explicit: rendererpkg.Padding = switch (options.padding_mode) {
        .explicit => .{
            .top = options.padding_top,
            .right = options.padding_right,
            .bottom = options.padding_bottom,
            .left = options.padding_left,
        },
        .config => configuredPadding(config, options.content_scale),
    };
    if (options.padding_mode == .config and
        config.@"window-padding-balance" != .false)
    {
        result.balancePadding(explicit, config.@"window-padding-balance");
    } else {
        result.padding = explicit;
    }
    return result;
}

fn configuredPadding(
    config: *const configpkg.Config,
    content_scale: f64,
) rendererpkg.Padding {
    // Match Surface.DerivedConfig.scaledPadding's f32 arithmetic exactly.
    const dpi: f32 = @floatCast(content_scale * font.face.default_dpi);
    return .{
        .top = scalePadding(config.@"window-padding-y".top_left, dpi),
        .right = scalePadding(config.@"window-padding-x".bottom_right, dpi),
        .bottom = scalePadding(config.@"window-padding-y".bottom_right, dpi),
        .left = scalePadding(config.@"window-padding-x".top_left, dpi),
    };
}

fn scalePadding(points: u32, dpi: f32) u32 {
    return @intFromFloat(@floor(@as(f32, @floatFromInt(points)) * dpi / 72));
}

fn validateOptions(options: *const Options) !void {
    if (options.width == 0 or options.height == 0 or
        !std.math.isFinite(options.content_scale) or
        options.content_scale <= 0 or options.renderer_epoch == 0 or
        Scene.identityIsZero(options.terminal_id) or
        options.terminal_epoch == 0 or
        Scene.identityIsZero(options.presentation_id) or
        options.presentation_generation == 0 or
        (options.padding_mode != .explicit and options.padding_mode != .config) or
        (options.padding_mode == .config and
            (options.padding_top != 0 or options.padding_right != 0 or
                options.padding_bottom != 0 or options.padding_left != 0)) or
        options.padding_left > options.width or
        options.padding_right > options.width - options.padding_left or
        options.padding_top > options.height or
        options.padding_bottom > options.height - options.padding_top)
        return error.InvalidArgument;
    const scaled_dpi = options.content_scale * font.face.default_dpi;
    if (scaled_dpi < 1 or scaled_dpi > std.math.maxInt(u16))
        return error.InvalidArgument;
}

fn validateConfigure(self: *SceneRenderer, configure: *const Configure) !void {
    if (configure.width == 0 or configure.height == 0 or
        configure.renderer_epoch <= self.renderer_epoch or
        Scene.identityIsZero(configure.terminal_id) or
        configure.terminal_epoch == 0 or
        Scene.identityIsZero(configure.presentation_id) or
        configure.presentation_generation == 0 or
        configure.padding_left > configure.width or
        configure.padding_right > configure.width - configure.padding_left or
        configure.padding_top > configure.height or
        configure.padding_bottom > configure.height - configure.padding_top)
        return error.InvalidArgument;
}

fn frameFromLease(lease: Scene.Export.FrameLease) Frame {
    return .{
        .renderer_epoch = lease.metadata.renderer_epoch,
        .terminal_id = lease.metadata.terminal_id,
        .terminal_epoch = lease.metadata.terminal_epoch,
        .content_sequence = lease.metadata.content_sequence,
        .presentation_id = lease.metadata.presentation_id,
        .presentation_generation = lease.metadata.presentation_generation,
        .presentation_sequence = lease.metadata.presentation_sequence,
        .frame_sequence = lease.metadata.frame_sequence,
        .iosurface_id = lease.iosurface_id,
        .width = lease.width,
        .height = lease.height,
    };
}

fn leaseFromFrame(frame: Frame) Scene.Export.FrameLease {
    return .{
        .metadata = .{
            .renderer_epoch = frame.renderer_epoch,
            .terminal_id = frame.terminal_id,
            .terminal_epoch = frame.terminal_epoch,
            .content_sequence = frame.content_sequence,
            .presentation_id = frame.presentation_id,
            .presentation_generation = frame.presentation_generation,
            .presentation_sequence = frame.presentation_sequence,
            .frame_sequence = frame.frame_sequence,
        },
        .iosurface_id = frame.iosurface_id,
        .width = frame.width,
        .height = frame.height,
    };
}

fn setStatus(out: ?*Status, status: Status) void {
    if (out) |value| value.* = status;
}

fn statusForError(err: anyerror) Status {
    log.warn("scene renderer operation failed err={}", .{err});
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidArgument,
        error.InvalidRoute,
        error.InvalidSceneMetadata,
        error.InvalidSceneSize,
        => .invalid_argument,
        error.ReplayRejected => .replay_rejected,
        error.UnsupportedCapability,
        error.UnsupportedCustomShaders,
        error.UnsupportedSceneRenderer,
        => .unsupported_capability,
        error.LimitExceeded => .limit_exceeded,
        error.NoScene, error.MissingInitialState => .no_scene,
        error.Timeout, error.NoAvailableSlot, error.SceneDrawInProgress => .busy,
        error.LeaseMismatch => .lease_mismatch,
        error.MetalFailed, error.NoMetalDevice => .gpu_error,
        error.WrongTerminal,
        error.WrongPresentation,
        error.InvalidIdentity,
        error.InvalidSequence,
        => .replay_rejected,
        else => .invalid_scene,
    };
}

test "frame C conversion preserves the exact release fence" {
    const lease: Scene.Export.FrameLease = .{
        .metadata = .{
            .renderer_epoch = 1,
            .terminal_id = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .terminal_epoch = 2,
            .content_sequence = 3,
            .presentation_id = .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
            .presentation_generation = 4,
            .presentation_sequence = 5,
            .frame_sequence = 6,
        },
        .iosurface_id = 7,
        .width = 8,
        .height = 9,
    };
    try std.testing.expect(std.meta.eql(lease, leaseFromFrame(frameFromLease(lease))));
}

test "receiver defaults come from each renderer config" {
    var config = try configpkg.Config.default(std.testing.allocator);
    defer config.deinit();
    const configured_palette: terminal.color.RGB = .{
        .r = 0xF9,
        .g = 0x26,
        .b = 0x72,
    };
    config.palette.value[1] = configured_palette;
    config.palette.mask.set(1);

    const options: Options = .{
        .config = &config,
        .width = 800,
        .height = 600,
        .padding_top = 0,
        .padding_right = 0,
        .padding_bottom = 0,
        .padding_left = 0,
        .padding_mode = .explicit,
        .content_scale = 2,
        .renderer_epoch = 1,
        .terminal_id = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .terminal_epoch = 1,
        .presentation_id = .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .presentation_generation = 1,
        .max_scene_bytes = 0,
        .max_allocation_bytes = 0,
        .userdata = null,
        .event_callback = null,
    };
    const defaults = receiverOptions(&options, &config).color_defaults;
    try std.testing.expectEqual(config.background.toTerminalRGB(), defaults.background);
    try std.testing.expectEqual(config.foreground.toTerminalRGB(), defaults.foreground);
    try std.testing.expectEqual(configured_palette, defaults.palette[1]);
    try std.testing.expectEqual(config.terminalPalette(), defaults.palette);
    try std.testing.expectEqual(@as(?terminal.color.RGB, null), defaults.cursor);
}
