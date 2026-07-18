const std = @import("std");
const terminal = @import("../terminal/main.zig");

/// Search results shared by the renderer mailbox and renderer state.
///
/// These live outside `renderer.Message` so the semantic-scene renderer can
/// use the render state without instantiating the renderer thread or app
/// mailbox dependency graph.
pub const Matches = struct {
    arena: std.heap.ArenaAllocator,
    matches: []const terminal.highlight.Flattened,
};

pub const Match = struct {
    arena: std.heap.ArenaAllocator,
    match: terminal.highlight.Flattened,
};
