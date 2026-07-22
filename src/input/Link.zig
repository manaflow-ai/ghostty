//! A link is a clickable element that can be used to trigger some action.
//! A link is NOT just a URL that opens in a browser. A link is any generic
//! regular expression match over terminal text that can trigger various
//! action types.
const Link = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const Mods = @import("key.zig").Mods;

/// The regular expression that will be used to match the link. Ownership
/// of this memory is up to the caller. The link will never free this memory.
regex: []const u8,

/// The action that will be triggered when the link is clicked.
action: Action,

/// The situations in which the link will be highlighted. A link is only
/// clickable by the mouse when it is highlighted, so this also controls
/// when the link is clickable.
highlight: Highlight,

/// The terminal text region searched by this matcher.
candidate_scope: CandidateScope = .semantic,

/// Whether a real newline plus indentation after common link punctuation is
/// treated as prose hard-wrapping. Built-in URL and path matchers enable this;
/// custom matchers retain their literal newline behavior by default.
hard_wrap_continuations: bool = false,

/// Append a matching-only delimiter after a candidate whose hard newlines
/// were removed. This is an internal policy for the built-in path matcher,
/// whose end-of-input branch otherwise accepts trailing sentence punctuation.
/// Custom matchers keep their normal end-anchor semantics by default.
hard_wrap_match_delimiter: bool = false,

pub const CandidateScope = enum {
    /// Search only the semantic prompt region containing the clicked cell.
    semantic,

    /// Search the complete soft-wrapped logical line, subject to the
    /// renderer's fixed candidate-size budget. This is only for lexical
    /// matchers where printable soft-wrap continuity intentionally outranks
    /// OSC 133 metadata, such as the built-in explicit-scheme URL matcher.
    /// File paths and custom matchers remain semantic.
    bounded_logical,
};

pub const Action = union(enum) {
    /// Open the full matched value using the default open program.
    /// For example, on macOS this is "open" and on Linux this is "xdg-open".
    open: void,

    /// Open the OSC8 hyperlink under the mouse position. _-prefixed means
    /// this can't be user-specified, it's only used internally.
    _open_osc8: void,
};

pub const Highlight = union(enum) {
    /// Always highlight the link.
    always: void,

    /// Only highlight the link when the mouse is hovering over it.
    hover: void,

    /// Highlight anytime the given mods are pressed, either when
    /// hovering or always. For always, all links will be highlighted
    /// when the mods are pressed regardless of if the mouse is hovering
    /// over them.
    ///
    /// Note that if "shift" is specified here, this will NEVER match in
    /// TUI programs that capture mouse events. "Shift" with mouse capture
    /// escapes the mouse capture but strips the "shift" so it can't be
    /// detected.
    always_mods: Mods,
    hover_mods: Mods,
};

/// Returns a new oni.Regex that can be used to match the link.
pub fn oniRegex(self: *const Link) !oni.Regex {
    return try oni.Regex.init(
        self.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
}

/// Deep clone the link.
pub fn clone(self: *const Link, alloc: Allocator) Allocator.Error!Link {
    return .{
        .regex = try alloc.dupe(u8, self.regex),
        .action = self.action,
        .highlight = self.highlight,
        .candidate_scope = self.candidate_scope,
        .hard_wrap_continuations = self.hard_wrap_continuations,
        .hard_wrap_match_delimiter = self.hard_wrap_match_delimiter,
    };
}

/// Check if two links are equal.
pub fn equal(self: *const Link, other: *const Link) bool {
    return std.meta.eql(self.action, other.action) and
        std.meta.eql(self.highlight, other.highlight) and
        self.candidate_scope == other.candidate_scope and
        self.hard_wrap_continuations == other.hard_wrap_continuations and
        self.hard_wrap_match_delimiter == other.hard_wrap_match_delimiter and
        std.mem.eql(u8, self.regex, other.regex);
}

test "Link: candidate scope defaults to semantic" {
    const link: Link = .{
        .regex = "https?://",
        .action = .{ .open = {} },
        .highlight = .hover,
    };
    try std.testing.expectEqual(CandidateScope.semantic, link.candidate_scope);
    try std.testing.expect(!link.hard_wrap_continuations);
    try std.testing.expect(!link.hard_wrap_match_delimiter);
}
