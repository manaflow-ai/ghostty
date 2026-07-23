//! Canonical resolution for interactive regex links.
//!
//! A resolved link retains the exact regex byte range and its exact terminal
//! cells. Consumers must use `Resolved.value` and `Resolved.cells`; a bounding
//! selection is only a compatibility view for selection-oriented UI.
const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const input = @import("input.zig");
const link_wrap = @import("link_wrap.zig");
const terminal = @import("terminal/main.zig");

pub fn Candidate(comptime Cell: type) type {
    return struct {
        string: [:0]const u8,
        mapped_len: usize,
        map: []const Cell,
    };
}

pub fn Prepared(comptime Cell: type) type {
    return struct {
        target: Cell,
        candidates: [candidate_key_count][]const Candidate(Cell) =
            [_][]const Candidate(Cell){&.{}} ** candidate_key_count,
    };
}

/// A borrowed resolved match. Its slices live as long as the prepared
/// candidates and allocator passed to `resolveAt`. Resolution is designed for
/// a short-lived frame or operation arena, which owns every prepared and
/// resolved slice as one unit.
pub fn Resolved(comptime Cell: type) type {
    return struct {
        matcher_index: usize,
        action: input.Link.Action,
        value: []const u8,
        cells: []const Cell,
    };
}

const CandidateKey = enum(u3) {
    semantic,
    semantic_hard,
    semantic_hard_delimited,
    bounded_logical,
    bounded_logical_hard,
    bounded_logical_hard_delimited,
};

const candidate_key_count = @typeInfo(CandidateKey).@"enum".fields.len;

fn candidateKey(link: anytype) CandidateKey {
    return switch (link.candidate_scope) {
        .semantic => if (!link.hard_wrap_continuations)
            .semantic
        else if (link.hard_wrap_match_delimiter)
            .semantic_hard_delimited
        else
            .semantic_hard,
        .bounded_logical => if (!link.hard_wrap_continuations)
            .bounded_logical
        else if (link.hard_wrap_match_delimiter)
            .bounded_logical_hard_delimited
        else
            .bounded_logical_hard,
    };
}

fn candidateScope(key: CandidateKey) input.Link.CandidateScope {
    return switch (key) {
        .semantic, .semantic_hard, .semantic_hard_delimited => .semantic,
        .bounded_logical,
        .bounded_logical_hard,
        .bounded_logical_hard_delimited,
        => .bounded_logical,
    };
}

fn candidateNormalizesHardWraps(key: CandidateKey) bool {
    return switch (key) {
        .semantic, .bounded_logical => false,
        else => true,
    };
}

fn candidateUsesDelimiter(key: CandidateKey) bool {
    return switch (key) {
        .semantic_hard_delimited, .bounded_logical_hard_delimited => true,
        else => false,
    };
}

pub fn candidatesFor(
    comptime Cell: type,
    prepared: Prepared(Cell),
    link: anytype,
) []const Candidate(Cell) {
    return prepared.candidates[@intFromEnum(candidateKey(link))];
}

pub fn matcherActive(
    link: anytype,
    mouse_mods: ?input.Mods,
) bool {
    const mods = mouse_mods orelse return true;
    return switch (link.highlight) {
        .always, .hover => true,
        .always_mods, .hover_mods => |required| required.equal(mods),
    };
}

pub fn alwaysMatcherActive(
    link: anytype,
    mouse_mods: input.Mods,
) bool {
    return switch (link.highlight) {
        .always => true,
        .always_mods => |required| required.equal(mouse_mods),
        .hover, .hover_mods => false,
    };
}

/// Prepare every candidate variant needed by eligible matchers around one
/// terminal pin. Candidate construction and hard-wrap policy therefore have
/// one owner for click, preview, copy, and renderer hover. All allocations
/// belong to a short-lived operation arena supplied by the caller.
pub fn prepareAt(
    alloc: Allocator,
    screen: *terminal.Screen,
    links: anytype,
    target: terminal.Pin,
    mouse_mods: ?input.Mods,
) !Prepared(terminal.Pin) {
    if (target.node.pageIfResident() == null) return .{ .target = target };
    const canonical_target = if (target.rowAndCell().cell.wide == .spacer_tail)
        target.left(1)
    else
        target;
    var needed = [_]bool{false} ** candidate_key_count;

    for (links) |link| {
        if (!matcherActive(link, mouse_mods)) continue;
        needed[@intFromEnum(candidateKey(link))] = true;
    }

    for (needed) |value| {
        if (value) break;
    } else return .{ .target = canonical_target };

    // Candidate scopes can overlap without sharing boundaries. Resolve the
    // complete connected component around the target so matcher priority is
    // identical for click, hover, and whole-viewport rendering. For example,
    // a semantic matcher in the BAR half of FOOBAR must still suppress a
    // lower-priority logical FOOBAR match when the pointer is over FOO.
    var builders = [_]std.ArrayList(Candidate(terminal.Pin)){.empty} **
        candidate_key_count;
    defer for (&builders) |*builder| builder.deinit(alloc);
    var covered: CandidateCoverage = .{};
    defer covered.deinit(alloc);
    var budget: PreparationBudget = .{};
    var pending: std.ArrayList(terminal.Selection) = .empty;
    defer pending.deinit(alloc);

    for (needed, 0..) |is_needed, index| {
        if (!is_needed) continue;
        const key: CandidateKey = @enumFromInt(index);
        if (try appendCandidate(
            terminal.Pin,
            alloc,
            screen,
            key,
            canonical_target,
            &covered,
            &budget,
            &builders,
            {},
            identityPin,
        )) |selection| try pending.append(alloc, selection);
    }

    try expandCandidateComponents(
        terminal.Pin,
        alloc,
        screen,
        &needed,
        &covered,
        &budget,
        &builders,
        &pending,
        {},
        identityPin,
    );

    if (budget.exhausted) return .{ .target = canonical_target };

    var result: Prepared(terminal.Pin) = .{ .target = canonical_target };
    for (&builders, 0..) |*builder, index| {
        result.candidates[index] = try builder.toOwnedSlice(alloc);
    }
    return result;
}

fn identityPin(
    _: void,
    _: *terminal.Screen,
    pin: terminal.Pin,
) terminal.Pin {
    return pin;
}

pub fn VisibleCandidates(comptime Cell: type) type {
    return struct {
        candidates: [candidate_key_count][]const Candidate(Cell) =
            [_][]const Candidate(Cell){&.{}} ** candidate_key_count,

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            for (self.candidates) |candidates| {
                for (candidates) |candidate| {
                    alloc.free(candidate.string);
                    alloc.free(candidate.map);
                }
                if (candidates.len > 0) alloc.free(candidates);
            }
            self.* = .{};
        }
    };
}

const CandidateRowIdentity = struct {
    key: CandidateKey,
    node: usize,
    y: terminal.size.CellCountInt,
};

const CellRange = struct {
    start: terminal.size.CellCountInt,
    end: terminal.size.CellCountInt,
};

