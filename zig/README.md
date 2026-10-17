# KiloWallpaper — Zig 实现

用 Zig 直接调用 Win32 / COM，功能对齐 `cpp/`：桌面嵌入、DXVA 硬解视频、
GDI+ GIF、双进程守护、优雅关闭。**运行时零第三方依赖**（只链接系统 DLL）。

> 设计取舍：COM 接口（D3D11 / DXGI / DirectComposition / Media Foundation）的
> vtable 布局与 GUID 由 `@cImport` 直接翻译 Windows SDK 头文件得到——这些接口
> 方法索引极深，手写极易串位，SDK 头是唯一可靠来源。因此**编译期需要 Windows
> SDK 头文件**（运行时不需要），与 cpp 版的编译前提一致。

---

## 文件清单

| 文件 | 职责 |
| --- | --- |
| `src/main.zig` | 入口、窗口/消息循环、看门狗、帧调度、配置解析、单实例、守护互保 |
| `src/desktop.zig` | 桌面嵌入：Progman/WorkerW 探测、双向 z 锚定、`0x052C`、多级兜底 |
| `src/d3dplayer.zig` | 视频：MF SourceReader + DXVA + D3D11 VideoProcessor + DComp + 无缝循环 |
| `src/media.zig` | GDI+ 平面 API 解码 GIF/静态图，帧延时表 |
| `src/render.zig` | GIF 双缓冲绘制（cover） |
| `src/guard.zig` | 独立进程名守护进程 |
| `src/common.zig` | 共享状态、日志、pid/marker 文件、进程互认 |
| `src/win.zig` | `@cImport` 绑定层 + GDI+ flat API 声明 |

辅助：`build.zig`、`关闭壁纸.bat`。

---

## 编译与运行

前提：Zig 0.13+、Visual Studio 2017+（含 C++ 工具链）、Windows SDK 10。

**推荐**在「x64 Native Tools Command Prompt for VS」中执行（INCLUDE/LIB 已就绪）：

```bat
zig build
```

产物在 `zig-out\bin\`：

```
DynamicWallpaper.exe
DynamicWallpaperGuard.exe
```

运行：

```bat
zig-out\bin\DynamicWallpaper.exe "D:\videos\my_loop.mp4"
```

或把路径写进 exe 旁的 `wallpaper.txt`（见 `wallpaper.txt.example`）。

**关闭**：双击 `关闭壁纸.bat`（与 exe 同目录），写 `wallpaper.quit` →
主进程写 `wallpaper.graceful` → 守护退出。不要 `taskkill /f`。

---

## 实现要点（与 cpp 对齐）

- **桌面嵌入**：挂 Progman + `WS_EX_LAYERED`，插在 `SHELLDLL_DefView`（图标层）之后、
  系统 `WorkerW` 之前；嵌入前发 `0x052C` 唤醒 raised 状态；看门狗每 3 秒校准。
- **DPI**：建窗前 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`。
- **图标层零修改**。
- **视频**：DXVA 硬解 + DirectComposition 呈现 + EOS 分级无缝循环。
- **配置**：`wallpaper.txt` 首行、严格 UTF-8、容忍 BOM、相对路径按 exe 目录解析。
- **守护协议**：pid/marker 原子替换、`wallpaper.ok` 才保活、`graceful` 即退。

---

## ⚠️ 验证状态

**本机当前未安装 Zig 工具链，因此本实现尚未经过编译验证。** 代码按 Zig 0.13
语法与 Windows SDK 头文件接口编写，可能存在少量类型/调用约定细节需要按实际
编译器报错微调（尤其是 `callconv`、HWND 可空性与宏常量）。装好 Zig 后运行
`zig build` 即可暴露并定位这些问题。

C 版（`c/`）已在本机用 MSVC 完整编译通过；Zig 版与 C 版共享同一套接口语义。

## 已知限制

- 只铺主显示器（与 cpp 相同）。
- 无托盘、无设置界面、无音频、无播放列表。
- 编译期需要 Windows SDK；运行时零依赖。
