//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");

const mtl = @import("api.zig");
const Metal = @import("../Metal.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const rendererpkg = @import("../../renderer.zig");
const Health = rendererpkg.Health;
const FrameToken = rendererpkg.frame_lease.Token;
const FramePresentation = rendererpkg.FramePresentation;

const log = std.log.scoped(.metal);

/// Options for beginning a frame.
pub const Options = struct {
    /// MTLCommandQueue
    queue: objc.Object,

    /// Ref-counted renderer access gate for asynchronous completion.
    completion_lifetime: *Metal.RendererCompletionLifetime,

    /// Monotonic layer lifetime observed when this frame was submitted.
    presentation_generation: u64,
};

/// MTLCommandBuffer
buffer: objc.Object,

block: CompletionBlock.Context,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
    frame_token: FrameToken,
    host_context: u64,
    presentation: ?FramePresentation,
) !Self {
    const buffer = opts.queue.msgSend(
        objc.Object,
        objc.sel("commandBuffer"),
        .{},
    );

    // Create our block to register for completion updates.
    // The block is deallocated by the objC runtime on success.
    const block = CompletionBlock.init(
        .{
            .completion_lifetime = opts.completion_lifetime,
            .presentation_generation = opts.presentation_generation,
            .target = target,
            .sync = false,
            .frame_token = frame_token,
            .host_context = host_context,
            .presentation_callback = if (presentation) |value| value.callback else null,
            .presentation_userdata = if (presentation) |value| value.userdata else null,
            .presentation_token = if (presentation) |value| value.token else 0,
            .presentation_delivery_gate = if (presentation) |value| value.delivery_gate else null,
            .presentation_delivery_gate_userdata = if (presentation) |value| value.delivery_gate_userdata else null,
        },
        &bufferCompleted,
    );

    return .{ .buffer = buffer, .block = block };
}

/// This is the block type used for the addCompletedHandler callback.
const CompletionBlock = objc.Block(struct {
    completion_lifetime: *Metal.RendererCompletionLifetime,
    presentation_generation: u64,
    target: *Target,
    sync: bool,
    frame_token: FrameToken,
    host_context: u64,
    presentation_callback: ?*const fn (?*anyopaque, u64) callconv(.c) void,
    presentation_userdata: ?*anyopaque,
    presentation_token: u64,
    presentation_delivery_gate: ?*const fn (?*anyopaque) callconv(.c) void,
    presentation_delivery_gate_userdata: ?*anyopaque,
}, .{
    objc.c.id, // MTLCommandBuffer
}, void);

fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    // Asynchronous and iOS completions always queue tokened presentation.
    // Keep the fallback defensive so any future backend mode still consumes
    // the exact delivery ownership.
    if (bufferCompletedImpl(block, buffer_id)) |presentation| {
        presentation.deliver();
    }
}

fn bufferCompletedImpl(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) ?FramePresentation {
    // This reference was acquired immediately before the handler was armed.
    // It keeps only the gate alive, not renderer or target state.
    defer block.completion_lifetime.release();

    // Teardown invalidates this gate before freeing renderer-owned memory.
    var live = block.completion_lifetime.acquire() orelse return null;
    defer live.deinit();
    const renderer = live.context;

    const buffer = objc.Object.fromId(buffer_id);

    // Get our command buffer status to pass back to the generic renderer.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    const presentation = presentationFromBlock(block);
    if (health == .healthy) {
        return completeHealthyFrame(
            renderer,
            block.target,
            block.sync,
            block.frame_token,
            block.host_context,
            block.presentation_generation,
            presentation,
        );
    }

    renderer.frameCompleted(
        block.target,
        health,
        block.frame_token,
        false,
    );
    return null;
}

fn presentationFromBlock(
    block: *const CompletionBlock.Context,
) ?FramePresentation {
    return if (block.presentation_callback) |callback| .{
        .callback = callback,
        .userdata = block.presentation_userdata,
        .token = block.presentation_token,
        .delivery_gate = block.presentation_delivery_gate,
        .delivery_gate_userdata = block.presentation_delivery_gate_userdata,
    } else null;
}

