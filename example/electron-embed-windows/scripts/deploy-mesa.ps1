param(
  [string]$MesaDir = $env:GHOSTTY_MESA_DIR
)

$ErrorActionPreference = "Stop"

if (-not $MesaDir) {
  throw "Set GHOSTTY_MESA_DIR to an extracted Mesa Windows x64 directory."
}

$openGl = Join-Path $MesaDir "opengl32.dll"
$gallium = Join-Path $MesaDir "libgallium_wgl.dll"
if (-not (Test-Path $openGl) -or -not (Test-Path $gallium)) {
  throw "GHOSTTY_MESA_DIR must contain opengl32.dll and libgallium_wgl.dll."
}

$destination = Join-Path $PSScriptRoot "..\build\Release"
New-Item -ItemType Directory -Force $destination | Out-Null
Copy-Item -Force $openGl (Join-Path $destination "opengl32.mesa.dll")
Copy-Item -Force $gallium (Join-Path $destination "libgallium_wgl.dll")
