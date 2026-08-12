//! Kitty desktop notification protocol (OSC 99).
//! Specification: https://sw.kovidgoyal.net/kitty/desktop-notifications/

const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const encoding = @import("../encoding.zig");

const log = std.log.scoped(.kitty_notification);

const anonymous_id = "\x00";
const default_title: [:0]const u8 = "cmux";
const max_pending_notifications = 64;
const max_notification_id_bytes = 64;
const max_notification_bytes = 64 * 1024;

pub const NotificationStore = struct {
    map: std.StringHashMapUnmanaged(Pending) = .{},
    completed: ?Pending = null,
    next_sequence: u64 = 0,

    const Part = struct {
        decoded: std.ArrayListUnmanaged(u8) = .empty,
        encoded: std.ArrayListUnmanaged(u8) = .empty,

        fn deinit(self: *Part, alloc: std.mem.Allocator) void {
            self.decoded.deinit(alloc);
            self.encoded.deinit(alloc);
            self.* = .{};
        }

        fn storedBytes(self: *const Part) usize {
            return self.decoded.items.len + self.encoded.items.len;
        }

        fn appendChunk(
            self: *Part,
            alloc: std.mem.Allocator,
            payload: []const u8,
            encoded: bool,
        ) !void {
            if (!encoded) {
                try self.flushBase64(alloc, false);
                try self.decoded.appendSlice(alloc, payload);
                return;
            }

            try self.encoded.appendSlice(alloc, payload);
            if (std.mem.endsWith(u8, payload, "=")) {
                try self.flushBase64(alloc, true);
            }
        }

        fn flushBase64(
            self: *Part,
            alloc: std.mem.Allocator,
            padded: bool,
        ) !void {
            if (self.encoded.items.len == 0) return;

            const decoder = if (padded)
                std.base64.standard.Decoder
            else
                std.base64.standard_no_pad.Decoder;
            const decoded_len = decoder.calcSizeForSlice(self.encoded.items) catch
                return error.InvalidBase64;
            const previous_len = self.decoded.items.len;
            try self.decoded.resize(alloc, previous_len + decoded_len);
            decoder.decode(
                self.decoded.items[previous_len..],
                self.encoded.items,
            ) catch {
                self.decoded.shrinkRetainingCapacity(previous_len);
                return error.InvalidBase64;
            };
            self.encoded.clearRetainingCapacity();
        }

        fn finish(self: *Part, alloc: std.mem.Allocator) !void {
            try self.flushBase64(alloc, false);
            if (!encoding.isSafeUtf8(self.decoded.items)) return error.UnsafeText;
            try self.decoded.append(alloc, 0);
        }

        fn sentinel(self: *const Part) [:0]const u8 {
            return self.decoded.items[0 .. self.decoded.items.len - 1 :0];
        }
    };

    const Pending = struct {
        title: Part = .{},
        body: Part = .{},
        sequence: u64,

        fn deinit(self: *Pending, alloc: std.mem.Allocator) void {
            self.title.deinit(alloc);
            self.body.deinit(alloc);
        }

        fn storedBytes(self: *const Pending) usize {
            return self.title.storedBytes() + self.body.storedBytes();
        }
    };

    const PartKind = enum { title, body };

    pub fn deinit(self: *NotificationStore, alloc_: ?std.mem.Allocator) void {
        const alloc = alloc_ orelse return;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            entry.value_ptr.deinit(alloc);
        }
        self.map.deinit(alloc);
        self.clearCompleted(alloc_);
        self.* = .{};
    }

    pub fn clearCompleted(
        self: *NotificationStore,
        alloc_: ?std.mem.Allocator,
    ) void {
        const alloc = alloc_ orelse return;
        if (self.completed) |*completed| completed.deinit(alloc);
        self.completed = null;
    }

    fn append(
        self: *NotificationStore,
        alloc: std.mem.Allocator,
        id: []const u8,
        kind: PartKind,
        payload: []const u8,
        encoded: bool,
    ) !void {
        const pending = try self.getOrCreate(alloc, id);
        if (pending.storedBytes() + payload.len > max_notification_bytes) {
            return error.NotificationTooLarge;
        }

        switch (kind) {
            .title => try pending.title.appendChunk(alloc, payload, encoded),
            .body => try pending.body.appendChunk(alloc, payload, encoded),
        }
    }

    fn getOrCreate(
        self: *NotificationStore,
        alloc: std.mem.Allocator,
        id: []const u8,
    ) !*Pending {
        if (self.map.getPtr(id)) |pending| return pending;
        if (self.map.count() >= max_pending_notifications) {
            self.removeOldest(alloc);
        }

        const gop = try self.map.getOrPut(alloc, id);
        const inserted_new = !gop.found_existing;
        errdefer {
            if (inserted_new) _ = self.map.remove(id);
        }

        const key = try alloc.dupe(u8, id);
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{ .sequence = self.next_sequence };
        self.next_sequence +%= 1;
        return gop.value_ptr;
    }

    fn removeOldest(self: *NotificationStore, alloc: std.mem.Allocator) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_sequence: u64 = std.math.maxInt(u64);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.sequence < oldest_sequence) {
                oldest_key = entry.key_ptr.*;
                oldest_sequence = entry.value_ptr.sequence;
            }
        }

        const key = oldest_key orelse return;
        const removed = self.map.fetchRemove(key).?;
        alloc.free(removed.key);
        var pending = removed.value;
        pending.deinit(alloc);
    }

    fn discard(
        self: *NotificationStore,
        alloc: std.mem.Allocator,
        id: []const u8,
    ) void {
        const removed = self.map.fetchRemove(id) orelse return;
        alloc.free(removed.key);
        var pending = removed.value;
        pending.deinit(alloc);
    }

    fn complete(
        self: *NotificationStore,
        alloc: std.mem.Allocator,
        id: []const u8,
    ) !struct { title: [:0]const u8, body: [:0]const u8 } {
        const removed = self.map.fetchRemove(id) orelse return error.MissingNotification;
        alloc.free(removed.key);
        var pending = removed.value;
        errdefer pending.deinit(alloc);

        try pending.title.finish(alloc);
        try pending.body.finish(alloc);

        self.clearCompleted(alloc);
        self.completed = pending;
        const completed = &self.completed.?;
        return .{
            .title = if (completed.title.decoded.items.len > 1)
                completed.title.sentinel()
            else
                default_title,
            .body = if (completed.body.decoded.items.len > 1)
                completed.body.sentinel()
            else
                "",
        };
    }
};

pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"99");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    if (data.len <= 1) return null;

    const raw = data[0 .. data.len - 1];
    if (raw[0] == ';') {
        const title = data[1 .. data.len - 1 :0];
        if (title.len == 0) return null;
        if (!encoding.isSafeUtf8(title)) {
            log.warn("simple notification title is not escape code safe UTF-8", .{});
            return null;
        }

        parser.command = .{
            .show_desktop_notification = .{
                .title = title,
                .body = "",
            },
        };
        return &parser.command;
    }

    const payload_start = std.mem.indexOfScalar(u8, raw, ';') orelse {
        log.warn("notification is missing payload separator", .{});
        return null;
    };
    const metadata = raw[0..payload_start];
    const payload = data[payload_start + 1 .. data.len - 1 :0];

    const id = id: {
        const value = optionValue(metadata, "i") orelse break :id anonymous_id;
        if (!validId(value)) {
            log.warn("notification has an invalid id", .{});
            return null;
        }
        break :id value;
    };
    const part_value = optionValue(metadata, "p") orelse "title";
    const part: NotificationStore.PartKind = if (std.mem.eql(u8, part_value, "title"))
        .title
    else if (std.mem.eql(u8, part_value, "body"))
        .body
    else
        return null;
    const encoded = std.mem.eql(u8, optionValue(metadata, "e") orelse "0", "1");
    const done = !std.mem.eql(u8, optionValue(metadata, "d") orelse "1", "0");

    const alloc = parser.alloc orelse {
        log.warn("allocator is required to store structured OSC 99 notifications", .{});
        return null;
    };
    parser.kitty_notifications.append(
        alloc,
        id,
        part,
        payload,
        encoded,
    ) catch |err| {
        parser.kitty_notifications.discard(alloc, id);
        log.warn("failed to accumulate OSC 99 notification err={}", .{err});
        return null;
    };
    if (!done) return null;

    const completed = parser.kitty_notifications.complete(alloc, id) catch |err| {
        parser.kitty_notifications.discard(alloc, id);
        log.warn("failed to complete OSC 99 notification err={}", .{err});
        return null;
    };
    parser.command = .{ .show_desktop_notification = .{
        .title = completed.title,
        .body = completed.body,
    } };
    return &parser.command;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_notification_id_bytes) return false;
    for (id) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+', '.' => {},
        else => return false,
    };
    return true;
}

