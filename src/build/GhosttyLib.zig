const GhosttyLib = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const LipoStep = @import("LipoStep.zig");

const internal_lib_name = "ghostty-internal";

/// The step that generates the file.
step: *std.Build.Step,

/// The final static library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: ?std.Build.LazyPath,
pkg_config_static: ?std.Build.LazyPath,

pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLib {
    const lib = b.addLibrary(.{
        .name = internal_lib_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.strip,
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),

        // Fails on self-hosted x86_64 on macOS
        .use_llvm = true,
    });
    lib.linkLibC();

    // These must be bundled since we're compiling into a static lib.
    // Otherwise, you get undefined symbol errors.
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    if (deps.config.target.result.os.tag == .windows) {
        // Zig's ubsan emits /exclude-symbols linker directives that
        // are incompatible with the MSVC linker (LNK4229).
        lib.bundle_ubsan_rt = false;
    }

    // Add our dependencies. Get the list of all static deps so we can
    // build a combined archive.
    var lib_list = try deps.add(lib);
    try lib_list.append(b.allocator, lib.getEmittedBin());

    // Combine all archives into a single fat static library so
    // consumers only need to link one file.
    const combined = CombineArchivesStep.create(b, deps.config.target, "ghostty-internal", lib_list.items);
    combined.step.dependOn(&lib.step);

    return .{
        .step = combined.step,
        .output = combined.output,

        // Static libraries cannot have dSYMs because they aren't linked.
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}

pub fn initShared(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLib {
    const lib = b.addLibrary(.{
        .name = internal_lib_name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.strip,
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),

        // Fails on self-hosted x86_64
        .use_llvm = true,
    });
    _ = try deps.add(lib);
    try applySharedSymbolVisibility(b, lib, deps.config.target.result.os.tag);

    // On Windows with MSVC, building a DLL requires the full CRT library
    // chain. linkLibC() (called via deps.add) provides msvcrt.lib, but
    // that references symbols in vcruntime.lib and ucrt.lib. Zig's library
    // search paths include the MSVC lib dir and the Windows SDK 'um' dir,
    // but not the SDK 'ucrt' dir where ucrt.lib lives.
    if (deps.config.target.result.os.tag == .windows and
        deps.config.target.result.abi == .msvc)
    {
        // The CRT initialization code in msvcrt.lib calls __vcrt_initialize
        // and __acrt_initialize, which are in the static CRT libraries.
        lib.linkSystemLibrary("libvcruntime");

        // ucrt.lib is in the Windows SDK 'ucrt' dir. Detect the SDK
        // installation and add the UCRT library path.
        const arch = deps.config.target.result.cpu.arch;
        const sdk = std.zig.WindowsSdk.find(b.allocator, arch) catch null;
        if (sdk) |s| {
            if (s.windows10sdk) |w10| {
                const arch_str: []const u8 = switch (arch) {
                    .x86_64 => "x64",
                    .x86 => "x86",
                    .aarch64 => "arm64",
                    else => "x64",
                };
                const ucrt_lib_path = std.fmt.allocPrint(
                    b.allocator,
                    "{s}\\Lib\\{s}\\ucrt\\{s}",
                    .{ w10.path, w10.version, arch_str },
                ) catch null;

                if (ucrt_lib_path) |path| {
                    lib.addLibraryPath(.{ .cwd_relative = path });
                }
            }
        }
        lib.linkSystemLibrary("libucrt");
    }

    // Get our debug symbols
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (!deps.config.target.result.os.tag.isDarwin()) {
            break :dsymutil null;
        }

        const dsymutil = RunStep.create(b, "dsymutil");
        dsymutil.addArgs(&.{"dsymutil"});
        dsymutil.addFileArg(lib.getEmittedBin());
        dsymutil.addArgs(&.{"-o"});
        const output = dsymutil.addOutputFileArg("libghostty.dSYM");
        break :dsymutil output;
    };

    // pkg-config
    //
    // pkg-config's --static only expands Libs.private / Requires.private;
    // it doesn't rewrite Libs: into an archive-only reference when both
    // shared and static libraries are installed. Install a dedicated static
    // module whose normal Libs output is a complete static link command.
    const pcs = pkgConfigFiles(b, deps);

    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .pkg_config = pcs.shared,
        .pkg_config_static = pcs.static,
    };
}

