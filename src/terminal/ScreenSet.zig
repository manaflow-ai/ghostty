/// A ScreenSet holds multiple terminal screens. This is initially created
/// to handle simple primary vs alternate screens, but could be extended
/// in the future to handle N screens.
///
/// One of the goals of this is to allow lazy initialization of screens
/// as needed. The primary screen is always initialized, but the alternate
/// screen may not be until first used.
const ScreenSet = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const lib = @import("lib.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");

/// The possible keys for screens in the screen set.
pub const Key = lib.Enum(lib.target, &.{
    "primary",
    "alternate",
});

/// The key value of the currently active screen. Useful for simple
/// comparisons, e.g. "is this screen the primary screen".
active_key: Key,

/// The active screen pointer.
active: *Screen,

/// All screens that are initialized.
all: std.EnumMap(Key, *Screen),

/// Monotonic generation counter for each screen key. This changes whenever a
/// screen is removed so external handles can distinguish a newly initialized
/// screen from stale references into destroyed screen storage.
generations: std.EnumMap(Key, usize),

/// Lock-free epoch shared by every screen in this terminal. This lets the
/// renderer observe selection changes without acquiring the terminal mutex.
selection_activity: *std.atomic.Value(u64),

pub fn init(
    alloc: Allocator,
    opts: Screen.Options,
) Allocator.Error!ScreenSet {
    const selection_activity = try alloc.create(std.atomic.Value(u64));
    errdefer alloc.destroy(selection_activity);
    selection_activity.* = .init(0);

    // We need to initialize our initial primary screen
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    var screen_opts = opts;
    screen_opts.selection_activity_shared = selection_activity;
    screen.* = try .init(alloc, screen_opts);
    return .{
        .active_key = .primary,
        .active = screen,
        .all = .init(.{ .primary = screen }),
        .generations = .initFull(0),
        .selection_activity = selection_activity,
    };
}

pub fn deinit(self: *ScreenSet, alloc: Allocator) void {
    // Destroy all initialized screens
    var it = self.all.iterator();
    while (it.next()) |entry| {
        entry.value.*.deinit();
        alloc.destroy(entry.value.*);
    }
    alloc.destroy(self.selection_activity);
}

/// Get the screen for the given key, if it is initialized.
pub fn get(self: *const ScreenSet, key: Key) ?*Screen {
    return self.all.get(key);
}

/// Get the current generation for the given screen key.
pub fn generation(self: *const ScreenSet, key: Key) usize {
    return self.generations.get(key).?;
}

/// Get the screen for the given key, initializing it if necessary.
pub fn getInit(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
    opts: Screen.Options,
) Allocator.Error!*Screen {
    if (self.get(key)) |screen| return screen;
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    var screen_opts = opts;
    screen_opts.selection_activity_shared = self.selection_activity;
    screen.* = try .init(alloc, screen_opts);
    self.all.put(key, screen);
    return screen;
}

/// Remove a key from the set. The primary screen cannot be removed (asserted).
pub fn remove(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
) void {
    assert(key != .primary);
    if (self.all.fetchRemove(key)) |screen| {
        self.generations.put(key, self.generation(key) +% 1);
        screen.deinit();
        alloc.destroy(screen);
    }
}

/// Switch the active screen to the given key. Requires that the
/// screen is initialized.
pub fn switchTo(self: *ScreenSet, key: Key) void {
    const changed = self.active_key != key;
    self.active_key = key;
    self.active = self.all.get(key).?;
    if (changed) _ = self.selection_activity.fetchAdd(1, .release);
}

test ScreenSet {
    const alloc = testing.allocator;
    var set: ScreenSet = try .init(alloc, .default);
    defer set.deinit(alloc);
    try testing.expectEqual(.primary, set.active_key);
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    // Initialize a secondary screen
    _ = try set.getInit(alloc, .alternate, .default);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    set.switchTo(.alternate);
    try testing.expectEqual(.alternate, set.active_key);
}

test "ScreenSet generations" {
    const alloc = testing.allocator;
    var set: ScreenSet = try .init(alloc, .default);
    defer set.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    // A no-op removal doesn't change the generation.
    set.remove(alloc, .alternate);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    // Initializing a screen doesn't change the generation.
    _ = try set.getInit(alloc, .alternate, .default);
    try testing.expectEqual(@as(usize, 0), set.generation(.alternate));

    const alternate_generation = set.generation(.alternate);
    set.remove(alloc, .alternate);
    try testing.expectEqual(alternate_generation +% 1, set.generation(.alternate));

    // Reinitializing keeps the generation from the last removal, so stale
    // handles can distinguish the new screen from the destroyed screen.
    _ = try set.getInit(alloc, .alternate, .default);
    try testing.expectEqual(alternate_generation +% 1, set.generation(.alternate));
    try testing.expectEqual(@as(usize, 0), set.generation(.primary));
}
