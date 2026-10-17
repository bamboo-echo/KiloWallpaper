// build.zig - KiloWallpaper (Zig) 构建脚本
//
// 产出两个 exe（对齐 cpp/）：
//   DynamicWallpaper.exe       主壁纸进程
//   DynamicWallpaperGuard.exe  独立进程名守护进程
//
// 前提（与 cpp 相同）：Windows 10 1809+ / Windows 11，安装 Visual Studio 2017+
// 与 Windows SDK 10。Zig 的 @cImport 需要 SDK 头文件，链接需要 SDK/MSVC 的 .lib。
// 建议在「x64 Native Tools Command Prompt for VS」中运行 `zig build`，
// 这样 INCLUDE / LIB 环境变量已就绪；否则请手动设置后再运行。
//
// 本项目运行时零第三方依赖（只链接系统 DLL）。
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const main_exe = b.addExecutable(.{
        .name = "DynamicWallpaper",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_exe.subsystem = .Console;
    linkWin(main_exe);
    b.installArtifact(main_exe);

    const guard_exe = b.addExecutable(.{
        .name = "DynamicWallpaperGuard",
        .root_source_file = b.path("src/guard.zig"),
        .target = target,
        .optimize = optimize,
    });
    guard_exe.subsystem = .Console;
    linkWin(guard_exe);
    b.installArtifact(guard_exe);
}

fn linkWin(exe: *std.Build.Step.Compile) void {
    // 系统 DLL 导入库（与 cpp/build.bat 的链接列表对齐）
    const libs = [_][]const u8{
        "user32", "gdi32", "gdiplus", "mfplat", "mfreadwrite",
        "d3d11", "dxgi",      "dcomp",  "shlwapi", "ole32",      "comctl32",
        "uxtheme", "advapi32", "shell32", "kernel32",
    };
    for (libs) |l| exe.linkSystemLibrary(l);
    exe.linkLibC();
}
