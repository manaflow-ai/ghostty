//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const objc = @import("objc");

const mtl = @import("api.zig");
const Renderer = @import("../generic.zig").Renderer(Metal);
const Metal = @import("../Metal.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.metal);

/// Options for beginning a frame.
pub const Options = struct {
    /// MTLCommandQueue
    queue: objc.Object,
    presentation_ticket: ?u64,
};

/// MTLCommandBuffer
buffer: objc.Object,

block: CompletionBlock.Context,

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
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
            .renderer = renderer,
            .target = target,
            .sync = false,
            .presentation_ticket = opts.presentation_ticket orelse 0,
            .has_presentation_ticket = opts.presentation_ticket != null,
        },
        &bufferCompleted,
    );

    return .{ .buffer = buffer, .block = block };
}

/// This is the block type used for the addCompletedHandler callback.
const CompletionBlock = objc.Block(struct {
    renderer: *Renderer,
    target: *Target,
    sync: bool,
    presentation_ticket: u64,
    has_presentation_ticket: bool,
}, .{
    objc.c.id, // MTLCommandBuffer
}, void);

fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const buffer = objc.Object.fromId(buffer_id);

    // Get our command buffer status to pass back to the generic renderer.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    // If the frame is healthy, present it.
    if (health == .healthy) {
        block.renderer.api.present(
            block.target.*,
            block.sync,
            if (block.has_presentation_ticket)
                block.presentation_ticket
            else
                null,
        ) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
            if (block.has_presentation_ticket) {
                block.renderer.api.completePresentation(
                    block.presentation_ticket,
                    .backend_failed,
                );
            }
        };
    } else if (block.has_presentation_ticket) {
        block.renderer.api.completePresentation(
            block.presentation_ticket,
            .backend_failed,
        );
    }

    block.renderer.frameCompleted(health);
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
pub inline fn complete(self: *Self, sync: bool) void {
    // cmux iOS fork: iOS has no renderer-thread vsync pump; `render_now`
    // produces frames synchronously on a single serial dispatch queue. A
    // blocking `waitUntilCompleted` here would park that queue forever if the
    // GPU present stalls during a foreground resize storm. Force async
    // completion on iOS so the queue thread returns right after `commit`; the
    // completion handler (bufferCompleted -> frameCompleted -> releaseFrame)
    // still reposts the frame_sema permit. Today the iOS `render_now` path
    // already passes sync=false, so this is a no-op for the current build and
    // unchanged for macOS (use_sync == sync); it is a structural guarantee that
    // no future sync=true path can reintroduce the freeze on iOS. `use_sync` is
    // the SINGLE source of truth for both branches so exactly one completion
    // path runs per committed buffer (net-zero frame_sema balance).
    const use_sync = sync and builtin.os.tag != .ios;

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
        CompletionBlock.invoke(&self.block, .{self.buffer.value});
    }
}
