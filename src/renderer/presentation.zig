//! Exact render-presentation completion reported to embedded runtimes.

/// The terminal frame reached the host layer, was discarded because its
/// geometry was stale, or could not reach the presentation boundary.
pub const Status = enum(c_int) {
    presented = 0,
    wrong_size_discarded = 1,
    backend_failed = 2,
};

/// Completion for a render ticket supplied by the embedder.
pub const Callback = *const fn (
    ?*anyopaque,
    u64,
    Status,
) callconv(.c) void;