fn applySharedSymbolVisibility(
    b: *std.Build,
    lib: *std.Build.Step.Compile,
    os_tag: std.Target.Os.Tag,
) !void {
    // The Linux embedded library is loaded into a non-Ghostty host process.
    // Keep vendored dependency symbols out of the dynamic namespace and expose
    // only the intended C API.
    if (os_tag != .linux) return;

    const wf = b.addWriteFiles();
    lib.setVersionScript(wf.add(
        "ghostty-internal.exports",
        try versionScript(b.allocator, &linux_shared_exports),
    ));
}

const linux_shared_exports = [_][]const u8{
    "ghostty_app_free",
    "ghostty_app_has_global_keybinds",
    "ghostty_app_key",
    "ghostty_app_keyboard_changed",
    "ghostty_app_must_draw_from_app_thread",
    "ghostty_app_needs_confirm_quit",
    "ghostty_app_new",
    "ghostty_app_open_config",
    "ghostty_app_reload_config",
    "ghostty_app_set_color_scheme",
    "ghostty_app_set_focus",
    "ghostty_app_tick",
    "ghostty_app_update_config",
    "ghostty_app_userdata",
    "ghostty_benchmark_cli",
    "ghostty_cli_try_action",
    "ghostty_config_clone",
    "ghostty_config_diagnostics_count",
    "ghostty_config_finalize",
    "ghostty_config_free",
    "ghostty_config_get",
    "ghostty_config_get_diagnostic",
    "ghostty_config_key_is_binding",
    "ghostty_config_load_cli_args",
    "ghostty_config_load_default_files",
    "ghostty_config_load_file",
    "ghostty_config_load_recursive_files",
    "ghostty_config_load_string",
    "ghostty_config_new",
    "ghostty_config_open_path",
    "ghostty_config_trigger",
    "ghostty_embedding_info",
    "ghostty_embedding_info_query",
    "ghostty_info",
    "ghostty_init",
    "ghostty_inspector_free",
    "ghostty_inspector_key",
    "ghostty_inspector_mouse_button",
    "ghostty_inspector_mouse_pos",
    "ghostty_inspector_mouse_scroll",
    "ghostty_inspector_opengl_init",
    "ghostty_inspector_opengl_render",
    "ghostty_inspector_opengl_shutdown",
    "ghostty_inspector_set_content_scale",
    "ghostty_inspector_set_focus",
    "ghostty_inspector_set_size",
    "ghostty_inspector_text",
    "ghostty_resources_dir",
    "ghostty_string_free",
    "ghostty_surface_app",
    "ghostty_surface_binding_action",
    "ghostty_surface_clear_selection",
    "ghostty_surface_complete_clipboard_request",
    "ghostty_surface_config_new",
    "ghostty_surface_display_realized",
    "ghostty_surface_display_unrealized",
    "ghostty_surface_draw",
    "ghostty_surface_foreground_pid",
    "ghostty_surface_free",
    "ghostty_surface_free_text",
    "ghostty_surface_has_selection",
    "ghostty_surface_ime_point",
    "ghostty_surface_inherited_config",
    "ghostty_surface_inherited_config_free",
    "ghostty_surface_inspector",
    "ghostty_surface_key",
    "ghostty_surface_key_is_binding",
    "ghostty_surface_key_translation_mods",
    "ghostty_surface_mouse_button",
    "ghostty_surface_mouse_captured",
    "ghostty_surface_mouse_pos",
    "ghostty_surface_mouse_pressure",
    "ghostty_surface_mouse_scroll",
    "ghostty_surface_needs_confirm_quit",
    "ghostty_surface_new",
    "ghostty_surface_preedit",
    "ghostty_surface_process_exited",
    "ghostty_surface_pwd",
    "ghostty_surface_read_scrollback",
    "ghostty_surface_read_selection",
    "ghostty_surface_read_text",
    "ghostty_surface_refresh",
    "ghostty_surface_request_close",
    "ghostty_surface_select_cursor_cell",
    "ghostty_surface_select_viewport_rows",
    "ghostty_surface_set_color_scheme",
    "ghostty_surface_set_content_scale",
    "ghostty_surface_set_focus",
    "ghostty_surface_set_occlusion",
    "ghostty_surface_set_renderer_realized",
    "ghostty_surface_set_size",
    "ghostty_surface_set_visible",
    "ghostty_surface_size",
    "ghostty_surface_split",
    "ghostty_surface_split_equalize",
    "ghostty_surface_split_focus",
    "ghostty_surface_split_resize",
    "ghostty_surface_split_toggle_zoom",
    "ghostty_surface_text",
    "ghostty_surface_process_output",
    "ghostty_surface_title",
    "ghostty_surface_tty_name",
    "ghostty_surface_update_config",
    "ghostty_surface_userdata",
    "ghostty_translate",
};

