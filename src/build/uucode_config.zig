const std = @import("std");
const assert = std.debug.assert;
const config = @import("config.zig");
const config_x = @import("config.x.zig");
const d = config.default;
const wcwidth = config_x.wcwidth;
const grapheme_break = if (@hasDecl(config_x, "grapheme_break_no_control"))
    config_x.grapheme_break_no_control
else
    config_x.grapheme_break_pedantic_emoji;
const grapheme_break_field = if (@hasDecl(config_x, "grapheme_break_no_control"))
    "grapheme_break_no_control"
else
    "grapheme_break_pedantic_emoji";
const has_wcwidth_split = hasDefaultField("wcwidth_standalone");
const has_emoji_vs_base_field = hasDefaultField("is_emoji_vs_base");

const Allocator = std.mem.Allocator;

fn hasDefaultField(comptime name: []const u8) bool {
    inline for (d.fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return true;
    }
    return false;
}

fn computeWidth(
    alloc: std.mem.Allocator,
    cp: u21,
    data: anytype,
    backing: anytype,
    tracking: anytype,
) Allocator.Error!void {
    _ = alloc;
    _ = cp;
    _ = backing;
    _ = tracking;

    if (comptime has_wcwidth_split) {
        // Preserve older uucode behavior: width is 0 in-cluster except for
        // standalone emoji modifiers.
        if (data.wcwidth_zero_in_grapheme and !data.is_emoji_modifier) {
            data.width = 0;
        } else {
            data.width = @min(2, data.wcwidth_standalone);
        }
    } else {
        // Newer uucode variants expose a single wcwidth value.
        const w = data.wcwidth;
        data.width = if (w <= 0) 0 else @intCast(@min(@as(i3, 2), w));
    }
}

const width = config.Extension{
    .inputs = if (has_wcwidth_split)
        &.{
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_modifier",
        }
    else
        &.{"wcwidth"},
    .compute = &computeWidth,
    .fields = &.{
        .{ .name = "width", .type = u2 },
    },
};

fn computeEmojiVsBase(
    alloc: Allocator,
    cp: u21,
    data: anytype,
    backing: anytype,
    tracking: anytype,
) Allocator.Error!void {
    _ = alloc;
    _ = cp;
    _ = backing;
    _ = tracking;

    if (comptime has_emoji_vs_base_field) {
        data.is_emoji_vs_base = data.is_emoji_vs_base;
    } else {
        // Newer uucode variants dropped this field, so approximate with
        // emoji base property for compatibility with Ghostty's VS handling.
        data.is_emoji_vs_base = data.is_emoji;
    }
}

const emoji_vs_base = config.Extension{
    .inputs = if (has_emoji_vs_base_field)
        &.{"is_emoji_vs_base"}
    else
        &.{"is_emoji"},
    .compute = &computeEmojiVsBase,
    .fields = &.{
        .{ .name = "is_emoji_vs_base", .type = bool },
    },
};

fn computeIsSymbol(
    alloc: Allocator,
    cp: u21,
    data: anytype,
    backing: anytype,
    tracking: anytype,
) Allocator.Error!void {
    _ = alloc;
    _ = cp;
    _ = backing;
    _ = tracking;
    const block = data.block;
    data.is_symbol = data.general_category == .other_private_use or
        block == .arrows or
        block == .dingbats or
        block == .emoticons or
        block == .miscellaneous_symbols or
        block == .enclosed_alphanumerics or
        block == .enclosed_alphanumeric_supplement or
        block == .miscellaneous_symbols_and_pictographs or
        block == .transport_and_map_symbols;
}

const is_symbol = config.Extension{
    .inputs = &.{ "block", "general_category" },
    .compute = &computeIsSymbol,
    .fields = &.{
        .{ .name = "is_symbol", .type = bool },
    },
};

pub const tables = [_]config.Table{
    .{
        .name = "runtime",
        .extensions = &.{},
        .fields = &.{
            d.field("is_emoji_presentation"),
            d.field("case_folding_full"),
        },
    },
    .{
        .name = "buildtime",
        .extensions = &.{
            wcwidth,
            grapheme_break,
            width,
            emoji_vs_base,
            is_symbol,
        },
        .fields = &.{
            width.field("width"),
            grapheme_break.field(grapheme_break_field),
            is_symbol.field("is_symbol"),
            emoji_vs_base.field("is_emoji_vs_base"),
        },
    },
};
