const GhosttySceneLib = @This();

const std = @import("std");
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const LipoStep = @import("LipoStep.zig");

step: *std.Build.Step,
output: std.Build.LazyPath,

/// Build the scene-only C ABI and its rendering dependencies as one archive.
pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttySceneLib {
    const scene_deps = try deps.sceneRendererOnly(b);
    const lib = b.addLibrary(.{
        .name = "ghostty-scene-renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_scene_c.zig"),
            .target = scene_deps.config.target,
            .optimize = scene_deps.config.optimize,
            .strip = scene_deps.config.strip,
            .omit_frame_pointer = scene_deps.config.strip,
            .unwind_tables = if (scene_deps.config.strip) .none else .sync,
        }),
        .use_llvm = true,
    });
    lib.linkLibC();
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    var libraries = try scene_deps.addSceneRenderer(lib);
    try libraries.append(b.allocator, lib.getEmittedBin());
    const combined = CombineArchivesStep.create(
        b,
        scene_deps.config.target,
        "ghostty-scene-renderer",
        libraries.items,
    );
    combined.step.dependOn(&lib.step);

    return .{
        .step = combined.step,
        .output = combined.output,
    };
}

/// Build one universal macOS archive for SwiftPM binary-target consumption.
pub fn initMacOSUniversal(
    b: *std.Build,
    original_deps: *const SharedDeps,
) !GhosttySceneLib {
    const aarch64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .aarch64),
    ));
    const x86_64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .x86_64),
    ));

    const universal = LipoStep.create(b, .{
        .name = "ghostty-scene-renderer",
        .out_name = "libghostty-scene-renderer.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });
    return .{
        .step = universal.step,
        .output = universal.output,
    };
}