fn versionScript(alloc: std.mem.Allocator, exports: []const []const u8) ![]const u8 {
    var script: std.ArrayList(u8) = .empty;
    errdefer script.deinit(alloc);

    try script.appendSlice(alloc, "{\n  global:\n");
    for (exports) |symbol| {
        try script.appendSlice(alloc, "    ");
        try script.appendSlice(alloc, symbol);
        try script.appendSlice(alloc, ";\n");
    }
    try script.appendSlice(alloc, "  local:\n    *;\n};\n");

    return script.toOwnedSlice(alloc);
}

fn containsExport(name: []const u8) bool {
    for (linux_shared_exports) |symbol| {
        if (std.mem.eql(u8, symbol, name)) return true;
    }
    return false;
}

fn containsCmuxLinuxEmbeddingExport(name: []const u8) bool {
    for (cmux_linux_embedding_exports) |symbol| {
        if (std.mem.eql(u8, symbol, name)) return true;
    }
    return false;
}

fn containsCmuxLinuxOptionalExport(name: []const u8) bool {
    for (cmux_linux_optional_exports) |symbol| {
        if (std.mem.eql(u8, symbol, name)) return true;
    }
    return false;
}

const cmux_linux_embedding_exports = [_][]const u8{
    "ghostty_init",
    "ghostty_string_free",
    "ghostty_embedding_info",
    "ghostty_embedding_info_query",
    "ghostty_config_new",
    "ghostty_config_free",
    "ghostty_config_load_cli_args",
    "ghostty_config_load_file",
    "ghostty_config_load_string",
    "ghostty_config_load_default_files",
    "ghostty_config_load_recursive_files",
    "ghostty_config_finalize",
    "ghostty_config_get",
    "ghostty_config_diagnostics_count",
    "ghostty_config_get_diagnostic",
    "ghostty_config_open_path",
    "ghostty_resources_dir",
    "ghostty_app_new",
    "ghostty_app_free",
    "ghostty_app_tick",
    "ghostty_app_userdata",
    "ghostty_app_set_focus",
    "ghostty_app_key",
    "ghostty_app_keyboard_changed",
    "ghostty_app_open_config",
    "ghostty_app_reload_config",
    "ghostty_app_update_config",
    "ghostty_app_needs_confirm_quit",
    "ghostty_app_has_global_keybinds",
    "ghostty_app_must_draw_from_app_thread",
    "ghostty_app_set_color_scheme",
    "ghostty_surface_config_new",
    "ghostty_surface_new",
    "ghostty_surface_free",
    "ghostty_surface_userdata",
    "ghostty_surface_app",
    "ghostty_surface_inherited_config",
    "ghostty_surface_inherited_config_free",
    "ghostty_surface_update_config",
    "ghostty_surface_refresh",
    "ghostty_surface_draw",
    "ghostty_surface_display_realized",
    "ghostty_surface_display_unrealized",
    "ghostty_surface_set_renderer_realized",
    "ghostty_surface_set_content_scale",
    "ghostty_surface_set_focus",
    "ghostty_surface_set_visible",
    "ghostty_surface_set_occlusion",
    "ghostty_surface_set_size",
    "ghostty_surface_set_color_scheme",
    "ghostty_surface_needs_confirm_quit",
    "ghostty_surface_size",
    "ghostty_surface_process_exited",
    "ghostty_surface_foreground_pid",
    "ghostty_surface_tty_name",
    "ghostty_surface_title",
    "ghostty_surface_pwd",
    "ghostty_surface_key_translation_mods",
    "ghostty_surface_key",
    "ghostty_surface_key_is_binding",
    "ghostty_surface_text",
    "ghostty_surface_process_output",
    "ghostty_surface_preedit",
    "ghostty_surface_mouse_captured",
    "ghostty_surface_mouse_button",
    "ghostty_surface_mouse_pos",
    "ghostty_surface_mouse_scroll",
    "ghostty_surface_mouse_pressure",
    "ghostty_surface_ime_point",
    "ghostty_surface_request_close",
    "ghostty_surface_split",
    "ghostty_surface_split_focus",
    "ghostty_surface_split_resize",
    "ghostty_surface_split_equalize",
    "ghostty_surface_split_toggle_zoom",
    "ghostty_surface_binding_action",
    "ghostty_surface_has_selection",
    "ghostty_surface_select_cursor_cell",
    "ghostty_surface_select_viewport_rows",
    "ghostty_surface_clear_selection",
    "ghostty_surface_read_scrollback",
    "ghostty_surface_read_selection",
    "ghostty_surface_complete_clipboard_request",
    "ghostty_surface_read_text",
    "ghostty_surface_free_text",
    "ghostty_surface_inspector",
    "ghostty_inspector_free",
    "ghostty_inspector_set_focus",
    "ghostty_inspector_set_content_scale",
    "ghostty_inspector_set_size",
    "ghostty_inspector_mouse_button",
    "ghostty_inspector_mouse_pos",
    "ghostty_inspector_mouse_scroll",
    "ghostty_inspector_key",
    "ghostty_inspector_text",
    "ghostty_inspector_opengl_init",
    "ghostty_inspector_opengl_render",
    "ghostty_inspector_opengl_shutdown",
};

