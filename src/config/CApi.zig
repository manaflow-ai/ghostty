const builtin = @import("builtin");
const std = @import("std");
const cli = @import("../cli.zig");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Config = @import("Config.zig");
const FileFormatter = @import("formatter_file.zig").FileFormatter;
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
pub export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

pub export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

fn configHandle(ptr: ?*Config, comptime api_name: []const u8) ?*Config {
    return ptr orelse {
        log.warn("{s} called with null config", .{api_name});
        return null;
    };
}

fn bytesForLength(ptr: ?[*]const u8, len: usize, comptime api_name: []const u8) ?[]const u8 {
    if (len == 0) return "";

    const raw = ptr orelse {
        log.warn("{s} called with null pointer and non-zero length", .{api_name});
        return null;
    };

    return raw[0..len];
}

/// Deep clone the configuration.
pub export fn ghostty_config_clone(self_: ?*Config) ?*Config {
    const self = configHandle(self_, "ghostty_config_clone") orelse return null;
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Serialize every public effective configuration value using Ghostty's
/// config-file formatter. The returned allocation is owned by the caller and
/// is released by ghostty_string_free.
export fn ghostty_config_serialize(self: *const Config) String {
    const serialized = serializeConfig(global.alloc(), self) catch |err| {
        log.err("error serializing config err={}", .{err});
        return .empty;
    };
    return .fromSlice(serialized);
}

fn serializeConfig(alloc: std.mem.Allocator, self: *const Config) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    // Config.default preloads command-palette entries, while parsing that key
    // appends. Clear it before the all-values formatter emits the effective
    // entries so loading this snapshot into a fresh config is lossless.
    try output.writer.writeAll("command-palette-entry = clear\n");

    const formatter: FileFormatter = .{
        .alloc = alloc,
        .config = self,
        .docs = false,
        .changed = false,
    };
    try formatter.format(&output.writer);
    return try output.toOwnedSlice();
}

/// Load the configuration from the CLI args.
pub fn ghostty_config_load_cli_args(self_: ?*Config) callconv(.c) bool {
    const self = configHandle(self_, "ghostty_config_load_cli_args") orelse return false;
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
        return false;
    };
    return true;
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
pub fn ghostty_config_load_default_files(self_: ?*Config) callconv(.c) bool {
    const self = configHandle(self_, "ghostty_config_load_default_files") orelse return false;
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
        return false;
    };
    return true;
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
pub fn ghostty_config_load_file(self_: ?*Config, path_: ?[*:0]const u8) callconv(.c) bool {
    const self = configHandle(self_, "ghostty_config_load_file") orelse return false;
    const path = path_ orelse {
        log.warn("ghostty_config_load_file called with null path", .{});
        return false;
    };
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
        return false;
    };
    return true;
}

/// Load the configuration from an in-memory string in the same format as
/// a Ghostty config file. The buffer does not need to be null-terminated.
pub fn ghostty_config_load_string(
    self_: ?*Config,
    str_: ?[*]const u8,
    len: usize,
) callconv(.c) bool {
    const self = configHandle(self_, "ghostty_config_load_string") orelse return false;
    const str = bytesForLength(str_, len, "ghostty_config_load_string") orelse return false;

    var reader: std.Io.Reader = .fixed(str);
    var iter: cli.args.LineIterator = .{
        .r = &reader,
        .filepath = "<ghostty_config_load_string>",
    };
    self.loadIter(global.alloc(), &iter) catch |err| {
        log.err("error loading config from string err={}", .{err});
        return false;
    };
    return true;
}

/// Load the configuration from in-memory contents.
/// The path is only used as a synthetic source path for diagnostics and
/// relative path expansion.
fn ghostty_config_load_string_non_linux(
    self: *Config,
    contents: [*]const u8,
    contents_len: usize,
    path: [*:0]const u8,
) callconv(.c) void {
    const contents_slice = contents[0..contents_len];
    const path_slice = std.mem.span(path);
    self.loadString(global.alloc(), contents_slice, path_slice) catch |err| {
        log.err("error loading config from string path={s} err={}", .{ path_slice, err });
    };
}