const CandidateCoverage = struct {
    rows: std.AutoHashMapUnmanaged(
        CandidateRowIdentity,
        std.ArrayListUnmanaged(CellRange),
    ) = .empty,

    fn contains(
        self: *const CandidateCoverage,
        key: CandidateKey,
        pin: terminal.Pin,
    ) bool {
        const ranges = self.rows.get(.{
            .key = key,
            .node = @intFromPtr(pin.node),
            .y = pin.y,
        }) orelse return false;
        var low: usize = 0;
        var high = ranges.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const range = ranges.items[middle];
            if (pin.x < range.start) {
                high = middle;
            } else if (pin.x > range.end) {
                low = middle + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    fn add(
        self: *CandidateCoverage,
        alloc: Allocator,
        key: CandidateKey,
        row: terminal.Pin,
        range: CellRange,
    ) !void {
        const entry = try self.rows.getOrPut(alloc, .{
            .key = key,
            .node = @intFromPtr(row.node),
            .y = row.y,
        });
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        const ranges = entry.value_ptr;
        var index = ranges.items.len;
        if (index == 0 or ranges.items[index - 1].start <= range.start) {
            try ranges.append(alloc, range);
        } else {
            var low: usize = 0;
            var high = index;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (ranges.items[middle].start < range.start)
                    low = middle + 1
                else
                    high = middle;
            }
            index = low;
            try ranges.insert(alloc, index, range);
        }

        // Target preparation can discover a row's middle semantic domain
        // before its neighbors. Keep coverage sorted and coalesced so lookup
        // remains logarithmic regardless of discovery order.
        if (index > 0 and ranges.items[index - 1].end >= ranges.items[index].start) {
            ranges.items[index - 1].end = @max(
                ranges.items[index - 1].end,
                ranges.items[index].end,
            );
            _ = ranges.orderedRemove(index);
            index -= 1;
        }
        while (index + 1 < ranges.items.len and
            ranges.items[index].end >= ranges.items[index + 1].start)
        {
            ranges.items[index].end = @max(
                ranges.items[index].end,
                ranges.items[index + 1].end,
            );
            _ = ranges.orderedRemove(index + 1);
        }
    }

    fn deinit(self: *CandidateCoverage, alloc: Allocator) void {
        var values = self.rows.valueIterator();
        while (values.next()) |ranges| ranges.deinit(alloc);
        self.rows.deinit(alloc);
    }
};

const max_visible_candidate_cells = 128 * 1024;
const max_visible_candidate_domains = 4 * 1024;
const max_candidate_attempts = 512;
// Always-highlight preparation runs while holding the terminal lock on every
// rendered frame. Keep that recurring work far below the larger interactive
// preparation allowance while still accepting one maximum-size 8K domain.
const max_always_frame_candidate_cells = 16 * 1024;
const max_always_frame_candidate_bytes = 64 * 1024;
const CandidateReadError = error{NonResidentPage};

const PreparationBudget = struct {
    cells_remaining: usize = max_visible_candidate_cells,
    probe_cells_remaining: usize = max_visible_candidate_cells,
    bytes_remaining: usize = max_candidate_bytes,
    domains_remaining: usize = max_visible_candidate_domains,
    attempts_remaining: usize = max_candidate_attempts,
    exhausted: bool = false,

    fn beginAttempt(self: *PreparationBudget) bool {
        if (self.attempts_remaining == 0) {
            self.exhausted = true;
            return false;
        }
        self.attempts_remaining -= 1;
        return true;
    }

    fn probeCells(self: *PreparationBudget, cells: usize) bool {
        if (cells > self.probe_cells_remaining) {
            self.exhausted = true;
            return false;
        }
        self.probe_cells_remaining -= cells;
        return true;
    }

    fn beginDomain(self: *PreparationBudget, cost: SelectionCost) bool {
        if (self.domains_remaining == 0 or cost.cells > self.cells_remaining) {
            self.exhausted = true;
            return false;
        }
        self.domains_remaining -= 1;
        self.cells_remaining -= cost.cells;
        return true;
    }

    fn addBytes(self: *PreparationBudget, len: usize) bool {
        if (len > self.bytes_remaining) {
            self.exhausted = true;
            return false;
        }
        self.bytes_remaining -= len;
        return true;
    }
};

/// A small-buffer writer that counts output without retaining it and fails as
/// soon as the byte limit is crossed. This lets terminal formatting abort in
/// the middle of an oversized grapheme instead of traversing it to completion.
const CappedCountingWriter = struct {
    count: usize = 0,
    limit: usize,
    writer: std.Io.Writer,

    fn init(buffer: []u8, limit: usize) CappedCountingWriter {
        // One byte beyond the limit ensures even a tiny final buffered write
        // is observable by fullCount. Larger output reaches drain and aborts.
        const buffer_len = if (limit < buffer.len) limit + 1 else buffer.len;
        return .{
            .limit = limit,
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .rebase = std.Io.Writer.failingRebase,
                },
                .buffer = buffer[0..buffer_len],
            },
        };
    }

    fn fullCount(self: *const CappedCountingWriter) ?usize {
        return std.math.add(usize, self.count, self.writer.end) catch null;
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *CappedCountingWriter = @alignCast(
            @fieldParentPtr("writer", writer),
        );
        std.debug.assert(data.len > 0);

        var incoming: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            incoming = std.math.add(usize, incoming, bytes.len) catch
                return error.WriteFailed;
        }
        const pattern_len = std.math.mul(
            usize,
            data[data.len - 1].len,
            splat,
        ) catch return error.WriteFailed;
        incoming = std.math.add(usize, incoming, pattern_len) catch
            return error.WriteFailed;
        const buffered = std.math.add(
            usize,
            self.count,
            writer.end,
        ) catch return error.WriteFailed;
        const total = std.math.add(usize, buffered, incoming) catch
            return error.WriteFailed;
        if (total > self.limit) return error.WriteFailed;

        self.count = total;
        writer.end = 0;
        return incoming;
    }
};

fn appendCandidate(
    comptime Cell: type,
    alloc: Allocator,
    screen: *terminal.Screen,
    key: CandidateKey,
    target: terminal.Pin,
    covered: *CandidateCoverage,
    budget: *PreparationBudget,
    builders: *[candidate_key_count]std.ArrayList(Candidate(Cell)),
    mapper_context: anytype,
    mapper: anytype,
) !?terminal.Selection {
    if (budget.exhausted or covered.contains(key, target)) return null;
    if (!budget.beginAttempt()) return null;
    const selection = candidateSelectionForKey(screen, target, key, budget) catch {
        budget.exhausted = true;
        return null;
    } orelse return null;
    const cost = selectionCost(screen, selection) catch {
        budget.exhausted = true;
        return null;
    } orelse return null;
    if (!budget.beginDomain(cost)) return null;

    // Mark the complete domain before building it. Viewport enumeration can
    // otherwise rediscover the same soft-wrapped or hard-joined candidate
    // once per row and turn bounded selection into quadratic work.
    // Every internal selection is constructed in terminal-forward order.
    // Avoid Selection.topLeft/bottomRight here: ordering a selection walks
    // from the oldest history page to both pins.
    const top = selection.start();
    const bottom = selection.end();
    var rows = top.rowIterator(.right_down, bottom);
    while (rows.next()) |row| {
        const start_x: usize = if (row.node == top.node and row.y == top.y)
            top.x
        else
            0;
        const end_x: usize = if (row.node == bottom.node and row.y == bottom.y)
            bottom.x
        else
            row.node.cols() - 1;
        try covered.add(alloc, key, row, .{
            .start = @intCast(start_x),
            .end = @intCast(end_x),
        });
    }

    const source = (try candidateMapForSelection(
        alloc,
        screen,
        selection,
        key,
        budget.bytes_remaining,
    )) orelse {
        budget.exhausted = true;
        return null;
    };
    if (!budget.addBytes(source.string.len)) {
        alloc.free(source.string);
        alloc.free(source.map);
        return null;
    }
    errdefer alloc.free(source.string);
    defer alloc.free(source.map);
    const mapped = try alloc.alloc(Cell, source.map.len);
    errdefer alloc.free(mapped);
    for (source.map, mapped) |pin, *cell| {
        cell.* = mapper(mapper_context, screen, pin);
    }
    try builders[@intFromEnum(key)].append(alloc, .{
        .string = source.string,
        .mapped_len = source.mapped_len,
        .map = mapped,
    });
    return selection;
}

