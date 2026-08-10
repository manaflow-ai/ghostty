const GhosttyConfigXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const GhosttyConfigLib = @import("GhosttyConfigLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

xcframework: *XCFrameworkStep,
target: Target,

/// Build a macOS-only XCFramework whose module exposes only the config C ABI.
pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !GhosttyConfigXCFramework {
    const macos_universal = try GhosttyConfigLib.initMacOSUniversal(b, deps);
    const macos_native = try GhosttyConfigLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    const files = b.addWriteFiles();
    _ = files.addCopyFile(
        b.path("include/ghostty_config.h"),
        "ghostty_config.h",
    );
    _ = files.addCopyFile(
        b.path("include/ghostty_config.modulemap"),
        "module.modulemap",
    );
    const headers = files.getDirectory();

    const xcframework = XCFrameworkStep.create(b, .{
        .name = "GhosttyConfigKit",
        .out_path = "macos/GhosttyConfigKit.xcframework",
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

pub fn install(self: *const GhosttyConfigXCFramework) void {
    self.xcframework.step.owner.getInstallStep().dependOn(
        self.xcframework.step,
    );
}
