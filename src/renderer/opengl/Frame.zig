//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

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
    return completeFrame(
        self.renderer,
        self.target,
        self.presentation,
    );
}

fn completeFrame(
    renderer: anytype,
    target: anytype,
    presentation: ?FramePresentation,
) ?FramePresentation {
    // The target must reach the default framebuffer before the finish fence.
    // A failed blit is an unhealthy completion and cannot acknowledge a token.
    renderer.api.present(target.*) catch |err| {
        log.warn("Failed to present render target: err={}", .{err});
        renderer.frameCompleted(target, .unhealthy);
        return null;
    };

    renderer.api.finishFrame();
    const health = renderer.api.frameHealth();

    // Complete renderer bookkeeping while the draw lock is still held. The
    // generic renderer carries the returned value outward only after all of
    // its cleanup defers run; Thread delivers after its instrumentation ends.
    renderer.frameCompleted(target, health);
    return if (health == .healthy) presentation else null;
}

test "OpenGL acknowledges only after successful present and GPU completion" {
    const testing = std.testing;
    const Event = enum {
        present,
        finish,
        check_errors,
        frame_completed,
        gate,
        callback,
    };
    const State = struct {
        events: [6]Event = undefined,
        len: usize = 0,
        fail_present: bool = false,
        gl_healthy: bool = true,
        completed_health: ?Health = null,
        completed_count: usize = 0,

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

        fn finishFrame(self: *@This()) void {
            self.state.append(.finish);
        }

        fn frameHealth(self: *@This()) Health {
            self.state.append(.check_errors);
            return if (self.state.gl_healthy) .healthy else .unhealthy;
        }
    };
    const MockRenderer = struct {
        state: *State,
        api: MockAPI,

        fn frameCompleted(self: *@This(), _: *MockTarget, health: Health) void {
            self.state.completed_health = health;
            self.state.completed_count += 1;
            self.state.append(.frame_completed);
        }
    };
    const Harness = struct {
        fn complete(
            renderer: *MockRenderer,
            target: *MockTarget,
            presentation: ?FramePresentation,
        ) ?FramePresentation {
            if (@hasDecl(Self, "completeFrame")) {
                return Self.completeFrame(renderer, target, presentation);
            }

            // Exercise the pre-fix production order. Once completeFrame is
            // introduced, the branch above exercises that implementation.
            renderer.api.finishFrame();
            const health = renderer.api.frameHealth();
            if (health == .healthy) {
                renderer.api.present(target.*) catch {
                    renderer.frameCompleted(target, .unhealthy);
                    return null;
                };
            }
            renderer.frameCompleted(target, health);
            return if (health == .healthy) presentation else null;
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

    const completed = Harness.complete(
        &renderer,
        &target,
        presentation,
    );
    try testing.expectEqual(Health.healthy, state.completed_health.?);
    try testing.expectEqual(@as(usize, 1), state.completed_count);
    try testing.expectEqualSlices(
        Event,
        &.{ .present, .finish, .check_errors, .frame_completed },
        state.events[0..state.len],
    );
    try testing.expectEqual(@as(u64, 42), completed.?.token);

    completed.?.deliver();
    try testing.expectEqualSlices(
        Event,
        &.{
            .present,
            .finish,
            .check_errors,
            .frame_completed,
            .gate,
            .callback,
        },
        state.events[0..state.len],
    );

    state = .{ .fail_present = true };
    renderer = .{
        .state = &state,
        .api = .{ .state = &state },
    };
    try testing.expectEqual(
        null,
        Harness.complete(&renderer, &target, presentation),
    );
    try testing.expectEqual(Health.unhealthy, state.completed_health.?);
    try testing.expectEqual(@as(usize, 1), state.completed_count);
    try testing.expectEqualSlices(
        Event,
        &.{ .present, .frame_completed },
        state.events[0..state.len],
    );

    state = .{ .gl_healthy = false };
    renderer = .{
        .state = &state,
        .api = .{ .state = &state },
    };
    try testing.expectEqual(
        null,
        Harness.complete(&renderer, &target, presentation),
    );
    try testing.expectEqual(Health.unhealthy, state.completed_health.?);
    try testing.expectEqual(@as(usize, 1), state.completed_count);
    try testing.expectEqualSlices(
        Event,
        &.{ .present, .finish, .check_errors, .frame_completed },
        state.events[0..state.len],
    );
}
