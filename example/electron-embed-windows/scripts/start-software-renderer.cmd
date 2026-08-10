@echo off
setlocal
set GALLIUM_DRIVER=llvmpipe
set LIBGL_ALWAYS_SOFTWARE=true
set MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
set GHOSTTY_MESA_OPENGL_PATH=%~dp0..\build\Release\opengl32.mesa.dll
if not exist "%GHOSTTY_MESA_OPENGL_PATH%" (
  echo Missing %GHOSTTY_MESA_OPENGL_PATH%. Run npm run deploy:mesa first.
  exit /b 1
)
if not exist "%~dp0..\build\Release\libgallium_wgl.dll" (
  echo Missing libgallium_wgl.dll. Run npm run deploy:mesa first.
  exit /b 1
)
if not exist "%~dp0..\artifacts" mkdir "%~dp0..\artifacts"
set GHOSTTY_EMBED_TRACE=%~dp0..\artifacts\native.log
del "%GHOSTTY_EMBED_TRACE%" 2>nul
"%~dp0..\node_modules\electron\dist\electron.exe" "%~dp0.." %* --enable-logging --v=1 > "%~dp0..\artifacts\electron.log" 2>&1
