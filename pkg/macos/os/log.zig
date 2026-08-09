const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub const Log = opaque {
    pub fn create(
        subsystem: [:0]const u8,
        category: [:0]const u8,
    ) *Log {
        return @ptrCast(c.os_log_create(
            subsystem.ptr,
            category.ptr,
        ).?);
    }

    pub fn release(self: *Log) void {
        c.os_release(self);
    }

    pub fn typeEnabled(self: *Log, typ: LogType) bool {
        return c.os_log_type_enabled(
            @ptrCast(self),
            @intFromEnum(typ),
        );
    }

    pub fn log(
        self: *Log,
        alloc: Allocator,
        typ: LogType,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (!self.typeEnabled(typ)) return;

        const str = nosuspend std.fmt.allocPrintSentinel(
            alloc,
            format,
            args,
            0,
        ) catch return;
        defer alloc.free(str);
        zig_os_log_with_type(self, typ, str.ptr);
    }

    extern "c" fn zig_os_log_with_type(*Log, LogType, [*c]const u8) void;
};

/// Returns a process-lifetime logger for a compile-time subsystem and category.
/// The first caller initializes it; subsequent calls only take dispatch_once's
/// already-complete fast path. Unified log handles are safe to share between
/// threads.
pub fn ScopedLog(
    comptime subsystem: [:0]const u8,
    comptime category: [:0]const u8,
) type {
    const Init = struct {
        fn create() *Log {
            return Log.create(subsystem, category);
        }
    };

    return Lazy(*Log, Init.create);
}

fn Lazy(comptime T: type, comptime initializer: fn () T) type {
    return struct {
        var once: c.dispatch_once_t = 0;
        var value: ?T = null;

        pub fn get() T {
            c.dispatch_once_f(&once, null, initialize);
            return value.?;
        }

        fn initialize(_: ?*anyopaque) callconv(.c) void {
            value = initializer();
        }
    };
}

/// https://developer.apple.com/documentation/os/os_log_type_t?language=objc
pub const LogType = enum(c.os_log_type_t) {
    default = c.OS_LOG_TYPE_DEFAULT,
    debug = c.OS_LOG_TYPE_DEBUG,
    info = c.OS_LOG_TYPE_INFO,
    err = c.OS_LOG_TYPE_ERROR,
    fault = c.OS_LOG_TYPE_FAULT,
};

test {
    const testing = std.testing;

    const log = Log.create("com.mitchellh.ghostty", "test");
    defer log.release();

    try testing.expect(log.typeEnabled(.fault));
    log.log(testing.allocator, .default, "hello {d}", .{12});
}

test "disabled log skips formatting" {
    const testing = std.testing;

    const FormattingProbe = struct {
        formatted: *bool,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            self.formatted.* = true;
            try writer.writeAll("formatted");
        }
    };

    var formatted = false;
    const disabled: *Log = @ptrCast(&c._os_log_disabled);
    try testing.expect(!disabled.typeEnabled(.debug));

    disabled.log(
        testing.allocator,
        .debug,
        "{f}",
        .{FormattingProbe{ .formatted = &formatted }},
    );
    try testing.expect(!formatted);
}

test "scoped log cache initializes once" {
    const testing = std.testing;

    const Counter = struct {
        var calls: usize = 0;

        fn initialize() usize {
            calls += 1;
            return calls;
        }
    };

    const cache = Lazy(usize, Counter.initialize);
    try testing.expectEqual(@as(usize, 1), cache.get());
    try testing.expectEqual(@as(usize, 1), cache.get());
    try testing.expectEqual(@as(usize, 1), Counter.calls);
}
