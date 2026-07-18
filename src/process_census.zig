//! Process-lifetime census for externally observable terminal ownership.
//!
//! These counters are monotonic by design. They count constructor attempts and
//! successful PTY-master allocations for the lifetime of the process, rather
//! than live objects, so destroying a surface cannot erase evidence that the
//! process once owned canonical terminal state or a PTY.

const std = @import("std");
const builtin = @import("builtin");

pub const schema_version: u32 = 1;

pub const Snapshot = extern struct {
    schema_version: u32,
    reserved: u32 = 0,
    surface_constructor_attempts: u64,
    manual_io_surface_constructor_attempts: u64,
    embedded_pty_surface_constructor_attempts: u64,
    pty_master_open_attempts: u64,
    pty_master_allocations: u64,
};

const Counters = struct {
    surface_constructor_attempts: std.atomic.Value(u64) = .init(0),
    manual_io_surface_constructor_attempts: std.atomic.Value(u64) = .init(0),
    embedded_pty_surface_constructor_attempts: std.atomic.Value(u64) = .init(0),
    pty_master_open_attempts: std.atomic.Value(u64) = .init(0),
    pty_master_allocations: std.atomic.Value(u64) = .init(0),

    fn recordSurfaceConstructor(self: *Counters, manual_io: bool) void {
        increment(&self.surface_constructor_attempts);
        if (manual_io) {
            increment(&self.manual_io_surface_constructor_attempts);
        } else {
            increment(&self.embedded_pty_surface_constructor_attempts);
        }
    }

    fn recordPtyMasterOpenAttempt(self: *Counters) void {
        increment(&self.pty_master_open_attempts);
    }

    fn recordPtyMasterAllocation(self: *Counters) void {
        increment(&self.pty_master_allocations);
    }

    fn snapshot(self: *const Counters) Snapshot {
        return .{
            .schema_version = schema_version,
            .surface_constructor_attempts = self.surface_constructor_attempts.load(.acquire),
            .manual_io_surface_constructor_attempts = self.manual_io_surface_constructor_attempts.load(.acquire),
            .embedded_pty_surface_constructor_attempts = self.embedded_pty_surface_constructor_attempts.load(.acquire),
            .pty_master_open_attempts = self.pty_master_open_attempts.load(.acquire),
            .pty_master_allocations = self.pty_master_allocations.load(.acquire),
        };
    }
};

fn increment(value: *std.atomic.Value(u64)) void {
    var current = value.load(.monotonic);
    while (current != std.math.maxInt(u64)) {
        if (value.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
        } else return;
    }
}

var counters: Counters = .{};

pub fn recordSurfaceConstructor(manual_io: bool) void {
    counters.recordSurfaceConstructor(manual_io);
    emitEvent("ghostty-canonical-surface-constructor");
    if (manual_io) {
        emitEvent("ghostty-manual-io-surface-constructor");
    } else {
        emitEvent("ghostty-embedded-pty-surface-constructor");
    }
}

pub fn recordPtyMasterOpenAttempt() void {
    counters.recordPtyMasterOpenAttempt();
    emitEvent("ghostty-pty-master-open-attempt");
}

pub fn recordPtyMasterAllocation() void {
    counters.recordPtyMasterAllocation();
    emitEvent("ghostty-pty-master-allocated");
}

pub fn snapshot() Snapshot {
    return counters.snapshot();
}

