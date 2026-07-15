const std = @import("std");
const lib = @import("../lib/main.zig");

pub const Status = enum(c_int) {
    success = 0,
    retryable_not_quiescent = 1,
    failure = 2,
};

pub const Cursor = struct {
    row: u32,
    column: u32,
    visible: bool,
    style: []const u8,
    blinking: bool,
    cell_width: u32,
    opacity: f64,
};

pub fn writeCursor(jw: *std.json.Stringify, cursor: Cursor) !void {
    try jw.beginObject();
    try jw.objectField("row");
    try jw.write(cursor.row);
    try jw.objectField("column");
    try jw.write(cursor.column);
    try jw.objectField("visible");
    try jw.write(cursor.visible);
    try jw.objectField("style");
    try jw.write(cursor.style);
    try jw.objectField("blinking");
    try jw.write(cursor.blinking);
    try jw.objectField("cell_width");
    try jw.write(cursor.cell_width);
    try jw.objectField("opacity");
    try jw.write(cursor.opacity);
    try jw.endObject();
}

pub fn writeCursorTextColor(jw: *std.json.Stringify, color: [3]u8) !void {
    const digits = "0123456789ABCDEF";
    var value: [7]u8 = undefined;
    value[0] = '#';
    value[1] = digits[color[0] >> 4];
    value[2] = digits[color[0] & 0x0F];
    value[3] = digits[color[1] >> 4];
    value[4] = digits[color[1] & 0x0F];
    value[5] = digits[color[2] >> 4];
    value[6] = digits[color[2] & 0x0F];

    try jw.objectField("terminal_cursor_text_color");
    try jw.write(value[0..]);
}

fn fixtureJson(cursor: Cursor, cursor_text_color: [3]u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &buf.writer };
    try jw.beginObject();
    try jw.objectField("cursor");
    try writeCursor(&jw, cursor);
    try writeCursorTextColor(&jw, cursor_text_color);
    try jw.endObject();
    return try buf.toOwnedSlice();
}

test "render grid cursor JSON includes width opacity and text color" {
    const json = try fixtureJson(
        .{
            .row = 2,
            .column = 3,
            .visible = true,
            .style = "block",
            .blinking = false,
            .cell_width = 2,
            .opacity = 0.5,
        },
        .{ 17, 34, 51 },
    );
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"cell_width\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"opacity\":0.5") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, json, "\"terminal_cursor_text_color\":\"#112233\"") != null,
    );
}

test "ghostty.h render grid status" {
    try lib.checkGhosttyHEnum(Status, "GHOSTTY_RENDER_GRID_");
}