const cmux_linux_optional_exports = [_][]const u8{
    "ghostty_benchmark_cli",
    "ghostty_cli_try_action",
    "ghostty_config_clone",
    "ghostty_config_key_is_binding",
    "ghostty_config_trigger",
    "ghostty_info",
    "ghostty_translate",
};

pub fn initMacOSUniversal(
    b: *std.Build,
    original_deps: *const SharedDeps,
) !GhosttyLib {
    const aarch64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .aarch64),
    ));
    const x86_64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .x86_64),
    ));

    const universal = LipoStep.create(b, .{
        .name = "ghostty",
        .out_name = "ghostty-internal.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });

    return .{
        .step = universal.step,
        .output = universal.output,

        // You can't run dsymutil on a universal binary, you have to
        // do it on the individual binaries.
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}

pub fn install(self: *const GhosttyLib, name: []const u8) void {
    self.installLibraryFile(name);

    const b = self.step.owner;
    const step = b.getInstallStep();
    if (self.pkg_config) |pc| {
        step.dependOn(&b.addInstallFileWithDir(
            pc,
            .prefix,
            "share/pkgconfig/ghostty-internal.pc",
        ).step);
    }
    if (self.pkg_config_static) |pc| {
        step.dependOn(&b.addInstallFileWithDir(
            pc,
            .prefix,
            "share/pkgconfig/ghostty-internal-static.pc",
        ).step);
    }
}

pub fn installLibraryFile(self: *const GhosttyLib, name: []const u8) void {
    const b = self.step.owner;
    const lib_install = b.addInstallLibFile(self.output, name);
    b.getInstallStep().dependOn(&lib_install.step);
}

pub fn installHeader(self: *const GhosttyLib) void {
    const b = self.step.owner;
    const header_install = b.addInstallHeaderFile(
        b.path("include/ghostty.h"),
        "ghostty.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
}

const PkgConfigFiles = struct {
    shared: std.Build.LazyPath,
    static: std.Build.LazyPath,
};

fn pkgConfigFiles(
    b: *std.Build,
    deps: *const SharedDeps,
) PkgConfigFiles {
    const os_tag = deps.config.target.result.os.tag;
    const prefix = pkgConfigPathValue(b.allocator, b.install_prefix) catch
        @panic("failed to escape pkg-config prefix");
    const libs_private = libsPrivate(os_tag);
    const static_libs = staticLibraryLibs(b.allocator, os_tag) catch
        @panic("failed to format static pkg-config libraries");
    const wf = b.addWriteFiles();

    return .{
        .shared = wf.add("ghostty-internal.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: ghostty-internal
            \\URL: https://github.com/ghostty-org/ghostty
            \\Description: Ghostty internal library (not for external use)
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: {s}
            \\Libs.private: {s}
            \\Requires.private:
            \\
        , .{ prefix, deps.config.version, sharedLibraryLibs(os_tag), libs_private })),
        .static = wf.add("ghostty-internal-static.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: ghostty-internal-static
            \\URL: https://github.com/ghostty-org/ghostty
            \\Description: Ghostty internal library, static (not for external use)
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: {s}
            \\Libs.private:
            \\Requires.private:
            \\
        , .{ prefix, deps.config.version, static_libs })),
    };
}

fn libsPrivate(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        // The combined Linux static archive contains vendored C/C++ dependency
        // objects, but consumers still need the runtime/system libraries those
        // objects reference. These are emitted only for pkg-config --static.
        .linux => "-lc++ -lc++abi -lunwind -lm -lxml2 -lz -lbz2 -lpthread -ldl",
        else => "",
    };
}