/// Expand the overlap-connected candidate components represented by pending
/// selections. Every active key is enumerated across each component, so a
/// higher-priority match can suppress an overlapping lower-priority match
/// even when their semantic or logical boundaries differ.
fn expandCandidateComponents(
    comptime Cell: type,
    alloc: Allocator,
    screen: *terminal.Screen,
    needed: *const [candidate_key_count]bool,
    covered: *CandidateCoverage,
    budget: *PreparationBudget,
    builders: *[candidate_key_count]std.ArrayList(Candidate(Cell)),
    pending: *std.ArrayList(terminal.Selection),
    mapper_context: anytype,
    mapper: anytype,
) !void {
    var semantic_needed = false;
    for (needed, 0..) |is_needed, index| {
        if (is_needed and candidateScope(@enumFromInt(index)) == .semantic) {
            semantic_needed = true;
            break;
        }
    }
    var pending_index: usize = 0;
    while (pending_index < pending.items.len and !budget.exhausted) : (pending_index += 1) {
        const selection = pending.items[pending_index];
        const top = selection.start();
        const bottom = selection.end();
        var rows = top.rowIterator(.right_down, bottom);
        while (rows.next()) |row| {
            const page = row.node.pageIfResident() orelse {
                budget.exhausted = true;
                break;
            };
            const start_x: usize = if (row.node == top.node and row.y == top.y)
                top.x
            else
                0;
            const end_x: usize = if (row.node == bottom.node and row.y == bottom.y)
                bottom.x
            else
                row.node.cols() - 1;

            // Each touched physical row identifies its complete bounded
            // logical domain. Coverage prevents rediscovering soft wraps.
            for (needed, 0..) |is_needed, index| {
                if (!is_needed) continue;
                const key: CandidateKey = @enumFromInt(index);
                if (candidateScope(key) != .bounded_logical) continue;
                var target = row;
                target.x = @intCast(start_x);
                if (try appendCandidate(
                    Cell,
                    alloc,
                    screen,
                    key,
                    target,
                    covered,
                    budget,
                    builders,
                    mapper_context,
                    mapper,
                )) |added| try pending.append(alloc, added);
            }
            if (budget.exhausted) break;
            if (!semantic_needed) continue;

            // Semantic domains can begin multiple times in one row. Probe
            // only transitions inside the intersecting range; the first cell
            // recovers a run that began before the range.
            const cells = page.getCells(page.getRow(row.y));
            var previous_semantic: ?terminal.page.Cell.SemanticContent = null;
            for (cells[start_x .. end_x + 1], start_x..) |cell, x| {
                if (previous_semantic) |previous| {
                    if (std.meta.eql(previous, cell.semantic_content)) continue;
                }
                previous_semantic = cell.semantic_content;
                var target = row;
                target.x = @intCast(x);
                for (needed, 0..) |is_needed, index| {
                    if (!is_needed) continue;
                    const key: CandidateKey = @enumFromInt(index);
                    if (candidateScope(key) != .semantic) continue;
                    if (try appendCandidate(
                        Cell,
                        alloc,
                        screen,
                        key,
                        target,
                        covered,
                        budget,
                        builders,
                        mapper_context,
                        mapper,
                    )) |added| try pending.append(alloc, added);
                }
                if (budget.exhausted) break;
            }
        }
    }
}

/// Copy every unique candidate domain intersecting the viewport for active
/// always-highlight matchers. Candidate strings and stable mapped cells can
/// then be resolved after releasing the terminal lock.
pub fn prepareVisibleAlways(
    comptime Cell: type,
    alloc: Allocator,
    screen: *terminal.Screen,
    links: anytype,
    mouse_mods: input.Mods,
    mapper_context: anytype,
    mapper: anytype,
) !VisibleCandidates(Cell) {
    var needed = [_]bool{false} ** candidate_key_count;
    for (links) |link| {
        if (!alwaysMatcherActive(link, mouse_mods)) continue;
        needed[@intFromEnum(candidateKey(link))] = true;
    }
    for (needed) |value| {
        if (value) break;
    } else return .{};
    var semantic_needed = false;
    for (needed, 0..) |is_needed, index| {
        if (is_needed and candidateScope(@enumFromInt(index)) == .semantic) {
            semantic_needed = true;
            break;
        }
    }

    var builders = [_]std.ArrayList(Candidate(Cell)){.empty} ** candidate_key_count;
    defer for (&builders) |*builder| builder.deinit(alloc);
    errdefer for (&builders) |*builder| {
        for (builder.items) |candidate| {
            alloc.free(candidate.string);
            alloc.free(candidate.map);
        }
    };
    var covered: CandidateCoverage = .{};
    defer covered.deinit(alloc);
    var budget: PreparationBudget = .{
        .cells_remaining = max_always_frame_candidate_cells,
        .probe_cells_remaining = max_always_frame_candidate_cells,
        .bytes_remaining = max_always_frame_candidate_bytes,
    };
    var pending: std.ArrayList(terminal.Selection) = .empty;
    defer pending.deinit(alloc);

    var rows = screen.pages.getTopLeft(.viewport).rowIterator(.right_down, null);
    var previous_wrap: ?bool = null;
    var logical_line_eligible = true;
    viewport_rows: for (0..screen.pages.rows) |_| {
        var row_pin = rows.next() orelse break;
        row_pin.x = 0;
        const page = row_pin.node.pageIfResident() orelse {
            budget.exhausted = true;
            break :viewport_rows;
        };
        const row = page.getRow(row_pin.y);

        // Preflight each soft-wrapped logical line once. If it exceeds the
        // fixed candidate budget, skip every semantic transition in that
        // same line instead of repeating the rejected 8K scan per cell.
        if (previous_wrap == null or !previous_wrap.?) {
            logical_line_eligible = (boundedLogicalLineChecked(row_pin, null) catch {
                budget.exhausted = true;
                break :viewport_rows;
            }) != null;
        }
        previous_wrap = row.wrap;
        if (!logical_line_eligible) continue;

        // Logical candidates have one domain per complete soft-wrapped line.
        for (needed, 0..) |is_needed, index| {
            if (!is_needed) continue;
            const key: CandidateKey = @enumFromInt(index);
            if (candidateScope(key) != .bounded_logical) continue;
            if (try appendCandidate(
                Cell,
                alloc,
                screen,
                key,
                row_pin,
                &covered,
                &budget,
                &builders,
                mapper_context,
                mapper,
            )) |selection| try pending.append(alloc, selection);
            if (budget.exhausted) break :viewport_rows;
        }

        // Semantic candidates can begin more than once inside a physical row.
        if (!semantic_needed) continue;
        const cells = page.getCells(row);
        var previous_semantic: ?terminal.page.Cell.SemanticContent = null;
        for (cells, 0..) |cell, x| {
            if (previous_semantic) |previous| {
                if (std.meta.eql(previous, cell.semantic_content)) continue;
            }
            previous_semantic = cell.semantic_content;
            var target = row_pin;
            target.x = @intCast(x);
            for (needed, 0..) |is_needed, index| {
                if (!is_needed) continue;
                const key: CandidateKey = @enumFromInt(index);
                if (candidateScope(key) != .semantic) continue;
                if (try appendCandidate(
                    Cell,
                    alloc,
                    screen,
                    key,
                    target,
                    &covered,
                    &budget,
                    &builders,
                    mapper_context,
                    mapper,
                )) |selection| try pending.append(alloc, selection);
                if (budget.exhausted) break :viewport_rows;
            }
        }
    }

    if (!budget.exhausted) try expandCandidateComponents(
        Cell,
        alloc,
        screen,
        &needed,
        &covered,
        &budget,
        &builders,
        &pending,
        mapper_context,
        mapper,
    );

    if (budget.exhausted) {
        for (&builders) |*builder| {
            for (builder.items) |candidate| {
                alloc.free(candidate.string);
                alloc.free(candidate.map);
            }
            builder.clearRetainingCapacity();
        }
        return .{};
    }

    var result: VisibleCandidates(Cell) = .{};
    errdefer result.deinit(alloc);
    for (&builders, 0..) |*builder, index| {
        result.candidates[index] = try builder.toOwnedSlice(alloc);
    }
    return result;
}

