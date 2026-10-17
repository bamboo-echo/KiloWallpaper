@echo off
rem ============================================================
rem  KiloWallpaper (C) - start
rem
rem  直接启动 DynamicWallpaper.exe（工作目录设为脚本所在目录，
rem  wallpaper.txt 与素材的相对路径都按它解析）。
rem  守护进程由主程序自动拉起，不需要手动开第二个。
rem
rem  注意：本脚本必须与 DynamicWallpaper.exe 放在同一目录
rem  （%~dp0 = 脚本所在目录 = exe 所在目录）。
rem ============================================================
setlocal
set "DIR=%~dp0"
if not exist "%DIR%DynamicWallpaper.exe" (
    echo [ERROR] 同目录下找不到 DynamicWallpaper.exe
    exit /b 1
)
start "" "%DIR%DynamicWallpaper.exe"
echo [OK] 壁纸已启动，约 1~3 秒后出画面。
endlocal
