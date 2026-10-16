@echo off
rem ============================================================
rem  KiloWallpaper - close the wallpaper (graceful shutdown).
rem
rem  How it works:
rem    We only create the marker file "wallpaper.quit" next to the
rem    exe. The main process polls it, then exits with code 0 and
rem    writes "wallpaper.graceful" so the guard process exits too.
rem
rem  NEVER replace this with "taskkill /f /im DynamicWallpaper.exe":
rem    - the guard process (DynamicWallpaperGuard.exe) relaunches the
rem      wallpaper within ~1 second, and
rem    - the Windows Restart Manager may revive it as well.
rem    That is why a hard kill cannot close this wallpaper.
rem
rem  Finding the install folder - two ways, tried in order:
rem    1. %~dp0, for this copy, which sits next to the exe.
rem    2. the image path of the running process, for the copy that
rem       setup.bat places on the Desktop.
rem    Nothing is baked into this file on purpose: a literal install
rem    path would be stored as raw bytes, and cmd.exe decodes .bat
rem    bytes with the console code page (65001 on UTF-8 systems),
rem    which corrupts non-ASCII paths such as ...\dp1\<chinese>\...
rem    The runtime lookup below is code-page independent.
rem ============================================================
setlocal
set "DW_DIR=%~dp0"
if exist "%DW_DIR%DynamicWallpaper.exe" (
    type nul > "%DW_DIR%wallpaper.quit"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=Get-Process DynamicWallpaper -ErrorAction SilentlyContinue | Select-Object -First 1; $d=$null; if($p){ try { $d=Split-Path $p.Path } catch {} }; if($d){ [IO.File]::WriteAllText((Join-Path $d 'wallpaper.quit'),'') } else { Write-Host 'DynamicWallpaper is not running - nothing to close.' }"
)
endlocal
