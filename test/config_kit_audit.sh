#!/bin/sh
set -eu

KIT="${1:-macos/GhosttyConfigKit.xcframework}"
test -d "$KIT" || {
  echo "error: GhosttyConfigKit not found: $KIT" >&2
  exit 1
}

TEMP_DIR="$(mktemp -d /tmp/ghostty-config-kit-audit.XXXXXX)"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

HEADER="$(find "$KIT" -type f -name ghostty_config.h -print -quit)"
test -n "$HEADER" || {
  echo "error: ghostty_config.h missing from $KIT" >&2
  exit 1
}

cat > "$TEMP_DIR/expected.txt" <<'EOF'
_ghostty_config_diagnostics_count
_ghostty_config_finalize
_ghostty_config_free
_ghostty_config_get_diagnostic
_ghostty_config_init
_ghostty_config_load_default_files
_ghostty_config_load_file
_ghostty_config_load_recursive_files
_ghostty_config_load_string
_ghostty_config_new
_ghostty_config_serialize
_ghostty_string_free
EOF

header_symbols="$TEMP_DIR/header.txt"
sed -nE 's/.*(ghostty_[a-z0-9_]+)[[:space:]]*\(.*/_\1/p' "$HEADER" | sort -u > "$header_symbols"
if ! cmp -s "$TEMP_DIR/expected.txt" "$header_symbols"; then
  echo "error: public config header ABI differs from the closed allowlist" >&2
  diff -u "$TEMP_DIR/expected.txt" "$header_symbols" >&2 || true
  exit 1
fi

modulemap="$(find "$KIT" -type f -name module.modulemap -print -quit)"
grep -Fq 'module GhosttyConfigKit' "$modulemap"
if grep -Eq 'GhosttySceneRendererKit|ghostty_scene' "$HEADER" "$modulemap"; then
  echo "error: ConfigKit header imports the scene renderer" >&2
  exit 1
fi
printf '@import GhosttyConfigKit;\nint main(void) { return 0; }\n' > "$TEMP_DIR/module-smoke.m"
clang -fmodules \
  -fmodules-cache-path="$TEMP_DIR/module-cache" \
  -fmodule-map-file="$modulemap" \
  -I "$(dirname "$HEADER")" \
  -fsyntax-only "$TEMP_DIR/module-smoke.m"

banned_ghostty='_ghostty_(app|surface|inspector|scene|renderer|terminal|pty|termio|benchmark|cli|input)_'
banned_process='_(posix_spawn|fork|forkpty|execv|execve|execvp|waitpid|system)$'
banned_dynamic='_(dlopen|dlopen_preflight|dlsym|NSCreateObjectFileImageFromFile|NSLinkModule|NSLookupSymbolInModule|CFBundleLoadExecutable|CFBundlePreflightExecutable)$'
banned_swift_bundle='Foundation.*Bundle.*(load|unload)'
bundle_loader_selectors='(^|[^[:alnum:]_])(load|unload|preflight|loadAndReturnError:|preflightAndReturnError:)([^[:alnum:]_]|$)'
banned_runtime_paths='src/(Surface|App|termio|pty)(\.zig|/)|src/terminal/(Parser|Stream|Terminal|Screen|Page|PageList|stream|parser)|src/renderer/(generic|metal|opengl|Thread|State|Scene|scene)(\.zig|/)|std/process/(Child|child)|pkg/macos/(iosurface|video)|ghostty_metallib|shaders\.metal|Metal\.framework|IOSurface\.framework'
banned_members='(^|/)(sentry|breakpad|glslang|spirv|Metal|metallib|imgui|dcimgui|pty|termio)[^/]*\.o$'

archive_containers="$TEMP_DIR/archive-containers.txt"
audit_archives="$TEMP_DIR/audit-archives.txt"
find "$KIT" -type f -name '*.a' -print | sort > "$archive_containers"
: > "$audit_archives"
while IFS= read -r archive; do
  archs="$(lipo -archs "$archive" 2>/dev/null || true)"
  if test "$(printf '%s\n' "$archs" | wc -w | tr -d ' ')" -gt 1; then
    for arch in $archs; do
      thin="$TEMP_DIR/$(printf '%s-%s' "$archive" "$arch" | shasum -a 256 | awk '{print $1}').a"
      lipo "$archive" -thin "$arch" -output "$thin"
      printf '%s\n' "$thin" >> "$audit_archives"
    done
  else
    printf '%s\n' "$archive" >> "$audit_archives"
  fi
done < "$archive_containers"

archive_count=0
while IFS= read -r archive; do
  archive_count=$((archive_count + 1))
  slug="$(printf '%s' "$archive" | shasum -a 256 | awk '{print $1}')"
  defined="$TEMP_DIR/$slug-defined.txt"
  undefined="$TEMP_DIR/$slug-undefined.txt"
  all_symbols="$TEMP_DIR/$slug-all.txt"
  strings_file="$TEMP_DIR/$slug-strings.txt"
  members="$TEMP_DIR/$slug-members.txt"
  ghostty_symbols="$TEMP_DIR/$slug-ghostty.txt"

  nm -gUj "$archive" > "$defined"
  nm -u -A "$archive" > "$undefined"
  nm -a "$archive" > "$all_symbols"
  strings -a "$archive" > "$strings_file"
  ar -t "$archive" > "$members"
  grep -E '^_ghostty_' "$defined" | sort -u > "$ghostty_symbols"

  if ! cmp -s "$TEMP_DIR/expected.txt" "$ghostty_symbols"; then
    echo "error: ConfigKit archive exports symbols outside its header: $archive" >&2
    diff -u "$TEMP_DIR/expected.txt" "$ghostty_symbols" >&2 || true
    exit 1
  fi
  if grep -Eq "$banned_ghostty|$banned_process|$banned_dynamic|$banned_swift_bundle" "$defined" "$undefined" "$all_symbols"; then
    echo "error: ConfigKit contains app, terminal runtime, process-launch, renderer, or dynamic-loader symbols: $archive" >&2
    grep -E "$banned_ghostty|$banned_process|$banned_dynamic|$banned_swift_bundle" "$defined" "$undefined" "$all_symbols" >&2 || true
    exit 1
  fi
  if grep -Fq '_OBJC_CLASS_$_NSBundle' "$all_symbols" &&
      grep -Eq "$bundle_loader_selectors" "$strings_file"; then
    echo "error: ConfigKit contains an NSBundle dynamic-loading escape hatch: $archive" >&2
    exit 1
  fi
  if grep -Eiq "$banned_runtime_paths" "$all_symbols" "$strings_file"; then
    echo "error: ConfigKit contains terminal VT/parser or render-runtime implementation paths: $archive" >&2
    grep -Ei "$banned_runtime_paths" "$all_symbols" "$strings_file" >&2 || true
    exit 1
  fi
  if grep -Eiq "$banned_members" "$members"; then
    echo "error: ConfigKit bundles a forbidden runtime dependency object: $archive" >&2
    grep -Ei "$banned_members" "$members" >&2 || true
    exit 1
  fi
  if otool -L "$archive" 2>/dev/null | grep -Eiq 'Metal|IOSurface'; then
    echo "error: ConfigKit links a GPU framework: $archive" >&2
    exit 1
  fi
done < "$audit_archives"

test "$archive_count" -gt 0 || {
  echo "error: ConfigKit contains no static archive" >&2
  exit 1
}

container_count="$(wc -l < "$archive_containers" | tr -d ' ')"
echo "GhosttyConfigKit audit passed: containers=$container_count architecture_archives=$archive_count exports=12"
