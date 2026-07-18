#!/bin/sh
set -eu

ZIG_BIN="${ZIG_BIN:-/opt/homebrew/opt/zig@0.15/bin/zig}"
SMOKE_DIR="$(mktemp -d /tmp/ghostty-config-kit-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_DIR"' EXIT INT TERM

"$ZIG_BIN" build \
  -Dapp-runtime=none \
  -Demit-xcframework=false \
  -Demit-scene-xcframework=false \
  -Demit-config-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Doptimize=ReleaseFast

KIT="macos/GhosttyConfigKit.xcframework"
ARCHIVE="$(find "$KIT" -type f -name '*.a' -print -quit)"
HEADERS="$(find "$KIT" -type d -name Headers -print -quit)"
test -n "$ARCHIVE"
test -n "$HEADERS"

mkdir -p "$SMOKE_DIR/config"
cat > "$SMOKE_DIR/config/root.ghostty" <<'EOF'
font-size = 17.5
config-file = child.ghostty
EOF
cat > "$SMOKE_DIR/config/child.ghostty" <<'EOF'
background = 123456
EOF

clang -std=c17 -Wall -Wextra -Werror \
  -I "$HEADERS" \
  test/config_kit_smoke.c \
  "$ARCHIVE" \
  -framework AppKit \
  -framework Foundation \
  -framework CoreFoundation \
  -lobjc \
  -o "$SMOKE_DIR/config-kit-smoke"
"$SMOKE_DIR/config-kit-smoke" "$SMOKE_DIR/config/root.ghostty"

test/config_kit_audit.sh "$KIT"
