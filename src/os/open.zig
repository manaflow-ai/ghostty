const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
///
/// This function is purposely simple for the sake of providing some portable
/// way to open URLs. If you are implementing an apprt for Ghostty, you should
/// consider doing something special-cased for your platform.
pub fn open(
    kind: apprt.action.OpenUrl.Kind,
    url: []const u8,
) !void {
    var spawn_opts: std.process.SpawnOptions = switch (builtin.os.tag) {
        .linux, .freebsd => .{ .argv = &.{ "xdg-open", url } },
        .windows => .{ .argv = &.{ "rundll32", "url.dll,FileProtocolHandler", url } },
        .macos => switch (kind) {
            .text => .{ .argv = &.{ "open", "-t", url } },
            .html, .unknown => .{ .argv = &.{ "open", url } },
        },
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };
    // Ignore anything from stdout. This must be set before spawning the
    // process.
    spawn_opts.stdout = .ignore;
    // Pipe stderr so we can log the stderr from the command. This must be set
    // before spawning the process.
    spawn_opts.stderr = .pipe;

    const exe = if (comptime build_config.snap) local_env: {
        // In the snap on Linux the launcher exports LD_LIBRARY_PATH
        // pointing at the snap's bundled libraries. Leaking this into
        // child process can can be problematic, so let's drop it from the
        // env.
        //
        // Note that `spawn` copies the passed in `Environ.Map` into a
        // fresh `Environ` block, so this is safe to release immediately
        // after spawn.
        var environ_map = try global.environMap();
        defer environ_map.deinit();
        _ = environ_map.orderedRemove("LD_LIBRARY_PATH");
        spawn_opts.environ_map = &environ_map;
        break :local_env try std.process.spawn(global.io(), spawn_opts);
    } else
        // Non-snap releases don't need to alter the env.
        try std.process.spawn(global.io(), spawn_opts);

    const thread = try std.Thread.spawn(.{}, openThread, .{ global.io(), exe });
    thread.detach();
}

/// Maximum stderr lines reported for a single `open`. A failing `open` says
/// what went wrong in a line or two; anything past this is a malfunctioning
/// child, and logging it at full speed throttles the whole process's unified
/// logging firehose (`__FIREHOSE_CLIENT_THROTTLED_DUE_TO_HEAVY_LOGGING__`),
/// which makes every other os_log call in the process expensive.
const max_open_stderr_lines = 32;

fn openThread(io: std.Io, exe_: std.process.Child) void {
    // Copy the exe so it is non-const. This is necessary because wait()
    // requires a mutable reference and we can't have one as a thread
    // param.
    var exe = exe_;
    // Always reap the child. Previously `wait()` was only reachable by falling
    // out of the drain loop below, so a loop that never terminated leaked this
    // thread AND left the child as a zombie forever.
    defer _ = exe.wait(io) catch {};

    const stderr = exe.stderr orelse return;
    var buffer: [256]u8 = undefined;
    var stream = stderr.readerStreaming(io, &buffer);
    const reader = &stream.interface;

    _ = drainStderr(reader);
}

/// Drain `reader` to end-of-stream, reporting at most `max_open_stderr_lines`
/// lines. Returns how many were reported.
///
/// Split out from `openThread` so the property that actually matters -- this
/// loop consumes its input and terminates -- can be tested without spawning a
/// child process.
fn drainStderr(reader: *std.Io.Reader) usize {
    var logged: usize = 0;
    while (true) {
        // `takeDelimiter` consumes the delimiter and reports end-of-stream as
        // null. `takeDelimiterExclusive` (used here previously) advances only up
        // to the delimiter, so once the seek position sits on a '\n' it returns
        // a zero-length slice forever without progressing and without erroring.
        // That made this loop spin at 100% CPU after the very first stderr line,
        // emitting empty `open stderr=` records until macOS throttled the
        // process-wide logging firehose, and it never reached `wait()`.
        const line = (reader.takeDelimiter('\n') catch |outer| switch (outer) {
            error.ReadFailed => break,
            error.StreamTooLong => reader.take(reader.buffer.len) catch break,
        }) orelse break;

        // Keep draining after the cap so a child blocked writing into a full
        // pipe can still finish and exit; only the reporting is capped.
        if (logged < max_open_stderr_lines) {
            logged += 1;
            log.warn("open stderr={s}", .{line});
            if (logged == max_open_stderr_lines) {
                log.warn("open stderr truncated after {d} lines", .{logged});
            }
        }
    }
    return logged;
}

test "drainStderr reports every line and terminates" {
    var r: std.Io.Reader = .fixed("first\nsecond\nthird\n");
    try std.testing.expectEqual(@as(usize, 3), drainStderr(&r));
}

test "drainStderr terminates on blank lines" {
    // The old `takeDelimiterExclusive` loop spun forever here: the seek position
    // parks on the delimiter and every subsequent read returns an empty slice.
    var r: std.Io.Reader = .fixed("\n\n\n");
    try std.testing.expectEqual(@as(usize, 3), drainStderr(&r));
}

test "drainStderr reports a final line with no trailing newline" {
    var r: std.Io.Reader = .fixed("only");
    try std.testing.expectEqual(@as(usize, 1), drainStderr(&r));
}

test "drainStderr caps reporting but still drains to end of stream" {
    const line_count = max_open_stderr_lines + 8;
    var buf: [line_count * 2]u8 = undefined;
    for (0..line_count) |i| {
        buf[i * 2] = 'x';
        buf[i * 2 + 1] = '\n';
    }
    var r: std.Io.Reader = .fixed(&buf);
    try std.testing.expectEqual(@as(usize, max_open_stderr_lines), drainStderr(&r));
    // Draining must continue past the reporting cap, otherwise a child blocked
    // writing into a full pipe can never exit and `wait()` parks forever.
    try std.testing.expectEqual(@as(usize, 0), r.end - r.seek);
}