/// Convert prepared terminal pins to stable caller-owned cell identities while
/// the terminal lock is held. The candidate strings remain shared and mapped
/// arrays belong to the same short-lived operation arena.
pub fn mapPrepared(
    comptime Cell: type,
    alloc: Allocator,
    screen: *terminal.Screen,
    prepared: Prepared(terminal.Pin),
    mapper_context: anytype,
    mapper: anytype,
) !Prepared(Cell) {
    var result: Prepared(Cell) = .{
        .target = mapper(mapper_context, screen, prepared.target),
    };

    for (prepared.candidates, 0..) |sources, index| {
        if (sources.len == 0) continue;
        const mapped_candidates = try alloc.alloc(Candidate(Cell), sources.len);
        for (sources, mapped_candidates) |source, *mapped_candidate| {
            const mapped = try alloc.alloc(Cell, source.map.len);
            for (source.map, mapped) |pin, *cell| {
                cell.* = mapper(mapper_context, screen, pin);
            }
            mapped_candidate.* = .{
                .string = source.string,
                .mapped_len = source.mapped_len,
                .map = mapped,
            };
        }
        result.candidates[index] = mapped_candidates;
    }

    return result;
}

/// Resolve every canonical match in the prepared candidate domain.
///
/// Matchers are considered in configuration order. Every accepted match marks
/// its exact cells as occupied. A lower-priority overlapping match is rejected
/// as a whole, so it cannot claim punctuation outside a higher-priority URL.
/// All returned slices belong to the caller's short-lived operation arena.
pub fn resolveAll(
    comptime Cell: type,
    alloc: Allocator,
    prepared: Prepared(Cell),
    links: anytype,
    mouse_mods: ?input.Mods,
    seed_occupied: []const Cell,
) ![]Resolved(Cell) {
    var occupied: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer occupied.deinit(alloc);
    for (seed_occupied) |cell| try occupied.put(alloc, cell, {});

    var results: std.ArrayList(Resolved(Cell)) = .empty;
    defer results.deinit(alloc);
    errdefer for (results.items) |match| alloc.free(match.cells);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(alloc);
    var budget: SearchBudget = .{};

    for (links, 0..) |link, matcher_index| {
        if (!matcherActive(link, mouse_mods)) continue;
        const candidates = candidatesFor(Cell, prepared, link);
        for (candidates) |candidate| {
            std.debug.assert(candidate.mapped_len == candidate.map.len);
            std.debug.assert(candidate.mapped_len <= candidate.string.len);
            if (!budget.beginCandidate(candidate.string.len)) break;

            var matches = try MatchIterator.init(link.regex, candidate.string, &budget);
            defer matches.deinit();
            while (try matches.next()) |range| {
                // A match-only delimiter can be present after the mapped
                // prefix. It must never enter the target cell range.
                if (range.end > candidate.mapped_len) continue;

                cells.clearRetainingCapacity();
                try cells.ensureTotalCapacity(alloc, range.end - range.start);

                for (candidate.map[range.start..range.end]) |cell| {
                    if (cells.getLastOrNull()) |last| {
                        if (std.meta.eql(last, cell)) continue;
                    }
                    try cells.append(alloc, cell);
                }
                if (cells.items.len == 0) continue;

                var overlaps = false;
                for (cells.items) |cell| {
                    if (occupied.contains(cell)) {
                        overlaps = true;
                        break;
                    }
                }
                if (overlaps) continue;

                for (cells.items) |cell| try occupied.put(alloc, cell, {});

                try results.ensureUnusedCapacity(alloc, 1);
                const owned_cells = try alloc.dupe(Cell, cells.items);
                results.appendAssumeCapacity(.{
                    .matcher_index = matcher_index,
                    .action = link.action,
                    .value = candidate.string[range.start..range.end],
                    .cells = owned_cells,
                });
            }
        }
        if (budget.exhausted) break;
    }

    if (budget.exhausted) {
        for (results.items) |match| alloc.free(match.cells);
        return &.{};
    }
    return try results.toOwnedSlice(alloc);
}

/// Resolve all active always-highlight matches across unique visible
/// candidate domains. Matcher priority and exact-cell overlap arbitration are
/// identical to interactive resolution.
pub fn resolveVisibleAlways(
    comptime Cell: type,
    alloc: Allocator,
    prepared: VisibleCandidates(Cell),
    links: anytype,
    mouse_mods: input.Mods,
    seed_occupied: []const Cell,
) ![]Resolved(Cell) {
    var occupied: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer occupied.deinit(alloc);
    for (seed_occupied) |cell| try occupied.put(alloc, cell, {});
    var results: std.ArrayList(Resolved(Cell)) = .empty;
    defer results.deinit(alloc);
    errdefer for (results.items) |match| alloc.free(match.cells);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(alloc);
    var budget: SearchBudget = .{};

    for (links, 0..) |link, matcher_index| {
        if (!alwaysMatcherActive(link, mouse_mods)) continue;
        const candidates = prepared.candidates[@intFromEnum(candidateKey(link))];
        for (candidates) |candidate| {
            std.debug.assert(candidate.mapped_len == candidate.map.len);
            std.debug.assert(candidate.mapped_len <= candidate.string.len);
            if (!budget.beginCandidate(candidate.string.len)) break;

            var matches = try MatchIterator.init(link.regex, candidate.string, &budget);
            defer matches.deinit();
            while (try matches.next()) |range| {
                if (range.end > candidate.mapped_len) continue;

                cells.clearRetainingCapacity();
                try cells.ensureTotalCapacity(alloc, range.end - range.start);
                for (candidate.map[range.start..range.end]) |cell| {
                    if (cells.getLastOrNull()) |last| {
                        if (std.meta.eql(last, cell)) continue;
                    }
                    try cells.append(alloc, cell);
                }
                if (cells.items.len == 0) continue;

                var overlaps = false;
                for (cells.items) |cell| {
                    if (occupied.contains(cell)) {
                        overlaps = true;
                        break;
                    }
                }
                if (overlaps) continue;

                for (cells.items) |cell| try occupied.put(alloc, cell, {});
                try results.ensureUnusedCapacity(alloc, 1);
                const owned_cells = try alloc.dupe(Cell, cells.items);
                results.appendAssumeCapacity(.{
                    .matcher_index = matcher_index,
                    .action = link.action,
                    .value = candidate.string[range.start..range.end],
                    .cells = owned_cells,
                });
            }
        }
        if (budget.exhausted) break;
    }

    // Never render a prefix of the candidate set when a hostile matcher or an
    // oversized viewport exhausts the finite work budget.
    if (budget.exhausted) {
        for (results.items) |match| alloc.free(match.cells);
        return &.{};
    }
    return try results.toOwnedSlice(alloc);
}

/// Resolve the accepted match that owns the target cell.
pub fn resolveAt(
    comptime Cell: type,
    alloc: Allocator,
    prepared: Prepared(Cell),
    links: anytype,
    mouse_mods: ?input.Mods,
) !?Resolved(Cell) {
    var occupied: std.AutoHashMapUnmanaged(Cell, void) = .empty;
    defer occupied.deinit(alloc);
    var cells: std.ArrayList(Cell) = .empty;
    defer cells.deinit(alloc);
    var budget: SearchBudget = .{};

    for (links, 0..) |link, matcher_index| {
        if (!matcherActive(link, mouse_mods)) continue;
        const candidates = candidatesFor(Cell, prepared, link);
        for (candidates) |candidate| {
            std.debug.assert(candidate.mapped_len == candidate.map.len);
            std.debug.assert(candidate.mapped_len <= candidate.string.len);
            if (!budget.beginCandidate(candidate.string.len)) break;

            var matches = try MatchIterator.init(link.regex, candidate.string, &budget);
            defer matches.deinit();
            while (try matches.next()) |range| {
                if (range.end > candidate.mapped_len) continue;

                cells.clearRetainingCapacity();
                try cells.ensureTotalCapacity(alloc, range.end - range.start);
                for (candidate.map[range.start..range.end]) |cell| {
                    if (cells.getLastOrNull()) |last| {
                        if (std.meta.eql(last, cell)) continue;
                    }
                    try cells.append(alloc, cell);
                }
                if (cells.items.len == 0) continue;

                var overlaps = false;
                for (cells.items) |cell| {
                    if (occupied.contains(cell)) {
                        overlaps = true;
                        break;
                    }
                }
                if (overlaps) continue;

                var owns_target = false;
                for (cells.items) |cell| {
                    try occupied.put(alloc, cell, {});
                    owns_target = owns_target or std.meta.eql(cell, prepared.target);
                }
                if (owns_target) return .{
                    .matcher_index = matcher_index,
                    .action = link.action,
                    .value = candidate.string[range.start..range.end],
                    .cells = try alloc.dupe(Cell, cells.items),
                };
            }
        }
        if (budget.exhausted) break;
    }
    return null;
}

