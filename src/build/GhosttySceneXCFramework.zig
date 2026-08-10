const GhosttySceneXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttySceneLib = @import("GhosttySceneLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

xcframework: *XCFrameworkStep,
target: Target,

/// Build a macOS-only XCFramework whose module exposes the scene C ABI.
pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttySceneXCFramework {
    const macos_universal = try GhosttySceneLib.initMacOSUniversal(b, deps);
    const macos_native = try GhosttySceneLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    const files = b.addWriteFiles();
    _ = files.addCopyFile(
        b.path("include/ghostty_scene.h"),
        "ghostty_scene.h",
    );
    _ = files.addCopyFile(
        b.path("include/ghostty_scene.modulemap"),
        "module.modulemap",
    );
    const headers = files.getDirectory();

    const xcframework = XCFrameworkStep.create(b, .{
        .name = "GhosttySceneRendererKit",
        .out_path = "macos/GhosttySceneRendererKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{.{
                .library = macos_universal.output,
                .headers = headers,
                .dsym = null,
            }},
            .native => &.{.{
                .library = macos_native.output,
                .headers = headers,
                .dsym = null,
            }},
        },
    });

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const GhosttySceneXCFramework) void {
    self.xcframework.step.owner.getInstallStep().dependOn(
        self.xcframework.step,
    );
}
