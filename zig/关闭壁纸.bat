@echo off
rem ============================================================
rem  KiloWallpaper (Zig) - graceful close
rem
rem  写 wallpaper.quit，主进程消费后正常退出并写 wallpaper.graceful，
rem  守护进程随之退出。不要用 taskkill /f（守护会在 1 秒内拉回）。
rem
rem  本脚本需与 DynamicWallpaper.exe 放在同一目录。
rem  若 exe 在 zig-out\bin\，请把本脚本一起复制过去再运行。
rem ============================================================
setlocal
set "DIR=%~dp0"
if exist "%DIR%wallpaper.graceful" del "%DIR%wallpaper.graceful" >nul 2>&1
type nul > "%DIR%wallpaper.quit"
if errorlevel 1 (
    echo [ERROR] 无法写入 wallpaper.quit，请确认脚本与 exe 在同一目录且目录可写。
    exit /b 1
)
echo [OK] 已发送关闭请求，约 1~3 秒后壁纸与守护进程一起退出。
endlocal