pub const MatchRange = struct {
    start: usize,
    end: usize,
};

const oni_search_retry_limit = 10_000;
const max_search_calls = 2 * 1024;
const max_candidate_bytes = 1024 * 1024;

/// Shared finite work budget for one link resolution or renderer scan.
pub const SearchBudget = struct {
    searches_remaining: usize = max_search_calls,
    candidate_bytes_remaining: usize = max_candidate_bytes,
    exhausted: bool = false,

    pub fn beginCandidate(self: *SearchBudget, len: usize) bool {
        if (self.exhausted) return false;
        if (len > self.candidate_bytes_remaining) {
            self.exhausted = true;
            return false;
        }
        self.candidate_bytes_remaining -= len;
        return true;
    }

    fn beginSearch(self: *SearchBudget) bool {
        if (self.searches_remaining == 0) {
            self.exhausted = true;
            return false;
        }
        self.searches_remaining -= 1;
        return true;
    }

    fn exhaust(self: *SearchBudget) void {
        self.exhausted = true;
        self.searches_remaining = 0;
    }
};

pub const MatchIterator = struct {
    regex: oni.Regex,
    string: []const u8,
    offset: usize = 0,
    budget: *SearchBudget,
    match_param: oni.MatchParam,
    region: oni.Region = .{},

    pub fn init(
        regex: oni.Regex,
        string: []const u8,
        budget: *SearchBudget,
    ) !MatchIterator {
        var match_param = try oni.MatchParam.init();
        errdefer match_param.deinit();
        try match_param.setRetryLimitInSearch(oni_search_retry_limit);
        return .{
            .regex = regex,
            .string = string,
            .budget = budget,
            .match_param = match_param,
        };
    }

    pub fn deinit(self: *MatchIterator) void {
        self.region.deinit();
        self.match_param.deinit();
    }

    pub fn next(self: *MatchIterator) !?MatchRange {
        if (self.offset >= self.string.len) return null;
        if (!self.budget.beginSearch()) {
            self.offset = self.string.len;
            return null;
        }

        _ = self.regex.searchAdvancedWithParam(
            self.string,
            self.offset,
            self.string.len,
            &self.region,
            .{ .find_not_empty = true },
            &self.match_param,
        ) catch |err| switch (err) {
            error.Mismatch => {
                self.offset = self.string.len;
                return null;
            },
            error.RetryLimitInMatchOver,
            error.RetryLimitInSearchOver,
            error.MatchStackLimitOver,
            error.SubexpCallLimitInSearchOver,
            => {
                self.budget.exhaust();
                self.offset = self.string.len;
                return null;
            },
            else => return err,
        };

        const start: usize = @intCast(self.region.starts()[0]);
        const end: usize = @intCast(self.region.ends()[0]);
        if (end <= start or end <= self.offset) {
            // `find_not_empty` should make this impossible. Keep a defensive
            // stop so malformed engine output can never spin the renderer.
            self.offset = self.string.len;
            return null;
        }

        self.offset = end;
        return .{ .start = start, .end = end };
    }
};

fn candidateSelectionForKey(
    screen: *terminal.Screen,
    target: terminal.Pin,
    key: CandidateKey,
    budget: *PreparationBudget,
) CandidateReadError!?terminal.Selection {
    const scope = candidateScope(key);
    const base = try candidateSelection(screen, target, scope, budget) orelse return null;
    if (candidateNormalizesHardWraps(key)) {
        return try expandHardWrappedSelection(screen, base, scope, budget);
    }
    _ = try selectionCost(screen, base) orelse return null;
    return base;
}

fn candidateMapForSelection(
    alloc: Allocator,
    screen: *terminal.Screen,
    selection: terminal.Selection,
    key: CandidateKey,
    max_bytes: usize,
) !?Candidate(terminal.Pin) {
    const normalize_hard_wraps = candidateNormalizesHardWraps(key);

    // Reserve the synthetic delimiter up front. A no-allocation counting pass
    // rejects a cell with unusually large grapheme data before it can allocate
    // or copy past the shared candidate byte budget while the terminal is
    // locked. The mapped pass then allocates exactly the measured size, which
    // matters because runtime callers use an arena that cannot reclaim an
    // oversized per-candidate reservation.
    const delimiter_bytes: usize = if (candidateUsesDelimiter(key)) 1 else 0;
    if (max_bytes <= delimiter_bytes) return null;
    const output_limit = max_bytes - delimiter_bytes;

    // Internal candidates are already terminal-forward. Drive the PageList
    // formatter with those ordered endpoints directly, avoiding Selection's
    // full-scrollback ordering walk and selectionString's duplicate text.
    var formatter: terminal.formatter.PageListFormatter = .init(
        &screen.pages,
        .{ .emit = .plain, .unwrap = true, .trim = false },
    );
    formatter.top_left = selection.start();
    formatter.bottom_right = selection.end();

    var count_buffer: [256]u8 = undefined;
    var counter: CappedCountingWriter = .init(&count_buffer, output_limit);
    formatter.format(&counter.writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return null,
    };
    const output_len = counter.fullCount() orelse return null;
    if (output_len > output_limit) return null;

    var storage = try alloc.alloc(u8, output_len + 1);
    errdefer alloc.free(storage);
    var writer = std.Io.Writer.fixed(storage[0..output_len]);
    var pins: std.ArrayList(terminal.Pin) = .empty;
    defer pins.deinit(alloc);
    formatter.pin_map = .{ .alloc = alloc, .map = &pins };
    formatter.format(&writer) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return null,
    };

    std.debug.assert(writer.end == output_len);
    storage[output_len] = 0;
    const string: [:0]u8 = storage[0..output_len :0];
    const map = try pins.toOwnedSlice(alloc);
    errdefer alloc.free(map);
    if (!normalize_hard_wraps) return .{
        .string = string,
        .mapped_len = map.len,
        .map = map,
    };

    const normalized = try link_wrap.normalize(
        terminal.Pin,
        alloc,
        string,
        map,
        .{ .terminate_joined = candidateUsesDelimiter(key) },
    );
    alloc.free(string);
    alloc.free(map);
    return .{
        .string = normalized.string,
        .mapped_len = normalized.mapped_len,
        .map = normalized.map,
    };
}

fn expandHardWrappedSelection(
    screen: *terminal.Screen,
    selection: terminal.Selection,
    candidate_scope: input.Link.CandidateScope,
    budget: *PreparationBudget,
) CandidateReadError!?terminal.Selection {
    var start = selection.start();
    var end = selection.end();
    var cost = try selectionCost(screen, selection) orelse return null;

    // Walk to the beginning of the complete join-connected component. A
    // connected neighbor that would exceed the shared budget rejects the
    // candidate instead of returning a target-dependent truncated match.
    while (try previousCandidate(screen, start, candidate_scope, budget)) |adjacent| {
        const adjacent_end = adjacent.end();
        if (!try hardWrapBoundary(adjacent_end, start)) break;
        const adjacent_cost = try selectionCost(screen, adjacent) orelse return null;
        if (!cost.add(adjacent_cost)) return null;
        start = adjacent.start();
    }

    // Walk independently to the end. Expansion order cannot affect the
    // result: any connected component that exceeds the budget is rejected.
    while (try nextCandidate(screen, end, candidate_scope, budget)) |adjacent| {
        const adjacent_start = adjacent.start();
        if (!try hardWrapBoundary(end, adjacent_start)) break;
        const adjacent_cost = try selectionCost(screen, adjacent) orelse return null;
        if (!cost.add(adjacent_cost)) return null;
        end = adjacent.end();
    }

    return .init(start, end, false);
}

