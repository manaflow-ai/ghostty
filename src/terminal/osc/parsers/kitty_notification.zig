//! Kitty desktop notification protocol (OSC 99).
//! Specification: https://sw.kovidgoyal.net/kitty/desktop-notifications/

const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const encoding = @import("../encoding.zig");

const log = std.log.scoped(.kitty_notification);

const default_id = "default";
const default_title: [:0]const u8 = "cmux";

pub const TitleMap = struct {
    map: std.StringHashMapUnmanaged([:0]u8) = .{},

    pub fn deinit(self: *TitleMap, alloc_: ?std.mem.Allocator) void {
        const alloc = alloc_ orelse return;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.map.deinit(alloc);
        self.* = .{};
    }

    fn put(
        self: *TitleMap,
        alloc: std.mem.Allocator,
        id: []const u8,
        title: []const u8,
    ) !void {
        const gop = try self.map.getOrPut(alloc, id);
        const inserted_new = !gop.found_existing;
        errdefer {
            if (inserted_new) _ = self.map.remove(id);
        }

        const value = try alloc.dupeZ(u8, title);
        errdefer alloc.free(value);

        if (gop.found_existing) {
            alloc.free(gop.value_ptr.*);
            gop.value_ptr.* = value;
            return;
        }

        const key = try alloc.dupe(u8, id);
        gop.key_ptr.* = key;
        gop.value_ptr.* = value;
    }

    fn get(self: *TitleMap, id: []const u8) ?[:0]const u8 {
        return self.map.get(id);
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
    if (payload.len == 0) return null;
    if (!encoding.isSafeUtf8(payload)) {
        log.warn("notification payload is not escape code safe UTF-8", .{});
        return null;
    }

    const id = id: {
        const value = optionValue(metadata, "i") orelse break :id default_id;
        break :id if (value.len == 0) default_id else value;
    };
    const part = optionValue(metadata, "p") orelse return null;

    if (std.mem.eql(u8, part, "title")) {
        const alloc = parser.alloc orelse {
            log.warn("allocator is required to store OSC 99 notification titles", .{});
            return null;
        };
        parser.kitty_notification_titles.put(alloc, id, payload) catch |err| {
            log.warn("failed to store OSC 99 notification title err={}", .{err});
        };
        return null;
    }

    if (std.mem.eql(u8, part, "body")) {
        parser.command = .{
            .show_desktop_notification = .{
                .title = parser.kitty_notification_titles.get(id) orelse default_title,
                .body = payload,
            },
        };
        return &parser.command;
    }

    return null;
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

    for ("99;i=build:p=title;Build") |ch| p.next(ch);
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

test "OSC 99: repeated title chunks replace the previous title" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    for ("99;i=build:p=title;Old") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=title;New") |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);

    p.reset();
    for ("99;i=build:p=body;Done") |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("New", cmd.show_desktop_notification.title);
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
    try testing.expectEqual(@as(usize, 0), p.kitty_notification_titles.map.count());
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

    try testing.expect(p.kitty_notification_titles.map.count() <= 64);
}
