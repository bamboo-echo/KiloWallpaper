@echo off
rem ============================================================
rem  KiloWallpaper - build script (MASM x64, ml64)
rem
rem  Produces, in this folder:
rem    DynamicWallpaper.exe    main wallpaper process (static image)
rem
rem  The toolchain is located with vswhere.exe, so ANY Visual Studio
rem  2017+ edition works (Community / Professional / Enterprise /
rem  Build Tools). No third-party library, no CMake, no vcpkg.
rem  No CRT: ml64 + link only, all runtime calls are Win32/GDI+ imports.
rem  Environment is initialised with vcvarsall (sets INCLUDE/LIB for
rem  the Windows SDK import libs like user32.lib).
rem ============================================================
setlocal
cd /d "%~dp0"

set "PF86=%ProgramFiles(x86)%"
set "VSWHERE=%PF86%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSPATH="

if not exist "%VSWHERE%" goto try_known
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if defined VSPATH goto found
:try_known
for %%e in (Community Professional Enterprise BuildTools) do if exist "%ProgramFiles%\Microsoft Visual Studio\2022\%%e\VC\Auxiliary\Build\vcvarsall.bat" set "VSPATH=%ProgramFiles%\Microsoft Visual Studio\2022\%%e"
for %%e in (Community Professional Enterprise BuildTools) do if exist "%ProgramFiles%\Microsoft Visual Studio\2019\%%e\VC\Auxiliary\Build\vcvarsall.bat" set "VSPATH=%ProgramFiles%\Microsoft Visual Studio\2019\%%e"
if defined VSPATH goto found
echo [ERROR] MSVC toolchain not found.
echo         Install "Visual Studio 2017+" or "Build Tools for Visual Studio"
echo         with the "Desktop development with C++" workload, then retry.
exit /b 1

:found
echo [toolchain] %VSPATH%
call "%VSPATH%\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul 2>&1
if errorlevel 1 goto nocall

echo [1/2] assembling main.asm
ml64 /nologo /c /Fo main.obj main.asm
if errorlevel 1 goto buildfail

echo [2/2] linking
link /nologo /SUBSYSTEM:WINDOWS /ENTRY:start ^
    main.obj ^
    user32.lib gdi32.lib gdiplus.lib kernel32.lib psapi.lib ^
    /OUT:DynamicWallpaper.exe
if errorlevel 1 goto buildfail

echo [OK] DynamicWallpaper.exe built
goto done

:nocall
echo [ERROR] failed to initialise the MSVC environment:
echo         %VSPATH%\VC\Auxiliary\Build\vcvarsall.bat
exit /b 1

:buildfail
echo [ERROR] assembly or link failed
exit /b 1

:done
del main.obj >nul 2>&1
endlocal
