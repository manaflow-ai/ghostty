//! Owns POSIX environment snapshots for the lifetime of their consumers.
//! Retaining earlier captures also keeps previously returned Environ views valid.
const EnvironSnapshots = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

arena: std.heap.ArenaAllocator,

pub fn init(allocator: Allocator) EnvironSnapshots {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *EnvironSnapshots) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Copies both the pointer vector and its strings. The caller must ensure the
/// source is stable during capture; subsequent libc mutations cannot alter it.
/// Non-POSIX environments retain their existing global-query semantics.
pub fn capture(self: *EnvironSnapshots, source: Environ) Allocator.Error!Environ {
    if (comptime Environ.Block != Environ.PosixBlock) return source;

    const allocator = self.arena.allocator();
    const entries = try allocator.allocSentinel(?[*:0]const u8, source.block.slice.len, null);
    for (source.block.slice, 0..) |entry, i| {
        entries[i] = try allocator.dupeZ(u8, std.mem.span(entry.?));
    }
    return .{ .block = .{ .slice = entries } };
}

test "environment snapshot owns strings and pointer vector" {
    if (comptime Environ.Block != Environ.PosixBlock) return error.SkipZigTest;
    var snapshots: EnvironSnapshots = .init(std.testing.allocator);
    defer snapshots.deinit();
    var entry: [11:0]u8 = "NAME=before".*;
    var entries = [_:null]?[*:0]const u8{&entry};
    const captured = try snapshots.capture(.{ .block = .{ .slice = &entries } });

    @memcpy(entry[5..11], "after!");
    entries[0] = "OTHER=value";
    try std.testing.expectEqualStrings("before", captured.getPosix("NAME").?);
    try std.testing.expect(captured.getPosix("OTHER") == null);
}

test "environment refresh retains older snapshots" {
    if (comptime Environ.Block != Environ.PosixBlock) return error.SkipZigTest;
    var snapshots: EnvironSnapshots = .init(std.testing.allocator);
    defer snapshots.deinit();
    var entries = [_:null]?[*:0]const u8{"NAME=before"};
    const first = try snapshots.capture(.{ .block = .{ .slice = &entries } });
    entries[0] = "NAME=after";
    const second = try snapshots.capture(.{ .block = .{ .slice = &entries } });
    try std.testing.expectEqualStrings("before", first.getPosix("NAME").?);
    try std.testing.expectEqualStrings("after", second.getPosix("NAME").?);
}

test "empty environment snapshot" {
    if (comptime Environ.Block != Environ.PosixBlock) return error.SkipZigTest;
    var snapshots: EnvironSnapshots = .init(std.testing.allocator);
    defer snapshots.deinit();
    const entries = [_:null]?[*:0]const u8{};
    const captured = try snapshots.capture(.{ .block = .{ .slice = &entries } });
    try std.testing.expectEqual(@as(usize, 0), captured.block.slice.len);
    try std.testing.expect(captured.block.slice.ptr[0] == null);
    try std.testing.expect(captured.getPosix("NAME") == null);
}

test "allocation failure preserves existing environment snapshots" {
    if (comptime Environ.Block != Environ.PosixBlock) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: Allocator) !void {
            var snapshots: EnvironSnapshots = .init(allocator);
            defer snapshots.deinit();
            const original = [_:null]?[*:0]const u8{"NAME=before"};
            const first = try snapshots.capture(.{ .block = .{ .slice = &original } });
            const replacement = [_:null]?[*:0]const u8{ "NAME=after", "LARGE=" ++ "x" ** 4096 };
            _ = snapshots.capture(.{ .block = .{ .slice = &replacement } }) catch |err| {
                try std.testing.expectEqualStrings("before", first.getPosix("NAME").?);
                return err;
            };
            try std.testing.expectEqualStrings("before", first.getPosix("NAME").?);
        }
    }.check, .{});
}