fn optionValue(metadata: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, metadata, ':');
    while (it.next()) |segment| {
        const split = std.mem.indexOfScalar(u8, segment, '=') orelse continue;
        if (std.mem.eql(u8, segment[0..split], key)) return segment[split + 1 ..];
    }
    return null;
}

test "OSC 99: simple notification" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    for ("99;;Build complete") |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Build complete", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: title and body chunks are paired by id" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=build:p=title:d=0;Build") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=body;Done") |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Build", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Done", cmd.show_desktop_notification.body);
}

test "OSC 99: body without title uses default title" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=missing:p=body;Needs input") |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("cmux", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Needs input", cmd.show_desktop_notification.body);
}

test "OSC 99: repeated title chunks concatenate" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=build:p=title:d=0;Old") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=title:d=0;New") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=body;Done") |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("OldNew", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Done", cmd.show_desktop_notification.body);
}

test "OSC 99: unsafe payload is ignored" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=bad:p=body;bad\x07payload") |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC 99: base64 payload is decoded" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=encoded:p=body:e=1;SGVsbG8=") |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Hello", cmd.show_desktop_notification.body);
}

test "OSC 99: title and body chunks concatenate until done" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=build:p=title:d=0;Build ") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=title:d=0;finished") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=body:d=0;Line ") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=body:d=1;one") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("Build finished", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Line one", cmd.show_desktop_notification.body);
}

test "OSC 99: base64 stream may be split between encoding quanta" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=encoded:p=body:e=1:d=0;SGV") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=encoded:p=body:e=1:d=1;sbG8=") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expectEqualStrings("Hello", cmd.show_desktop_notification.body);
}

test "OSC 99: independently padded base64 chunks concatenate" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=encoded:p=body:e=1:d=0;SGk=") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=encoded:p=body:e=1:d=1;IQ==") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expectEqualStrings("Hi!", cmd.show_desktop_notification.body);
}

test "OSC 99: unpadded final base64 is decoded" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=encoded:p=body:e=1;SGVsbG8") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expectEqualStrings("Hello", cmd.show_desktop_notification.body);
}

test "OSC 99: notification ids can be interleaved" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=first:p=title:d=0;First") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();
    for ("99;i=second:p=title:d=0;Second") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();
    for ("99;i=first:p=body;Done") |ch| p.next(ch);
    const first = p.end('\x1b').?.*;
    try testing.expectEqualStrings("First", first.show_desktop_notification.title);
    p.reset();
    for ("99;i=second:p=body;Ready") |ch| p.next(ch);
    const second = p.end('\x1b').?.*;
    try testing.expectEqualStrings("Second", second.show_desktop_notification.title);
}

test "OSC 99: invalid or unsafe base64 retires pending state" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=invalid:p=body:e=1;%%%") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(@as(usize, 0), p.kitty_notifications.map.count());

    p.reset();
    for ("99;i=unsafe:p=body:e=1;Bw==") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    try testing.expectEqual(@as(usize, 0), p.kitty_notifications.map.count());
}

test "OSC 99: completed notification state is retired" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=done:p=title:d=0;Build") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=done:p=body;Complete") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') != null);

    p.reset();
    try testing.expectEqual(@as(usize, 0), p.kitty_notifications.map.count());
}

test "OSC 99: reused id does not inherit a completed title" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=reused:p=title:d=0;Old title") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();
    for ("99;i=reused:p=body;Old body") |ch| p.next(ch);
    _ = p.end('\x1b').?;

    p.reset();
    for ("99;i=reused:p=body;New body") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expectEqualStrings("cmux", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("New body", cmd.show_desktop_notification.body);
}

test "OSC 99: title defaults and an empty chunk can finish it" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=default-part:d=0;Build") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
    p.reset();
    for ("99;i=default-part;") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expectEqualStrings("Build", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: completed title-only notification emits" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=title-only:p=title;Ready") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;
    try testing.expectEqualStrings("Ready", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.body);
}

test "OSC 99: incomplete notification state is bounded" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    var sequence: [128]u8 = undefined;
    for (0..128) |i| {
        const bytes = try std.fmt.bufPrint(
            &sequence,
            "99;i=pending-{d}:p=title:d=0;pending",
            .{i},
        );
        for (bytes) |ch| p.next(ch);
        try testing.expect(p.end('\x1b') == null);
        p.reset();
    }

    try testing.expect(p.kitty_notifications.map.count() <= 64);
    try testing.expect(!p.kitty_notifications.map.contains("pending-0"));
    try testing.expect(p.kitty_notifications.map.contains("pending-127"));
}