fn previousCandidate(
    screen: *terminal.Screen,
    start: terminal.Pin,
    candidate_scope: input.Link.CandidateScope,
    budget: *PreparationBudget,
) CandidateReadError!?terminal.Selection {
    // A semantic boundary inside a physical row is never a prose line break.
    if (start.x != 0) return null;
    var previous = start.up(1) orelse return null;
    const page = previous.node.pageIfResident() orelse
        return error.NonResidentPage;
    if (page.getRow(previous.y).wrap) return null;
    previous.x = 0;
    return try candidateSelection(screen, previous, candidate_scope, budget);
}

fn nextCandidate(
    screen: *terminal.Screen,
    end: terminal.Pin,
    candidate_scope: input.Link.CandidateScope,
    budget: *PreparationBudget,
) CandidateReadError!?terminal.Selection {
    // A semantic boundary inside a physical row is never a prose line break.
    if (end.x + 1 != end.node.cols()) return null;
    const page = end.node.pageIfResident() orelse return error.NonResidentPage;
    if (page.getRow(end.y).wrap) return null;
    var next = end.down(1) orelse return null;
    if (next.node.pageIfResident() == null) return error.NonResidentPage;
    next.x = 0;
    return try candidateSelection(screen, next, candidate_scope, budget);
}

/// Check a boundary directly from terminal cells. This avoids allocating an
/// oversized neighboring line merely to discover that it is unrelated.
fn hardWrapBoundary(
    upper_end: terminal.Pin,
    lower_start: terminal.Pin,
) CandidateReadError!bool {
    if (upper_end.x + 1 != upper_end.node.cols()) return false;
    if (lower_start.x != 0) return false;
    const upper_page = upper_end.node.pageIfResident() orelse
        return error.NonResidentPage;
    const lower_page = lower_start.node.pageIfResident() orelse
        return error.NonResidentPage;
    const upper_rac = upper_page.getRowAndCell(upper_end.x, upper_end.y);
    if (upper_rac.row.wrap) return false;

    const upper_cells = upper_page.getCells(upper_rac.row);
    var upper_x: usize = upper_end.x + 1;
    const before: u21 = while (upper_x > 0) {
        upper_x -= 1;
        const cp = upper_cells[upper_x].codepoint();
        if (cp != 0 and cp != '\r') break cp;
    } else return false;

    const semantic = upper_cells[upper_x].semantic_content;

    const lower_cells = lower_page.getCells(lower_page.getRow(lower_start.y));
    var lower_x: usize = lower_start.x;
    var indentation: usize = 0;
    while (lower_x < lower_cells.len) : (lower_x += 1) {
        const cell = lower_cells[lower_x];
        // A real newline is only prose continuation inside one semantic
        // region. Soft wraps may legitimately straddle shell metadata, but a
        // hard newline entering a new prompt or command must never join.
        if (cell.semantic_content != semantic) return false;
        const cp = cell.codepoint();
        if (cp == ' ' or cp == '\t') {
            indentation += 1;
            continue;
        }
        if (!link_wrap.canJoinCodepoints(before, indentation, cp)) return false;

        // Probe a bounded UTF-8 prefix without allocating under the terminal
        // lock. Filling the probe is ambiguous, so fail closed rather than
        // joining a token whose independent prefix we could not disprove.
        var prefix: [256]u8 = undefined;
        var prefix_len: usize = 0;
        for (lower_cells[lower_x..]) |prefix_cell| {
            switch (prefix_cell.wide) {
                .spacer_head, .spacer_tail => continue,
                .narrow, .wide => {},
            }
            const prefix_cp = prefix_cell.codepoint();
            if (prefix_cp == 0) break;
            if (prefix_cell.semantic_content != semantic) return false;
            var encoded: [4]u8 = undefined;
            const encoded_len = std.unicode.utf8Encode(
                prefix_cp,
                &encoded,
            ) catch return false;
            if (encoded_len > prefix.len - prefix_len) return false;
            @memcpy(
                prefix[prefix_len..][0..encoded_len],
                encoded[0..encoded_len],
            );
            prefix_len += encoded_len;
        }
        return !link_wrap.startsIndependentLink(
            prefix[0..prefix_len],
            before,
        );
    }
    return false;
}

const SelectionCost = struct {
    rows: usize,
    cells: usize,

    fn add(self: *SelectionCost, other: SelectionCost) bool {
        if (other.rows > max_logical_candidate_rows - self.rows or
            other.cells > max_logical_candidate_cells - self.cells)
        {
            return false;
        }
        self.rows += other.rows;
        self.cells += other.cells;
        return true;
    }
};

fn selectionCost(
    screen: *terminal.Screen,
    selection: terminal.Selection,
) CandidateReadError!?SelectionCost {
    _ = screen;
    const top = selection.start();
    const bottom = selection.end();
    var result: SelectionCost = .{ .rows = 0, .cells = 0 };
    var it = top.rowIterator(.right_down, bottom);
    while (it.next()) |row_pin| {
        if (row_pin.node.pageIfResident() == null) return error.NonResidentPage;
        if (result.rows == max_logical_candidate_rows) return null;
        result.rows += 1;

        const start_x: usize = if (row_pin.node == top.node and row_pin.y == top.y)
            top.x
        else
            0;
        const end_x: usize = if (row_pin.node == bottom.node and row_pin.y == bottom.y)
            bottom.x
        else
            row_pin.node.cols() - 1;
        const row_cells = end_x - start_x + 1;
        if (row_cells > max_logical_candidate_cells - result.cells) return null;
        result.cells += row_cells;
    }
    return result;
}

fn candidateSelection(
    screen: *terminal.Screen,
    pin: terminal.Pin,
    candidate_scope: input.Link.CandidateScope,
    budget: *PreparationBudget,
) CandidateReadError!?terminal.Selection {
    return switch (candidate_scope) {
        .semantic => semantic: {
            // selectLine scans the complete soft-wrapped line before finding
            // semantic boundaries, so preflight the same physical domain.
            _ = try boundedLogicalLineChecked(pin, budget) orelse break :semantic null;
            break :semantic screen.selectLine(.{
                .pin = pin,
                .whitespace = null,
                .semantic_prompt_boundary = true,
            });
        },
        .bounded_logical => try boundedLogicalLineChecked(pin, budget),
    };
}

pub const max_logical_candidate_cells = 8 * 1024;
pub const max_logical_candidate_rows = 256;

/// Return a complete soft-wrapped logical line within a fixed work budget.
pub fn boundedLogicalLine(pin: terminal.Pin) ?terminal.Selection {
    return boundedLogicalLineChecked(pin, null) catch null;
}

