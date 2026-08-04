$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$zig = $env:GHOSTTY_ZIG
if (-not $zig) {
  $command = Get-Command zig.exe -ErrorAction SilentlyContinue
  if ($command) { $zig = $command.Source }
}
if (-not $zig -and (Test-Path "C:\tools\zig\zig.exe")) {
  $zig = "C:\tools\zig\zig.exe"
}
if (-not $zig) {
  throw "Zig 0.15.2 was not found. Set GHOSTTY_ZIG or add zig.exe to PATH."
}

Push-Location $repo
try {
  & $zig build -Doptimize=ReleaseFast
} finally {
  Pop-Location
}

$required = @(
  (Join-Path $repo "zig-out\lib\ghostty-internal.dll"),
  (Join-Path $repo "zig-out\lib\ghostty-internal.lib"),
  (Join-Path $repo "zig-out\include\ghostty.h")
)
foreach ($path in $required) {
  if (-not (Test-Path $path)) {
    throw "Ghostty build did not produce $path"
  }
}