/// Emit a bounded, self-describing signpost snapshot and return the same
/// process-lifetime values to the caller. Each unit marker represents exactly
/// one monotonic counter unit. The verifier rejects the overflow marker, so a
/// passing trace can never silently truncate a large count.
pub fn emitSignpostSnapshot() Snapshot {
    const result = snapshot();
    if (comptime builtin.target.os.tag.isDarwin()) {
        const macos = @import("macos");
        ensureSignpostInitialized();
        const log = macos.os.Log.create(
            "com.cmux.ghostty.process-census",
            macos.os.signpost.Category.dynamic_stack_tracing,
        );
        defer log.release();

        const id = macos.os.signpost.Id.generate(log);
        macos.os.signpost.intervalBegin(log, id, "ghostty-process-census-snapshot");
        defer macos.os.signpost.intervalEnd(log, id, "ghostty-process-census-snapshot");
        macos.os.signpost.emitEvent(log, id, "ghostty-process-census-schema-v1");

        const maximum_units: u64 = 100_000;
        const total_units = result.surface_constructor_attempts +|
            result.manual_io_surface_constructor_attempts +|
            result.embedded_pty_surface_constructor_attempts +|
            result.pty_master_open_attempts +|
            result.pty_master_allocations;
        if (total_units > maximum_units) {
            macos.os.signpost.emitEvent(log, id, "ghostty-process-census-snapshot-overflow");
            return result;
        }

        emitUnits(
            macos,
            log,
            id,
            "ghostty-snapshot-canonical-surface-constructor",
            result.surface_constructor_attempts,
        );
        emitUnits(
            macos,
            log,
            id,
            "ghostty-snapshot-manual-io-surface-constructor",
            result.manual_io_surface_constructor_attempts,
        );
        emitUnits(
            macos,
            log,
            id,
            "ghostty-snapshot-embedded-pty-surface-constructor",
            result.embedded_pty_surface_constructor_attempts,
        );
        emitUnits(
            macos,
            log,
            id,
            "ghostty-snapshot-pty-master-open-attempt",
            result.pty_master_open_attempts,
        );
        emitUnits(
            macos,
            log,
            id,
            "ghostty-snapshot-pty-master-allocation",
            result.pty_master_allocations,
        );
    }
    return result;
}

fn emitUnits(
    comptime macos: type,
    log: *macos.os.Log,
    id: macos.os.signpost.Id,
    comptime name: [:0]const u8,
    count: u64,
) void {
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        macos.os.signpost.emitEvent(log, id, name);
    }
}

var signpost_init_mutex: std.Thread.Mutex = .{};
var signpost_initialized = false;

fn ensureSignpostInitialized() void {
    if (comptime !builtin.target.os.tag.isDarwin()) return;
    signpost_init_mutex.lock();
    defer signpost_init_mutex.unlock();
    if (signpost_initialized) return;
    @import("macos").os.signpost.init();
    signpost_initialized = true;
}

fn emitEvent(comptime name: [:0]const u8) void {
    if (comptime builtin.target.os.tag.isDarwin()) {
        const macos = @import("macos");
        ensureSignpostInitialized();
        const log = macos.os.Log.create(
            "com.cmux.ghostty.process-census",
            macos.os.signpost.Category.dynamic_stack_tracing,
        );
        defer log.release();
        macos.os.signpost.emitEvent(log, .exclusive, name);
    }
}

test "census remains monotonic and distinguishes surface IO ownership" {
    var local: Counters = .{};
    local.recordSurfaceConstructor(true);
    local.recordSurfaceConstructor(false);
    local.recordPtyMasterOpenAttempt();
    local.recordPtyMasterAllocation();

    const first = local.snapshot();
    try std.testing.expectEqual(schema_version, first.schema_version);
    try std.testing.expectEqual(@as(u64, 2), first.surface_constructor_attempts);
    try std.testing.expectEqual(@as(u64, 1), first.manual_io_surface_constructor_attempts);
    try std.testing.expectEqual(@as(u64, 1), first.embedded_pty_surface_constructor_attempts);
    try std.testing.expectEqual(@as(u64, 1), first.pty_master_open_attempts);
    try std.testing.expectEqual(@as(u64, 1), first.pty_master_allocations);

    local.recordSurfaceConstructor(true);
    const second = local.snapshot();
    try std.testing.expect(second.surface_constructor_attempts >= first.surface_constructor_attempts);
    try std.testing.expect(second.manual_io_surface_constructor_attempts >= first.manual_io_surface_constructor_attempts);
    try std.testing.expect(second.pty_master_allocations >= first.pty_master_allocations);

    local.pty_master_allocations.store(std.math.maxInt(u64), .release);
    local.recordPtyMasterAllocation();
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        local.snapshot().pty_master_allocations,
    );
}
