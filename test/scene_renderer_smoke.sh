#!/bin/sh
set -eu

ZIG_BIN="${ZIG_BIN:-/opt/homebrew/opt/zig@0.15/bin/zig}"
SMOKE_DIR="$(mktemp -d /tmp/ghostty-scene-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_DIR"' EXIT INT TERM

"$ZIG_BIN" build \
  -Dapp-runtime=none \
  -Demit-xcframework=false \
  -Demit-scene-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Doptimize=ReleaseFast
"$ZIG_BIN" build -Demit-lib-vt=true -Doptimize=ReleaseFast

clang -std=c17 -Wall -Wextra -Werror \
  -I zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/Headers \
  -I test \
  -c test/scene_renderer_fixture.c \
  -o "$SMOKE_DIR/fixture.o"
clang -std=c17 -Wall -Wextra -Werror \
  -I macos/GhosttySceneRendererKit.xcframework/macos-arm64/Headers \
  -I test \
  -c test/scene_renderer_smoke.c \
  -o "$SMOKE_DIR/smoke.o"
clang "$SMOKE_DIR/smoke.o" "$SMOKE_DIR/fixture.o" \
  macos/GhosttySceneRendererKit.xcframework/macos-arm64/libghostty-scene-renderer-fat.a \
  zig-out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a \
  -framework Foundation \
  -framework Carbon \
  -framework CoreFoundation \
  -framework CoreGraphics \
  -framework CoreText \
  -framework CoreVideo \
  -framework QuartzCore \
  -framework IOSurface \
  -framework Metal \
  -lc++ \
  -o "$SMOKE_DIR/smoke"
"$SMOKE_DIR/smoke" \
  "$(pwd)/src/renderer/shaders/test_shadertoy_crt.glsl"