fn ghostty_config_load_cli_args_non_linux(self: *Config) callconv(.c) void {
    _ = ghostty_config_load_cli_args(self);
}

fn ghostty_config_load_file_non_linux(self: *Config, path: [*:0]const u8) callconv(.c) void {
    _ = ghostty_config_load_file(self, path);
}

fn ghostty_config_load_default_files_non_linux(self: *Config) callconv(.c) void {
    _ = ghostty_config_load_default_files(self);
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
pub fn ghostty_config_load_recursive_files(self_: ?*Config) callconv(.c) bool {
    const self = configHandle(self_, "ghostty_config_load_recursive_files") orelse return false;
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
        return false;
    };
    return true;
}

pub fn ghostty_config_finalize(self_: ?*Config) callconv(.c) bool {
    const self = configHandle(self_, "ghostty_config_finalize") orelse return false;
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
        return false;
    };
    return true;
}

fn ghostty_config_load_recursive_files_non_linux(self: *Config) callconv(.c) void {
    _ = ghostty_config_load_recursive_files(self);
}

fn ghostty_config_finalize_non_linux(self: *Config) callconv(.c) void {
    _ = ghostty_config_finalize(self);
}

comptime {
    if (builtin.os.tag == .linux) {
        @export(&ghostty_config_load_cli_args, .{ .name = "ghostty_config_load_cli_args" });
        @export(&ghostty_config_load_file, .{ .name = "ghostty_config_load_file" });
        @export(&ghostty_config_load_string, .{ .name = "ghostty_config_load_string" });
        @export(&ghostty_config_load_default_files, .{ .name = "ghostty_config_load_default_files" });
        @export(&ghostty_config_load_recursive_files, .{ .name = "ghostty_config_load_recursive_files" });
        @export(&ghostty_config_finalize, .{ .name = "ghostty_config_finalize" });
    } else {
        @export(&ghostty_config_load_cli_args_non_linux, .{ .name = "ghostty_config_load_cli_args" });
        @export(&ghostty_config_load_file_non_linux, .{ .name = "ghostty_config_load_file" });
        @export(&ghostty_config_load_string_non_linux, .{ .name = "ghostty_config_load_string" });
        @export(&ghostty_config_load_default_files_non_linux, .{ .name = "ghostty_config_load_default_files" });
        @export(&ghostty_config_load_recursive_files_non_linux, .{ .name = "ghostty_config_load_recursive_files" });
        @export(&ghostty_config_finalize_non_linux, .{ .name = "ghostty_config_finalize" });
    }
}

