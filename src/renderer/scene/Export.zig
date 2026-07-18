//! Process-independent provenance for IOSurface frames exported by a
//! renderer-only Ghostty instance.

const Model = @import("Model.zig");

/// The semantic scene revision that a rendered frame represents. Every field
/// is part of the release fence. Sequences are non-zero and never wrap.
pub const FrameMetadata = struct {
    renderer_epoch: u64,
    terminal_id: Model.TerminalIdentity,
    terminal_epoch: u64,
    content_sequence: u64,
    presentation_id: Model.PresentationIdentity,
    presentation_generation: u64,
    presentation_sequence: u64,
    frame_sequence: u64,
};

/// A GPU-complete frame whose IOSurface slot remains immutable until the host
/// returns this exact lease.
pub const FrameLease = struct {
    metadata: FrameMetadata,
    iosurface_id: u32,
    width: u32,
    height: u32,
};

pub const Event = union(enum) {
    frame_ready: FrameLease,
    renderer_health: Health,
};

pub const Health = enum { healthy, unhealthy };

/// Event delivery runs on the renderer's calling or Metal completion thread.
/// The callback must be thread-safe and must not block.
pub const EventSink = struct {
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque, Event) void,

    pub fn send(self: EventSink, event: Event) void {
        self.callback(self.context, event);
    }
};
