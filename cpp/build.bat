@echo off
rem ============================================================
rem  KiloWallpaper - build script (MSVC, x64)
rem
rem  Produces, in this folder:
rem    DynamicWallpaperGuard.exe  companion guard process (separate process name)
rem    DynamicWallpaper.exe       main wallpaper process
rem
rem  The toolchain is located with vswhere.exe, so ANY Visual Studio
rem  2017+ edition works (Community / Professional / Enterprise /
rem  Build Tools). No third-party library, no CMake, no vcpkg.
rem ============================================================
setlocal
cd /d "%~dp0"

set "PF86=%ProgramFiles(x86)%"
set "VSWHERE=%PF86%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCVARS="

if not exist "%VSWHERE%" goto try_known
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if defined VSPATH set "VCVARS=%VSPATH%\VC\Auxiliary\Build\vcvarsall.bat"
if exist "%VCVARS%" goto build

:try_known
for %%e in (Community Professional Enterprise BuildTools) do call :probe "%ProgramFiles%\Microsoft Visual Studio\2022\%%e\VC\Auxiliary\Build\vcvarsall.bat"
if exist "%VCVARS%" goto build
for %%e in (Community Professional Enterprise BuildTools) do call :probe "%ProgramFiles%\Microsoft Visual Studio\2019\%%e\VC\Auxiliary\Build\vcvarsall.bat"
if exist "%VCVARS%" goto build
goto novs

:probe
if exist "%~1" set "VCVARS=%~1"
goto :eof

:novs
echo [ERROR] MSVC toolchain not found.
echo         Install "Visual Studio 2017+" or "Build Tools for Visual Studio"
echo         with the "Desktop development with C++" workload, then retry.
exit /b 1

:build
echo [toolchain] %VCVARS%
call "%VCVARS%" x64 >nul 2>&1
if errorlevel 1 goto nocall

echo [1/2] DynamicWallpaperGuard.exe
cl /nologo /O2 /EHsc /MD /DUNICODE /D_UNICODE guard.cpp /link /SUBSYSTEM:WINDOWS /OUT:DynamicWallpaperGuard.exe
if errorlevel 1 goto buildfail

echo [2/2] DynamicWallpaper.exe
cl /nologo /O2 /EHsc /MD /DUNICODE /D_UNICODE main.cpp media.cpp render.cpp desktop.cpp d3dplayer.cpp /link /SUBSYSTEM:WINDOWS user32.lib gdi32.lib gdiplus.lib mfplat.lib mfreadwrite.lib mfuuid.lib d3d11.lib dxgi.lib shlwapi.lib ole32.lib comctl32.lib uxtheme.lib /OUT:DynamicWallpaper.exe
if errorlevel 1 goto buildfail

echo [OK] DynamicWallpaper.exe + DynamicWallpaperGuard.exe built
goto done

:nocall
echo [ERROR] failed to initialise the MSVC environment:
echo         %VCVARS%
exit /b 1

:buildfail
echo [ERROR] compilation failed
exit /b 1

:done
endlocal