fn sharedLibraryLibs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "${libdir}/ghostty-internal.dll"
    else
        "-L${libdir} -lghostty-internal";
}

fn staticLibraryLibs(
    alloc: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
) ![]const u8 {
    const dependencies = libsPrivate(os_tag);
    return std.fmt.allocPrint(
        alloc,
        "${{libdir}}/{s}{s}{s}",
        .{
            staticLibraryName(os_tag),
            if (dependencies.len > 0) " " else "",
            dependencies,
        },
    );
}

fn pkgConfigPathValue(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(alloc);

    for (value) |byte| {
        switch (byte) {
            '\\', ' ', '\t', '*', '?', '[', ']' => try escaped.append(alloc, '\\'),
            '\n', '\r' => return error.InvalidPkgConfigPath,
            else => {},
        }
        try escaped.append(alloc, byte);
    }

    return escaped.toOwnedSlice(alloc);
}

test "pkg-config path values escape shell-sensitive path characters" {
    const escaped = try pkgConfigPathValue(
        std.testing.allocator,
        "/tmp/prefix with space/lib\\ghostty*[dev]",
    );
    defer std.testing.allocator.free(escaped);

    try std.testing.expectEqualStrings(
        "/tmp/prefix\\ with\\ space/lib\\\\ghostty\\*\\[dev\\]",
        escaped,
    );
}

test "Linux shared library version script exports only the C API list" {
    const script = try versionScript(std.testing.allocator, &linux_shared_exports);
    defer std.testing.allocator.free(script);

    try std.testing.expect(std.mem.startsWith(u8, script, "{\n  global:\n"));
    try std.testing.expect(std.mem.endsWith(u8, script, "  local:\n    *;\n};\n"));
    try std.testing.expect(std.mem.indexOf(u8, script, "    ghostty_init;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "    ghostty_surface_draw;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ghostty_*") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ghostty_simd_") == null);
}

