//! OSC 699: pane-local coding-agent footer metadata.
//!
//! The payload is intentionally opaque to Ghostty. Embedders interpret the
//! semicolon-separated fields so the terminal parser remains independent of
//! any particular coding agent. An empty payload explicitly clears metadata.

const std = @import("std");
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const capture = if (parser.capture) |*value| value else {
        parser.state = .invalid;
        return null;
    };

    parser.command = .{ .agent_footer = capture.trailing() };
    return &parser.command;
}

test "OSC 699: captures agent footer metadata" {
    var parser: Parser = .init(null);
    const input = "699;agent=claude;context=34%";
    for (input) |byte| parser.next(byte);

    const command = parser.end(null).?.*;
    try std.testing.expect(command == .agent_footer);
    try std.testing.expectEqualStrings(
        "agent=claude;context=34%",
        command.agent_footer,
    );
}

test "OSC 699: empty payload clears agent footer metadata" {
    var parser: Parser = .init(null);
    const input = "699;";
    for (input) |byte| parser.next(byte);

    const command = parser.end(null).?.*;
    try std.testing.expect(command == .agent_footer);
    try std.testing.expectEqualStrings("", command.agent_footer);
}