pub export fn ghostty_config_get(
    self_: ?*Config,
    ptr_: ?*anyopaque,
    key_str_: ?[*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const self = configHandle(self_, "ghostty_config_get") orelse return false;
    const ptr = ptr_ orelse {
        log.warn("ghostty_config_get called with null output pointer", .{});
        return false;
    };
    const key_str = bytesForLength(key_str_, len, "ghostty_config_get") orelse return false;
    const key = std.meta.stringToEnum(Key, key_str) orelse return false;
    return c_get.get(self, key, ptr);
}

pub export fn ghostty_config_trigger(
    self_: ?*Config,
    str_: ?[*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    const self = configHandle(self_, "ghostty_config_trigger") orelse return .{};
    const str = bytesForLength(str_, len, "ghostty_config_trigger") orelse return .{};
    return config_trigger_(self, str) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

pub export fn ghostty_config_diagnostics_count(self_: ?*Config) u32 {
    const self = configHandle(self_, "ghostty_config_diagnostics_count") orelse return 0;
    return @intCast(self._diagnostics.items().len);
}

pub export fn ghostty_config_get_diagnostic(self_: ?*Config, idx: u32) Diagnostic {
    const self = configHandle(self_, "ghostty_config_get_diagnostic") orelse return .{};
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

pub export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

test "ghostty_config_open_path ABI" {
    const c = @import("ghostty.h");
    const testing = std.testing;

    try testing.expect(@hasDecl(c, "ghostty_config_open_path"));
    try testing.expectEqual(@as(usize, @sizeOf(c.ghostty_string_s)), @as(usize, @sizeOf(String)));
    try testing.expectEqual(@as(usize, @alignOf(c.ghostty_string_s)), @as(usize, @alignOf(String)));

    const fields = .{
        .{ "ptr", "ptr" },
        .{ "len", "len" },
        .{ "sentinel", "sentinel" },
    };
    inline for (fields) |field| {
        try testing.expectEqual(
            @as(usize, @offsetOf(c.ghostty_string_s, field[0])),
            @as(usize, @offsetOf(String, field[1])),
        );
    }

    const function = @typeInfo(@TypeOf(c.ghostty_config_open_path)).@"fn";
    try testing.expectEqual(@as(usize, 0), function.params.len);
    try testing.expect(function.return_type.? == c.ghostty_string_s);
}

test "ghostty_config load/finalize ABI" {
    const c = @import("ghostty.h");
    const testing = std.testing;
    const expected_return = if (builtin.os.tag == .linux) bool else void;

    try testing.expect(@hasDecl(c, "ghostty_config_load_cli_args"));
    const load_cli_args = @typeInfo(@TypeOf(c.ghostty_config_load_cli_args)).@"fn";
    try testing.expect(load_cli_args.return_type.? == expected_return);

    try testing.expect(@hasDecl(c, "ghostty_config_load_file"));
    const load_file = @typeInfo(@TypeOf(c.ghostty_config_load_file)).@"fn";
    try testing.expect(load_file.return_type.? == expected_return);

    try testing.expect(@hasDecl(c, "ghostty_config_load_string"));
    const load_string = @typeInfo(@TypeOf(c.ghostty_config_load_string)).@"fn";
    try testing.expectEqual(
        @as(usize, if (builtin.os.tag == .linux) 3 else 4),
        load_string.params.len,
    );
    try testing.expect(load_string.return_type.? == expected_return);
    try testing.expect(load_string.params[0].type.? == c.ghostty_config_t);
    try testing.expect(load_string.params[1].type.? == [*c]const u8);
    try testing.expect(load_string.params[2].type.? == usize);
    if (comptime builtin.os.tag != .linux) {
        try testing.expect(load_string.params[3].type.? == [*c]const u8);
    }

    try testing.expect(@hasDecl(c, "ghostty_config_load_default_files"));
    const load_default_files = @typeInfo(@TypeOf(c.ghostty_config_load_default_files)).@"fn";
    try testing.expect(load_default_files.return_type.? == expected_return);

    try testing.expect(@hasDecl(c, "ghostty_config_load_recursive_files"));
    const load_recursive_files = @typeInfo(@TypeOf(c.ghostty_config_load_recursive_files)).@"fn";
    try testing.expect(load_recursive_files.return_type.? == expected_return);

    try testing.expect(@hasDecl(c, "ghostty_config_finalize"));
    const finalize = @typeInfo(@TypeOf(c.ghostty_config_finalize)).@"fn";
    try testing.expect(finalize.return_type.? == expected_return);
}

test "ghostty_config accessor ABI" {
    const c = @import("ghostty.h");
    const testing = std.testing;

    try testing.expect(@hasDecl(c, "ghostty_config_clone"));
    const clone = @typeInfo(@TypeOf(c.ghostty_config_clone)).@"fn";
    try testing.expectEqual(@as(usize, 1), clone.params.len);
    try testing.expect(clone.return_type.? == c.ghostty_config_t);
    try testing.expect(clone.params[0].type.? == c.ghostty_config_t);

    try testing.expect(@hasDecl(c, "ghostty_config_get"));
    const get = @typeInfo(@TypeOf(c.ghostty_config_get)).@"fn";
    try testing.expectEqual(@as(usize, 4), get.params.len);
    try testing.expect(get.return_type.? == bool);
    try testing.expect(get.params[0].type.? == c.ghostty_config_t);
    try testing.expect(get.params[1].type.? == ?*anyopaque);
    try testing.expect(get.params[2].type.? == [*c]const u8);
    try testing.expect(get.params[3].type.? == usize);

    try testing.expect(@hasDecl(c, "ghostty_config_trigger"));
    const trigger = @typeInfo(@TypeOf(c.ghostty_config_trigger)).@"fn";
    try testing.expectEqual(@as(usize, 3), trigger.params.len);
    try testing.expect(trigger.return_type.? == c.ghostty_input_trigger_s);
    try testing.expect(trigger.params[0].type.? == c.ghostty_config_t);
    try testing.expect(trigger.params[1].type.? == [*c]const u8);
    try testing.expect(trigger.params[2].type.? == usize);

    try testing.expect(@hasDecl(c, "ghostty_config_key_is_binding"));
    const key_is_binding = @typeInfo(@TypeOf(c.ghostty_config_key_is_binding)).@"fn";
    try testing.expectEqual(@as(usize, 2), key_is_binding.params.len);
    try testing.expect(key_is_binding.return_type.? == bool);
    try testing.expect(key_is_binding.params[0].type.? == c.ghostty_config_t);
    try testing.expect(key_is_binding.params[1].type.? == c.ghostty_input_key_s);
}

test "ghostty_config exported handles reject null" {
    const testing = std.testing;

    try testing.expect(ghostty_config_clone(null) == null);
    try testing.expect(!ghostty_config_load_cli_args(null));
    try testing.expect(!ghostty_config_load_default_files(null));
    try testing.expect(!ghostty_config_load_file(null, null));
    try testing.expect(!ghostty_config_load_string(null, null, 0));
    try testing.expect(!ghostty_config_load_recursive_files(null));
    try testing.expect(!ghostty_config_finalize(null));

    var out = false;
    const key = "maximize";
    try testing.expect(!ghostty_config_get(null, &out, key, key.len));

    const trigger = ghostty_config_trigger(null, null, 0);
    try testing.expectEqual(inputpkg.Binding.Trigger.C.Tag.physical, trigger.tag);
    try testing.expectEqual(inputpkg.Key.unidentified, trigger.key.physical);

    try testing.expectEqual(@as(u32, 0), ghostty_config_diagnostics_count(null));
    const diagnostic = ghostty_config_get_diagnostic(null, 0);
    try testing.expectEqualStrings("", std.mem.sliceTo(diagnostic.message, 0));
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_load_string: applies in-memory config" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    const input =
        \\maximize = true
        \\window-theme = dark
    ;
    try testing.expect(ghostty_config_load_string(&cfg, input.ptr, input.len));
    try testing.expect(cfg.maximize);
    try testing.expectEqual(Config.WindowTheme.dark, cfg.@"window-theme");
}

test "ghostty_config_load_string: null non-empty input returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    try testing.expect(!ghostty_config_load_string(&cfg, null, 1));
}

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_serialize round trips effective values" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var source = try Config.default(alloc);
    defer source.deinit();
    source.@"font-size" = 23.5;
    source.@"window-theme" = .dark;
    source.@"cursor-opacity" = 0.375;

    const serialized = try serializeConfig(alloc, &source);
    defer alloc.free(serialized);
    try testing.expect(std.mem.indexOf(u8, serialized, "font-size = 23.5") != null);
    try testing.expect(std.mem.indexOf(u8, serialized, "window-theme = dark") != null);

    var restored = try Config.default(alloc);
    defer restored.deinit();
    try restored.loadString(
        alloc,
        serialized,
        "/tmp/ghostty-effective-config",
    );
    try restored.finalize();

    try testing.expectEqual(source.@"font-size", restored.@"font-size");
    try testing.expectEqual(source.@"window-theme", restored.@"window-theme");
    try testing.expectEqual(source.@"cursor-opacity", restored.@"cursor-opacity");
    try testing.expect(source.@"command-palette-entry".equal(
        restored.@"command-palette-entry",
    ));
    try testing.expectEqual(@as(usize, 0), restored._diagnostics.items().len);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: null pointers return false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "maximize";
    try testing.expect(!ghostty_config_get(&cfg, null, key, key.len));
    try testing.expect(!ghostty_config_get(&cfg, &out, null, 1));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "ghostty_config_trigger: null string returns empty trigger" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    const trigger = ghostty_config_trigger(&cfg, null, 1);
    try testing.expectEqual(inputpkg.Binding.Trigger.C.Tag.physical, trigger.tag);
    try testing.expectEqual(inputpkg.Key.unidentified, trigger.key.physical);
}