fn boundedLogicalLineChecked(
    pin: terminal.Pin,
    budget: ?*PreparationBudget,
) CandidateReadError!?terminal.Selection {
    const initial_cols: usize = pin.node.cols();
    if (initial_cols == 0 or initial_cols > max_logical_candidate_cells) return null;
    if (pin.node.pageIfResident() == null) return error.NonResidentPage;
    if (budget) |value| if (!value.probeCells(initial_cols)) return null;

    var rows: usize = 1;
    var remaining_cells = max_logical_candidate_cells - initial_cols;
    var start = pin;
    start.x = 0;
    while (start.up(1)) |previous| {
        const previous_page = previous.node.pageIfResident() orelse
            return error.NonResidentPage;
        if (!previous_page.getRow(previous.y).wrap) break;
        if (rows == max_logical_candidate_rows) return null;

        const previous_cols: usize = previous.node.cols();
        if (budget) |value| if (!value.probeCells(previous_cols)) return null;
        if (previous_cols == 0 or previous_cols > remaining_cells) return null;
        remaining_cells -= previous_cols;
        start = previous;
        start.x = 0;
        rows += 1;
    }

    var end = pin;
    end.x = @intCast(initial_cols - 1);
    while (true) {
        const end_page = end.node.pageIfResident() orelse
            return error.NonResidentPage;
        if (!end_page.getRow(end.y).wrap) break;
        if (rows == max_logical_candidate_rows) return null;

        const next = end.down(1) orelse return null;
        if (next.node.pageIfResident() == null) return error.NonResidentPage;
        const next_cols: usize = next.node.cols();
        if (budget) |value| if (!value.probeCells(next_cols)) return null;
        if (next_cols == 0 or next_cols > remaining_cells) return null;
        remaining_cells -= next_cols;
        end = next;
        end.x = @intCast(next_cols - 1);
        rows += 1;
    }

    return .init(start, end, false);
}

test "link preparation never restores a compressed adjacent page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();

    const pages = &t.screens.active.pages;
    const first_page_rows = pages.pages.first.?.capacity().rows;
    for (0..first_page_rows + 24) |_| stream.nextSlice("history\r\n");
    _ = pages.compress(.full);

    const target_node = pages.getTopLeft(.active).node;
    const previous = target_node.prev orelse return error.TestExpectedEqual;
    try testing.expectEqual(.compressed, previous.storage());
    const target: terminal.Pin = .{ .node = target_node, .x = 0, .y = 0 };

    // Detecting a logical line across this boundary fails closed. The probe
    // must not call Node.page(), which would permanently restore history.
    try testing.expect(boundedLogicalLine(target) == null);
    try testing.expectEqual(.compressed, previous.storage());

    var regex = try oni.Regex.init(
        "history",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer regex.deinit();
    const TestLink = struct {
        regex: oni.Regex,
        action: input.Link.Action = .{ .open = {} },
        highlight: input.Link.Highlight = .hover,
        candidate_scope: input.Link.CandidateScope = .bounded_logical,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const prepared = try prepareAt(
        arena.allocator(),
        t.screens.active,
        &[_]TestLink{.{ .regex = regex }},
        target,
        null,
    );
    for (prepared.candidates) |candidates| try testing.expectEqual(0, candidates.len);
    try testing.expectEqual(.compressed, previous.storage());
}

test "candidate formatting stops at its byte budget" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 16, .rows = 1 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("abcdef");

    const screen = t.screens.active;
    const start = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const end = screen.pages.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const selection: terminal.Selection = .init(start, end, false);

    try testing.expect((try candidateMapForSelection(
        alloc,
        screen,
        selection,
        .semantic,
        5,
    )) == null);

    const exact = (try candidateMapForSelection(
        alloc,
        screen,
        selection,
        .semantic,
        6,
    )) orelse return error.TestExpectedEqual;
    defer {
        alloc.free(exact.string);
        alloc.free(exact.map);
    }
    try testing.expectEqualStrings("abcdef", exact.string);
    try testing.expectEqual(exact.string.len, exact.mapped_len);
    try testing.expectEqual(exact.mapped_len, exact.map.len);
}

test "capped counting writer aborts when output crosses its limit" {
    const testing = std.testing;

    var overflow_buffer: [4]u8 = undefined;
    var overflow: CappedCountingWriter = .init(&overflow_buffer, 5);
    try testing.expectError(
        error.WriteFailed,
        overflow.writer.writeAll("abcdef"),
    );
    try testing.expect(overflow.fullCount().? <= 5);

    var exact_buffer: [4]u8 = undefined;
    var exact: CappedCountingWriter = .init(&exact_buffer, 6);
    try exact.writer.writeAll("abcdef");
    try testing.expectEqual(@as(usize, 6), exact.fullCount().?);
}

test "hard-wrap continuation rejects a later semantic transition" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 40, .rows = 2 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();

    t.screens.active.cursorSetSemanticContent(.output);
    stream.nextSlice("https://example.com/a-");
    stream.nextSlice("\r\n    continu");
    t.screens.active.cursorSetSemanticContent(.{ .input = .clear_explicit });
    stream.nextSlice("ation");

    const upper_end = t.screens.active.pages.pin(.{ .active = .{
        .x = 39,
        .y = 0,
    } }).?;
    const lower_start = t.screens.active.pages.pin(.{ .active = .{
        .x = 0,
        .y = 1,
    } }).?;
    try testing.expect(!try hardWrapBoundary(upper_end, lower_start));
}

test "visible preparation discards partial domains at the probe-cell limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Every semantic candidate first scans its complete logical line. Keep
    // the number of candidates below the attempt cap while making their
    // aggregate probes exceed the independent cell-work budget.
    const cols = 400;
    comptime {
        std.debug.assert(cols < max_candidate_attempts);
        std.debug.assert(cols * cols > max_visible_candidate_cells);
    }

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = 1 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..cols) |index| {
        t.screens.active.cursorSetSemanticContent(if (index % 2 == 0)
            .output
        else
            .{ .input = .clear_explicit });
        stream.nextSlice("a");
    }

    const TestLink = struct {
        highlight: input.Link.Highlight = .always,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    var prepared = try prepareVisibleAlways(
        terminal.Pin,
        alloc,
        t.screens.active,
        &[_]TestLink{.{}},
        .{},
        {},
        identityPin,
    );
    defer prepared.deinit(alloc);
    for (prepared.candidates) |candidates| try testing.expectEqual(0, candidates.len);
}

test "always preparation has a dedicated per-frame probe-cell limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Every semantic candidate first scans its complete logical line. Keep
    // the number of candidates below the attempt cap while making aggregate
    // probes exceed the 16K per-frame cap but not the 128K interactive cap.
    const cols = 200;
    comptime {
        std.debug.assert(cols < max_candidate_attempts);
        std.debug.assert(cols * cols > 16 * 1024);
        std.debug.assert(cols * cols < max_visible_candidate_cells);
    }

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = cols, .rows = 1 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..cols) |index| {
        t.screens.active.cursorSetSemanticContent(if (index % 2 == 0)
            .output
        else
            .{ .input = .clear_explicit });
        stream.nextSlice("a");
    }

    const TestLink = struct {
        highlight: input.Link.Highlight = .always,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    var prepared = try prepareVisibleAlways(
        terminal.Pin,
        alloc,
        t.screens.active,
        &[_]TestLink{.{}},
        .{},
        {},
        identityPin,
    );
    defer prepared.deinit(alloc);
    for (prepared.candidates) |candidates| try testing.expectEqual(0, candidates.len);
}

test "visible preparation discards partial domains at the attempt limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const rows = max_candidate_attempts + 1;

    var t: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 1, .rows = rows });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    for (0..rows) |row| {
        stream.nextSlice("a");
        if (row + 1 < rows) stream.nextSlice("\r\n");
    }

    const TestLink = struct {
        highlight: input.Link.Highlight = .always,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    var prepared = try prepareVisibleAlways(
        terminal.Pin,
        alloc,
        t.screens.active,
        &[_]TestLink{.{}},
        .{},
        {},
        identityPin,
    );
    defer prepared.deinit(alloc);
    for (prepared.candidates) |candidates| try testing.expectEqual(0, candidates.len);
}