/// Present one healthy completed frame and recycle its exact swap-chain slot.
/// Explicitly tokened frames queue a detached IOSurface so both assignment and
/// the external callback remain independent of later slot reuse or teardown.
fn completeHealthyFrame(
    renderer: anytype,
    target: anytype,
    sync: bool,
    frame_token: FrameToken,
    host_context: u64,
    presentation_generation: u64,
    presentation: ?FramePresentation,
) ?FramePresentation {
    if (presentation) |value| {
        // Only non-iOS synchronous completion enters this branch. Assignment
        // is validated while renderer state is live; delivery is transferred
        // to the generic caller so it occurs after `draw_mutex` unlocks.
        if (sync) {
            const completed = renderer.api.presentWithPresentation(
                target.*,
                presentation_generation,
                value,
            ) catch |err| failed: {
                log.err("Failed to present tokened render target: err={}", .{err});
                break :failed null;
            };
            renderer.frameCompleted(target, .healthy, frame_token, false);
            return completed;
        }

        var frozen = renderer.api.detachPresentationTarget(target) catch |err| {
            log.warn("Failed to detach tokened render target: err={}", .{err});
            renderer.frameCompleted(target, .healthy, frame_token, false);
            return null;
        };
        defer frozen.releasePresentationOwnership();

        // Prepare retains the layer, IOSurface, presentation lifetime, and
        // exact observed generation before the replacement slot is recycled.
        const prepared = renderer.api.preparePresentation(
            frozen,
            value,
            presentation_generation,
        );
        renderer.frameCompleted(target, .healthy, frame_token, false);
        prepared.dispatch();
        return null;
    }

    const host_acquired = renderer.api.present(
        renderer,
        target.*,
        sync,
        frame_token,
        host_context,
        presentation_generation,
    ) catch |err| failed: {
        log.err("Failed to present render target: err={}", .{err});
        break :failed false;
    };
    renderer.frameCompleted(
        target,
        .healthy,
        frame_token,
        host_acquired,
    );
    return null;
}

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .command_buffer = self.buffer,
    });
}

/// Complete this frame and present the target.
///
/// If `sync` is true, this will block until the frame is presented.
pub inline fn complete(self: *Self, sync: bool) ?FramePresentation {
    // cmux iOS fork: iOS has no renderer-thread vsync pump; `render_now`
    // produces frames synchronously on a single serial dispatch queue. A
    // blocking `waitUntilCompleted` here would park that queue forever if the
    // GPU present stalls during a foreground resize storm. Force async
    // completion on iOS so the queue thread returns right after `commit`; the
    // completion handler (bufferCompleted -> frameCompleted -> finishFrame)
    // still returns the exact swap-chain permit. Today the iOS `render_now` path
    // already passes sync=false, so this is a no-op for the current build and
    // unchanged for macOS (use_sync == sync); it is a structural guarantee that
    // no future sync=true path can reintroduce the freeze on iOS. `use_sync` is
    // the SINGLE source of truth for both branches so exactly one completion
    // path runs per committed buffer (net-zero swap-chain permit balance).
    const use_sync = sync and builtin.os.tag != .ios;

    // The ObjC block copy retains Objective-C captures but not this raw Zig
    // pointer. Give every armed completion one explicit lifetime reference.
    self.block.completion_lifetime.retain();

    // If we don't complete synchronously, add our block as a completion
    // handler. It is copied when added and freed by the objc runtime.
    if (!use_sync) {
        self.buffer.msgSend(
            void,
            objc.sel("addCompletedHandler:"),
            .{&self.block},
        );
    }

    self.buffer.msgSend(void, objc.sel("commit"), .{});

    // If we need to complete synchronously, wait until the buffer is completed
    // and invoke the block directly.
    if (use_sync) {
        self.buffer.msgSend(void, "waitUntilCompleted", .{});
        self.block.sync = true;
        return bufferCompletedImpl(&self.block, self.buffer.value);
    }

    // Metal owns asynchronous presentation delivery through its completion
    // handler and main-queue layer block.
    return null;
}