test "Linux shared export allowlist stays narrow and complete for embedders" {
    try std.testing.expectEqual(@as(usize, 104), linux_shared_exports.len);
    try std.testing.expectEqual(@as(usize, 97), cmux_linux_embedding_exports.len);
    try std.testing.expectEqual(
        linux_shared_exports.len,
        cmux_linux_embedding_exports.len + cmux_linux_optional_exports.len,
    );

    inline for (cmux_linux_embedding_exports) |symbol| {
        try std.testing.expect(containsExport(symbol));
    }
    inline for (cmux_linux_optional_exports) |symbol| {
        try std.testing.expect(containsExport(symbol));
        try std.testing.expect(!containsCmuxLinuxEmbeddingExport(symbol));
    }

    inline for (linux_shared_exports, 0..) |symbol, index| {
        try std.testing.expect(std.mem.startsWith(u8, symbol, "ghostty_"));
        try std.testing.expect(!std.mem.startsWith(u8, symbol, "ghostty_simd_"));
        try std.testing.expect(!std.mem.startsWith(u8, symbol, "ghostty_surface_quicklook_"));
        try std.testing.expect(!std.mem.eql(u8, symbol, "ghostty_surface_set_display_id"));
        try std.testing.expect(!std.mem.eql(u8, symbol, "ghostty_set_window_background_blur"));
        try std.testing.expect(!std.mem.startsWith(u8, symbol, "ghostty_inspector_metal_"));
        try std.testing.expect(
            containsCmuxLinuxEmbeddingExport(symbol) or containsCmuxLinuxOptionalExport(symbol),
        );

        if (index > 0) {
            try std.testing.expect(std.mem.order(u8, linux_shared_exports[index - 1], symbol) == .lt);
        }

        inline for (linux_shared_exports, 0..) |other, other_index| {
            if (index < other_index) {
                try std.testing.expect(!std.mem.eql(u8, symbol, other));
            }
        }
    }
}

test "pkg-config static link libraries cover Linux archive dependencies" {
    try std.testing.expectEqualStrings(
        "-lc++ -lc++abi -lunwind -lm -lxml2 -lz -lbz2 -lpthread -ldl",
        libsPrivate(.linux),
    );
    try std.testing.expectEqualStrings("", libsPrivate(.macos));

    const linux = try staticLibraryLibs(std.testing.allocator, .linux);
    defer std.testing.allocator.free(linux);
    try std.testing.expectEqualStrings(
        "${libdir}/libghostty-internal.a -lc++ -lc++abi -lunwind -lm -lxml2 -lz -lbz2 -lpthread -ldl",
        linux,
    );

    const macos = try staticLibraryLibs(std.testing.allocator, .macos);
    defer std.testing.allocator.free(macos);
    try std.testing.expectEqualStrings(
        "${libdir}/libghostty-internal.a",
        macos,
    );
}

test "pkg-config shared library flags use linker search path on Unix" {
    try std.testing.expectEqualStrings(
        "-L${libdir} -lghostty-internal",
        sharedLibraryLibs(.linux),
    );
    try std.testing.expectEqualStrings(
        "${libdir}/ghostty-internal.dll",
        sharedLibraryLibs(.windows),
    );
}

test "embedding header uses strict C prototypes for zero-argument APIs" {
    const header = @embedFile("../../include/ghostty.h");
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "ghostty_config_new(void);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "ghostty_surface_config_new(void);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "ghostty_config_new();",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "ghostty_surface_config_new();",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "GHOSTTY_ENUM_ABI_ASSERT(ghostty_platform_e);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "GHOSTTY_ENUM_ABI_ASSERT(ghostty_action_tag_e);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        header,
        "GHOSTTY_ENUM_ABI_ASSERT(ghostty_ipc_action_tag_e);",
    ) != null);
}

fn sharedLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "ghostty-internal.dll"
    else
        "libghostty-internal.so";
}

fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "ghostty-internal-static.lib"
    else
        "libghostty-internal.a";
}