test "resolveAt preserves matcher priority outside the winning match" {
    const testing = std.testing;
    try oni.testing.ensureInit();

    var scheme_regex = try oni.Regex.init(
        "https://example\\.com",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer scheme_regex.deinit();
    var path_regex = try oni.Regex.init(
        "[[:alnum:]/:.-]+",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer path_regex.deinit();

    const TestLink = struct {
        regex: oni.Regex,
        action: input.Link.Action = .{ .open = {} },
        highlight: input.Link.Highlight = .hover,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    const links = [_]TestLink{
        .{ .regex = scheme_regex },
        .{ .regex = path_regex },
    };

    const string: [:0]const u8 = "https://example.com.";
    var map: [string.len]usize = undefined;
    for (&map, 0..) |*cell, index| cell.* = index;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var prepared: Prepared(usize) = .{
        .target = 8,
    };
    prepared.candidates[@intFromEnum(CandidateKey.semantic)] = &.{.{
        .string = string,
        .mapped_len = map.len,
        .map = &map,
    }};

    const inside = (try resolveAt(
        usize,
        alloc,
        prepared,
        &links,
        null,
    )) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(usize, 0), inside.matcher_index);
    try testing.expectEqualStrings("https://example.com", inside.value);
    try testing.expectEqual(@as(usize, 19), inside.cells.len);

    prepared.target = string.len - 1;
    try testing.expect((try resolveAt(
        usize,
        alloc,
        prepared,
        &links,
        null,
    )) == null);
}

test "resolveAt skips empty alternatives and rejects synthetic match bytes" {
    const testing = std.testing;
    try oni.testing.ensureInit();

    const TestLink = struct {
        regex: oni.Regex,
        action: input.Link.Action = .{ .open = {} },
        highlight: input.Link.Highlight = .hover,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var nonempty_regex = try oni.Regex.init(
        "(?:|https://example\\.com)",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer nonempty_regex.deinit();
    const string: [:0]const u8 = "https://example.com";
    var map: [string.len]usize = undefined;
    for (&map, 0..) |*cell, index| cell.* = index;
    const links = [_]TestLink{.{ .regex = nonempty_regex }};
    var prepared: Prepared(usize) = .{ .target = 8 };
    prepared.candidates[@intFromEnum(CandidateKey.semantic)] = &.{.{
        .string = string,
        .mapped_len = map.len,
        .map = &map,
    }};
    const resolved = (try resolveAt(
        usize,
        alloc,
        prepared,
        &links,
        null,
    )) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings(string, resolved.value);

    var terminator_regex = try oni.Regex.init(
        "/tmp/build\\.\\x00",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer terminator_regex.deinit();
    const terminated: [:0]const u8 = "/tmp/build.\x00";
    var terminated_map: [terminated.len - 1]usize = undefined;
    for (&terminated_map, 0..) |*cell, index| cell.* = index;
    const terminated_links = [_]TestLink{.{ .regex = terminator_regex }};
    prepared = .{ .target = 3 };
    prepared.candidates[@intFromEnum(CandidateKey.semantic)] = &.{.{
        .string = terminated,
        .mapped_len = terminated_map.len,
        .map = &terminated_map,
    }};
    try testing.expect((try resolveAt(
        usize,
        alloc,
        prepared,
        &terminated_links,
        null,
    )) == null);
}

test "resolveAt maps multibyte text to one terminal cell" {
    const testing = std.testing;
    try oni.testing.ensureInit();

    var regex = try oni.Regex.init(
        "https://x/日",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer regex.deinit();
    const TestLink = struct {
        regex: oni.Regex,
        action: input.Link.Action = .{ .open = {} },
        highlight: input.Link.Highlight = .hover,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    const links = [_]TestLink{.{ .regex = regex }};

    const string: [:0]const u8 = "https://x/日";
    const ascii_len = "https://x/".len;
    var map: [string.len]usize = undefined;
    for (&map, 0..) |*cell, index| {
        cell.* = if (index < ascii_len) index else ascii_len;
    }
    var prepared: Prepared(usize) = .{ .target = ascii_len };
    prepared.candidates[@intFromEnum(CandidateKey.semantic)] = &.{.{
        .string = string,
        .mapped_len = map.len,
        .map = &map,
    }};

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const resolved = (try resolveAt(
        usize,
        arena.allocator(),
        prepared,
        &links,
        null,
    )) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings(string, resolved.value);
    try testing.expectEqual(ascii_len + 1, resolved.cells.len);
    try testing.expectEqual(ascii_len, resolved.cells[resolved.cells.len - 1]);
}

test "MatchIterator stops without returning a partial unbounded scan" {
    const testing = std.testing;
    try oni.testing.ensureInit();
    var regex = try oni.Regex.init(
        "a",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer regex.deinit();

    var budget: SearchBudget = .{ .searches_remaining = 2 };
    try testing.expect(budget.beginCandidate(3));
    var matches = try MatchIterator.init(regex, "aaa", &budget);
    defer matches.deinit();
    try testing.expectEqual(MatchRange{ .start = 0, .end = 1 }, (try matches.next()).?);
    try testing.expectEqual(MatchRange{ .start = 1, .end = 2 }, (try matches.next()).?);
    try testing.expect((try matches.next()) == null);
    try testing.expect(budget.exhausted);
}

test "resolvers discard partial results when the search budget is exhausted" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    const len = max_search_calls + 1;
    const string = try alloc.allocSentinel(u8, len, 0);
    defer alloc.free(string);
    @memset(string, 'a');
    const map = try alloc.alloc(usize, len);
    defer alloc.free(map);
    for (map, 0..) |*cell, index| cell.* = index;

    var each = try oni.Regex.init(
        "a",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer each.deinit();
    var final = try oni.Regex.init(
        "a\\z",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer final.deinit();
    const TestLink = struct {
        regex: oni.Regex,
        action: input.Link.Action = .{ .open = {} },
        highlight: input.Link.Highlight = .hover,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    const links = [_]TestLink{
        .{ .regex = each },
        .{ .regex = final },
    };
    const prepared: Prepared(usize) = .{
        .target = len - 1,
        .candidates = candidate: {
            var candidates: [candidate_key_count][]const Candidate(usize) =
                [_][]const Candidate(usize){&.{}} ** candidate_key_count;
            candidates[@intFromEnum(CandidateKey.semantic)] = &.{.{
                .string = string,
                .mapped_len = map.len,
                .map = map,
            }};
            break :candidate candidates;
        },
    };

    const all = try resolveAll(usize, alloc, prepared, &links, null, &.{});
    try testing.expectEqual(@as(usize, 0), all.len);
    try testing.expect((try resolveAt(usize, alloc, prepared, &links, null)) == null);

    const AlwaysLink = struct {
        regex: oni.Regex,
        action: input.Link.Action = .{ .open = {} },
        highlight: input.Link.Highlight = .always,
        candidate_scope: input.Link.CandidateScope = .semantic,
        hard_wrap_continuations: bool = false,
        hard_wrap_match_delimiter: bool = false,
    };
    const always_links = [_]AlwaysLink{
        .{ .regex = each },
        .{ .regex = final },
    };
    var visible: VisibleCandidates(usize) = .{};
    visible.candidates = prepared.candidates;
    const visible_all = try resolveVisibleAlways(
        usize,
        alloc,
        visible,
        &always_links,
        .{},
        &.{},
    );
    try testing.expectEqual(@as(usize, 0), visible_all.len);
}

test "default scheme regex handles a near-limit URL ending in punctuation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try oni.testing.ensureInit();

    const prefix = "https://";
    const len = max_logical_candidate_cells;
    const value = try alloc.allocSentinel(u8, len, 0);
    defer alloc.free(value);
    @memcpy(value[0..prefix.len], prefix);
    @memset(value[prefix.len .. value.len - 1], 'a');
    value[value.len - 1] = '.';

    var regex = try oni.Regex.init(
        @import("config/url.zig").scheme_regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer regex.deinit();

    var budget: SearchBudget = .{};
    try testing.expect(budget.beginCandidate(value.len));
    var matches = try MatchIterator.init(regex, value, &budget);
    defer matches.deinit();
    try testing.expectEqual(
        MatchRange{ .start = 0, .end = value.len - 1 },
        (try matches.next()) orelse return error.TestExpectedEqual,
    );
    try testing.expect(!budget.exhausted);
}
