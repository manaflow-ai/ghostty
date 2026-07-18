const std = @import("std");
const Config = @import("Config.zig");
const FileFormatter = @import("formatter_file.zig").FileFormatter;

/// Serialize resolved config values as parseable overrides relative to this
/// Ghostty build. Source directives are omitted so the consumer cannot reopen
/// files after crossing a process boundary.
pub fn canonical(alloc: std.mem.Allocator, config: *const Config) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    errdefer buffer.deinit();
    const file: FileFormatter = .{
        .alloc = alloc,
        .config = config,
        .docs = false,
        .changed = true,
        .excluded = .initMany(&.{
            .theme,
            .@"config-file",
            .@"command-palette-entry",
        }),
    };
    try file.format(&buffer.writer);
    return try buffer.toOwnedSlice();
}
