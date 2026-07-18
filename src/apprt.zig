//! "apprt" is the "application runtime" package. This abstracts the
//! application runtime and lifecycle management such as creating windows,
//! getting user input (mouse/keyboard), etc.
//!
//! This enables compile-time interfaces to be built to swap out the underlying
//! application runtime. For example: pure macOS Cocoa, GTK+, browser, etc.
//!
//! The goal is to have different implementations share as much of the core
//! logic as possible, and to only reach out to platform-specific implementation
//! code when absolutely necessary.
const build_config = @import("build_config.zig");

const structs = @import("apprt/structs.zig");

pub const action = @import("apprt/action.zig");
pub const ipc = @import("apprt/ipc.zig");
pub const gtk = @import("apprt/gtk.zig");
pub const none = @import("apprt/none.zig");
pub const browser = @import("apprt/browser.zig");
pub const embedded = @import("apprt/embedded.zig");
pub const surface = @import("apprt/surface.zig");

pub const Action = action.Action;
pub const Runtime = @import("apprt/runtime.zig").Runtime;
pub const Target = action.Target;

pub const ContentScale = structs.ContentScale;
pub const Clipboard = structs.Clipboard;
pub const ClipboardContent = structs.ClipboardContent;
pub const ClipboardRequest = structs.ClipboardRequest;
pub const ClipboardRequestType = structs.ClipboardRequestType;
pub const ColorScheme = structs.ColorScheme;
pub const CursorPos = structs.CursorPos;
pub const IMEPos = structs.IMEPos;
pub const Selection = structs.Selection;
pub const SurfaceSize = structs.SurfaceSize;

/// The implementation to use for the app runtime. This is comptime chosen
/// so that every build has exactly one application runtime implementation.
/// Note: it is very rare to use Runtime directly; most usage will use
/// Window or something.
pub const runtime = selectRuntime(
    build_config.artifact,
    build_config.app_runtime,
    build_config.scene_renderer_only,
);

fn selectRuntime(
    comptime artifact: build_config.Artifact,
    comptime configured: Runtime,
    comptime scene_renderer_only: bool,
) type {
    return switch (artifact) {
        .exe => switch (configured) {
            .none => none,
            .gtk => gtk,
        },

        // Scene-only libraries never expose or construct the embedded app,
        // Surface, inspector, termio, or host callback runtime.
        .lib => if (scene_renderer_only) none else embedded,
        .wasm_module => browser,
    };
}

comptime {
    if (build_config.scene_renderer_only and runtime != none)
        @compileError("scene renderer selected an application runtime");
}

pub const App = runtime.App;
pub const Surface = runtime.Surface;

test "scene renderer library selects the no-runtime apprt" {
    const testing = @import("std").testing;
    try testing.expect(selectRuntime(.lib, .none, true) == none);
    try testing.expect(selectRuntime(.lib, .none, false) == embedded);
}

test {
    _ = Runtime;
    _ = runtime;
    _ = action;
    _ = structs;
}
