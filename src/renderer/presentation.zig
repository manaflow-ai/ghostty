//! Exact render-presentation completion reported to embedded runtimes.

/// Final disposition for an exact render ticket. Only `presented` means the
/// frame reached the host layer.
pub const Status = enum(c_int) {
    /// The host layer accepted the rendered frame.
    presented = 0,

    /// Stale geometry caused the frame to be discarded before presentation.
    wrong_size_discarded = 1,

    /// The renderer backend failed before presentation.
    backend_failed = 2,
};

/// Reports one final disposition for a render ticket supplied by the embedder.
pub const Callback = *const fn (
    ?*anyopaque,
    u64,
    Status,
) callconv(.c) void;
