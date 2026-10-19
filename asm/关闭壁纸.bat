@echo off
rem ============================================================
rem  KiloWallpaper (ASM) - graceful close
rem
rem  写 wallpaper.quit 标记文件，主进程轮询到后正常退出。
rem  asm 版没有守护进程，写完即生效，约 1~3 秒退出。
rem
rem  注意：本脚本必须与 DynamicWallpaper.exe 放在同一目录。
rem  %~dp0 = 脚本所在目录 = exe 所在目录。
rem  不要用 taskkill /f，请统一走握手退出。
rem ============================================================
setlocal
set "DIR=%~dp0"
if exist "%DIR%wallpaper.quit" del "%DIR%wallpaper.quit" >nul 2>&1
type nul > "%DIR%wallpaper.quit"
if errorlevel 1 (
    echo [ERROR] 无法写入 wallpaper.quit，请确认脚本与 exe 在同一目录且目录可写。
    exit /b 1
)
echo [OK] 已发送关闭请求，约 1~3 秒后壁纸退出。
endlocal
