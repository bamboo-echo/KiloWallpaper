@echo off
rem ============================================================
rem  KiloWallpaper - uninstall helper
rem
rem  1. stop the wallpaper THE GRACEFUL WAY
rem  2. delete the Start-up shortcut
rem  3. delete the copy of the close-script on the Desktop
rem
rem  Afterwards you can simply delete this folder. This project
rem  writes nothing to the registry, installs no service and no
rem  scheduled task, so there is nothing else to clean up.
rem ============================================================
setlocal
cd /d "%~dp0"

rem ---- 1. graceful stop ----
type nul > "%~dp0wallpaper.quit"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$n=0; while($n -lt 40){ if(-not (Get-Process DynamicWallpaper -ErrorAction SilentlyContinue)){ break }; Start-Sleep -Milliseconds 250; $n++ }"

rem ---- 2. + 3. remove Start-up shortcut and Desktop close-script ----
rem 用 %~dp0 显式锚定：Desktop/Startup 的路径必须是绝对路径。
rem 教训：旧版用裸文件名（相对路径），而本脚本从 cpp\ 运行时，相对路径
rem 会解析成 cpp\关闭壁纸.bat —— 把项目自己的关闭脚本当桌面副本删了。
rem 现在通过 -join 码点构造文件名，再用 [Environment]::GetFolderPath 拼绝对路径，
rem 绝不碰相对路径。
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$close=-join [char[]](0x5173,0x95ED,0x58C1,0x7EB8)+'.bat'; $desk=[Environment]::GetFolderPath('Desktop'); if ($desk) { $p=Join-Path $desk $close; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host ('removed '+$p) } else { Write-Host ('absent  '+$p) } } else { Write-Host ('WARN: Desktop folder not resolvable, skip') }; $lnkName=-join [char[]](0x52A8,0x6001,0x58C1,0x7EB8)+'.lnk'; $st=[Environment]::GetFolderPath('Startup'); if ($st) { $l=Join-Path $st $lnkName; if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l -Force; Write-Host ('removed '+$l) } else { Write-Host ('absent  '+$l) } } else { Write-Host ('WARN: Startup folder not resolvable, skip') }"

echo [OK] stopped and autostart removed. You may now delete this folder.
endlocal