test "tokened completion freezes target before recycling slot" {
    const testing = std.testing;
    const EventKind = enum {
        detach,
        prepare,
        present,
        complete,
        dispatch,
        deinit,
        release_presentation_ownership,
    };
    const Event = struct {
        kind: EventKind,
        target_id: u8,
    };
    const State = struct {
        events: [8]Event = undefined,
        len: usize = 0,
        fail_detach: bool = false,

        fn append(self: *@This(), kind: EventKind, target_id: u8) void {
            self.events[self.len] = .{ .kind = kind, .target_id = target_id };
            self.len += 1;
        }
    };
    const MockTarget = struct {
        id: u8,
        state: *State,

        fn deinit(self: *@This()) void {
            self.state.append(.deinit, self.id);
        }

        fn releasePresentationOwnership(self: *@This()) void {
            self.state.append(.release_presentation_ownership, self.id);
        }
    };
    const Prepared = struct {
        target_id: u8,
        state: *State,

        fn dispatch(self: @This()) void {
            self.state.append(.dispatch, self.target_id);
        }
    };
    const MockAPI = struct {
        state: *State,

        fn detachPresentationTarget(
            self: *@This(),
            target: *MockTarget,
        ) !MockTarget {
            if (self.state.fail_detach) return error.OutOfMemory;
            self.state.append(.detach, target.id);
            const frozen = target.*;
            target.id += 1;
            return frozen;
        }

        fn preparePresentation(
            self: *@This(),
            target: MockTarget,
            _: FramePresentation,
            _: u64,
        ) Prepared {
            self.state.append(.prepare, target.id);
            return .{ .target_id = target.id, .state = self.state };
        }

        fn present(
            self: *@This(),
            _: anytype,
            target: MockTarget,
            _: bool,
            _: FrameToken,
            _: u64,
            _: u64,
        ) !bool {
            self.state.append(.present, target.id);
            return false;
        }

        fn presentWithPresentation(
            self: *@This(),
            target: MockTarget,
            _: u64,
            presentation: FramePresentation,
        ) !?FramePresentation {
            self.state.append(.present, target.id);
            return presentation;
        }
    };
    const MockRenderer = struct {
        api: MockAPI,

        fn frameCompleted(
            self: *@This(),
            target: *MockTarget,
            health: Health,
            _: FrameToken,
            _: bool,
        ) void {
            std.debug.assert(health == .healthy);
            self.api.state.append(.complete, target.id);
            // Model immediate swap-chain reuse. The prepared update must keep
            // observing the detached target instead of this mutation.
            target.id += 10;
        }
    };
    const Callbacks = struct {
        fn presented(_: ?*anyopaque, _: u64) callconv(.c) void {}
    };
    const presentation: FramePresentation = .{
        .callback = &Callbacks.presented,
        .userdata = null,
        .token = 42,
    };

    var state: State = .{};
    var renderer: MockRenderer = .{ .api = .{ .state = &state } };
    var target: MockTarget = .{ .id = 1, .state = &state };
    _ = completeHealthyFrame(&renderer, &target, false, 1, 0, 7, presentation);
    try testing.expectEqualSlices(Event, &.{
        .{ .kind = .detach, .target_id = 1 },
        .{ .kind = .prepare, .target_id = 1 },
        .{ .kind = .complete, .target_id = 2 },
        .{ .kind = .dispatch, .target_id = 1 },
        .{ .kind = .release_presentation_ownership, .target_id = 1 },
    }, state.events[0..state.len]);

    // Replacement failure emits no token and still recycles the original
    // frame exactly once.
    state = .{ .fail_detach = true };
    renderer.api.state = &state;
    target = .{ .id = 4, .state = &state };
    _ = completeHealthyFrame(&renderer, &target, false, 2, 0, 7, presentation);
    try testing.expectEqualSlices(Event, &.{
        .{ .kind = .complete, .target_id = 4 },
    }, state.events[0..state.len]);

    // Ordinary frames retain the allocation-free presentation path.
    state = .{};
    renderer.api.state = &state;
    target = .{ .id = 7, .state = &state };
    _ = completeHealthyFrame(&renderer, &target, false, 3, 0, 7, null);
    try testing.expectEqualSlices(Event, &.{
        .{ .kind = .present, .target_id = 7 },
        .{ .kind = .complete, .target_id = 7 },
    }, state.events[0..state.len]);
}

test "late Metal completion cannot enter invalidated renderer lifetime" {
    const TestContext = struct {
        touched: bool = false,
    };
    const TestLifetime = @import("CompletionLifetime.zig").Lifetime(TestContext);

    var context: TestContext = .{};
    const lifetime = try TestLifetime.create(std.testing.allocator);
    lifetime.bind(&context);

    // Model independent completion ownership after the renderer generation
    // invalidates and releases its own reference.
    lifetime.retain();
    lifetime.invalidate();
    lifetime.release();

    try std.testing.expect(lifetime.acquire() == null);
    try std.testing.expect(!context.touched);
    lifetime.release();
}
