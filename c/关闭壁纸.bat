@echo off
rem ============================================================
rem  KiloWallpaper (C) - graceful close
rem
rem  写 wallpaper.quit 标记文件，主进程看门狗消费后正常退出，
rem  并写 wallpaper.graceful 通知守护进程一起退出。
rem
rem  注意：本脚本必须与 DynamicWallpaper.exe 放在同一目录
rem  （%~dp0 = 脚本所在目录 = exe 所在目录）。
rem  不要用 taskkill /f：守护进程会在 1 秒内把壁纸拉回来。
rem ============================================================
setlocal
set "DIR=%~dp0"
rem 先删残留的 graceful，避免本次关闭被旧标记干扰
if exist "%DIR%wallpaper.graceful" del "%DIR%wallpaper.graceful" >nul 2>&1
type nul > "%DIR%wallpaper.quit"
if errorlevel 1 (
    echo [ERROR] 无法写入 wallpaper.quit，请确认脚本与 exe 在同一目录且目录可写。
    exit /b 1
)
echo [OK] 已发送关闭请求，约 1~3 秒后壁纸与守护进程一起退出。
endlocal
