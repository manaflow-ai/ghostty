//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");

const Renderer = @import("../generic.zig").Renderer(OpenGL);
const OpenGL = @import("../OpenGL.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const rendererpkg = @import("../../renderer.zig");
const FramePresentation = rendererpkg.FramePresentation;
const Health = rendererpkg.Health;

const log = std.log.scoped(.opengl);

/// Options for beginning a frame.
pub const Options = struct {};

renderer: *Renderer,
target: *Target,
presentation: ?FramePresentation,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
    presentation: ?FramePresentation,
) !Self {
    _ = opts;

    return .{
        .renderer = renderer,
        .target = target,
        .presentation = presentation,
    };
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    _ = self;
    return RenderPass.begin(.{ .attachments = attachments });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
///
/// NOTE: For OpenGL, `sync` is ignored and we always block.
pub fn complete(self: *const Self, sync: bool) ?FramePresentation {
    _ = sync;
    gl.finish();

    // If there are any GL errors, consider the frame unhealthy.
    const health: Health = if (gl.errors.getError()) .healthy else |_| .unhealthy;

    return completeAfterFinish(
        self.renderer,
        self.target,
        health,
        self.presentation,
    );
}

fn completeAfterFinish(
    renderer: anytype,
    target: anytype,
    health: Health,
    presentation: ?FramePresentation,
) ?FramePresentation {
    // If the frame is healthy, present it.
    if (health == .healthy) {
        renderer.api.present(target.*) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
            renderer.frameCompleted(.unhealthy);
            return null;
        };
    }

    // Complete renderer bookkeeping while the draw lock is still held. The
    // generic renderer receives the returned value and delivers it only after
    // all of its cleanup and lock-release defers have run.
    renderer.frameCompleted(health);
    return if (health == .healthy) presentation else null;
}

test "OpenGL completion defers successful delivery and drops failed frames" {
    const testing = std.testing;
    const Event = enum { present, frame_completed, gate, callback };
    const State = struct {
        events: [4]Event = undefined,
        len: usize = 0,
        fail_present: bool = false,
        completed_health: ?Health = null,

        fn append(self: *@This(), event: Event) void {
            self.events[self.len] = event;
            self.len += 1;
        }

        fn gate(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(.gate);
        }

        fn callback(userdata: ?*anyopaque, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.append(.callback);
        }
    };
    const MockTarget = struct {};
    const MockAPI = struct {
        state: *State,

        fn present(self: *@This(), _: MockTarget) !void {
            self.state.append(.present);
            if (self.state.fail_present) return error.PresentFailed;
        }
    };
    const MockRenderer = struct {
        state: *State,
        api: MockAPI,

        fn frameCompleted(self: *@This(), health: Health) void {
            self.state.completed_health = health;
            self.state.append(.frame_completed);
        }
    };

    var state: State = .{};
    var renderer: MockRenderer = .{
        .state = &state,
        .api = .{ .state = &state },
    };
    var target: MockTarget = .{};
    const presentation: FramePresentation = .{
        .callback = &State.callback,
        .userdata = &state,
        .token = 42,
        .delivery_gate = &State.gate,
        .delivery_gate_userdata = &state,
    };

    const completed = completeAfterFinish(
        &renderer,
        &target,
        .healthy,
        presentation,
    );
    try testing.expectEqual(Health.healthy, state.completed_health.?);
    try testing.expectEqualSlices(
        Event,
        &.{ .present, .frame_completed },
        state.events[0..state.len],
    );
    try testing.expectEqual(@as(u64, 42), completed.?.token);

    completed.?.deliver();
    try testing.expectEqualSlices(
        Event,
        &.{ .present, .frame_completed, .gate, .callback },
        state.events[0..state.len],
    );

    state = .{ .fail_present = true };
    renderer = .{
        .state = &state,
        .api = .{ .state = &state },
    };
    try testing.expectEqual(
        null,
        completeAfterFinish(&renderer, &target, .healthy, presentation),
    );
    try testing.expectEqual(Health.unhealthy, state.completed_health.?);
    try testing.expectEqualSlices(
        Event,
        &.{ .present, .frame_completed },
        state.events[0..state.len],
    );

    state = .{};
    renderer = .{
        .state = &state,
        .api = .{ .state = &state },
    };
    try testing.expectEqual(
        null,
        completeAfterFinish(&renderer, &target, .unhealthy, presentation),
    );
    try testing.expectEqual(Health.unhealthy, state.completed_health.?);
    try testing.expectEqualSlices(
        Event,
        &.{.frame_completed},
        state.events[0..state.len],
    );
}
