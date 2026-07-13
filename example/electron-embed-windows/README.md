# Electron + native libghostty on Windows

This demo embeds a real libghostty surface in Electron 43.1.0. The Node-API
addon creates a child `HWND` under `BrowserWindow.getNativeWindowHandle()`,
owns a WGL OpenGL 4.3 context, and supplies that context through
`GHOSTTY_PLATFORM_OPENGL`. Chromium renders the panel beside it.

There is no xterm.js dependency. `ghostty_surface_new` starts the Windows
ConPTY-backed shell, and Ghostty's OpenGL renderer presents every terminal
frame through the addon's `SwapBuffers` callback.

## Build

Install Zig 0.15.2, Visual Studio 2022 Build Tools with the Desktop C++
workload, Node.js, and npm. From this directory:

```powershell
npm install
npm run build:ghostty
npm run build
npm start
```

The Ghostty build now installs `ghostty-internal.lib` with
`ghostty-internal.dll`, so MSVC embedders link against stable files under
`zig-out\lib`.

Ghostty requires desktop OpenGL 4.3. Many Windows cloud VMs expose only the
Microsoft OpenGL 1.1 RDP driver. Install a trusted OpenGL 4.3-capable GPU
driver for production. For software-rendered cloud validation, extract a
trusted Mesa Windows x64 build, then run:

```powershell
$env:GHOSTTY_MESA_DIR = "C:\path\to\mesa"
npm run deploy:mesa
.\scripts\start-software-renderer.cmd
```

The deploy script renames Mesa's `opengl32.dll` and places it beside the addon
with `libgallium_wgl.dll`. The addon loads that private WGL table through
`GHOSTTY_MESA_OPENGL_PATH`; it does not replace Electron's `opengl32.dll` or
alter Chromium's graphics stack. The addon rejects contexts older than 4.3 and
reports the exact GL version instead of showing a blank pseudo-terminal.

## Input and lifecycle

The child window routes physical scan codes, committed UTF-16 text, focus,
selection drags, wheel scrolling, and terminal mouse reporting directly to
libghostty. Right-click first checks `ghostty_surface_mouse_captured`: captured
applications receive the button, while an uncaptured shell gets a native
Copy/Paste menu backed by Ghostty's clipboard callbacks.

`destroy()` is idempotent. It first joins and frees the Ghostty surface while
WGL callbacks remain alive, then frees the app and config, deletes the GL
context, and destroys the child window. N-API finalization repeats the same
safe path, so closing during active output does not depend on garbage
collection order. Embedded surface creation also waits until renderer and IO
stop watchers are armed, so an immediate destroy cannot lose a startup stop
notification and deadlock teardown.

## Stress

`npm run stress` immediately creates and destroys 25 surfaces to exercise the
thread-startup race, then recreates 50 rendered surfaces, performs 2,500 native
resizes, closes each shell during active output, and injects five Chromium
renderer deaths while retaining the native terminal host. It writes a JSON
report under `artifacts` and fails on unexpected renderer loss, unresponsive
windows, native renderer health failures, a surface that never swaps a real
WGL frame, or retained memory growth above the limit.

`npm run stress:cycles` repeats the test in five fresh Electron processes for
cold-start coverage. The aggregate report is
`artifacts\stress-cycles.json`.
