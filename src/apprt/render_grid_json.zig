const std = @import("std");

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
    try jw.endObject();
}

pub fn writeCursorTextColor(jw: *std.json.Stringify, color: [3]u8) !void {
    _ = jw;
    _ = color;
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
