@echo off
rem ============================================================
rem  KiloWallpaper - install / refresh helper
rem
rem  1. build the binaries when they are missing
rem  2. stop a running instance THE GRACEFUL WAY
rem  3. copy the close-script to the Desktop
rem  4. write / refresh the Start-up shortcut
rem  5. start the wallpaper
rem
rem  The Desktop copy is a plain byte-for-byte copy: the close-script
rem  locates the install folder by itself at run time, so no path is
rem  baked into it (a baked non-ASCII path would break on UTF-8
rem  consoles - see the notes inside the close-script).
rem
rem  NOTE: never replace step 2 with
rem          taskkill /f /im DynamicWallpaper.exe
rem  A hard kill CANNOT close this wallpaper: the guard process
rem  relaunches it within ~1 second, and the Windows Restart Manager
rem  may revive it as well. Only the marker-file handshake works.
rem ============================================================
setlocal
cd /d "%~dp0"

if not exist "DynamicWallpaper.exe" (
    call "%~dp0build.bat"
    if errorlevel 1 exit /b 1
)

set "DW_EXE=%~dp0DynamicWallpaper.exe"
set "DW_DIR=%~dp0"

rem ---- 1. graceful stop: drop the quit marker, then wait for exit ----
type nul > "%~dp0wallpaper.quit"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$n=0; while($n -lt 40){ if(-not (Get-Process DynamicWallpaper -ErrorAction SilentlyContinue)){ break }; Start-Sleep -Milliseconds 250; $n++ }"

rem ---- 2. Desktop copy of the close-script + Start-up shortcut + launch ----
rem  File names containing CJK are built from code points so that this
rem  script itself stays pure ASCII (code-page safe).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$dir=$env:DW_DIR.TrimEnd([char]92); $exe=$env:DW_EXE; $close=-join [char[]](0x5173,0x95ED,0x58C1,0x7EB8)+'.bat'; Copy-Item -LiteralPath (Join-Path $dir $close) -Destination (Join-Path ([Environment]::GetFolderPath('Desktop')) $close) -Force; $lnkName=-join [char[]](0x52A8,0x6001,0x58C1,0x7EB8)+'.lnk'; $sh=New-Object -ComObject WScript.Shell; $lnk=$sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) $lnkName)); $lnk.TargetPath=$exe; $lnk.WorkingDirectory=$dir; $lnk.WindowStyle=1; $lnk.Save(); Start-Process -FilePath $exe -WorkingDirectory $dir"

endlocal
