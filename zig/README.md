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

## 验证状态

已在本机编译通过并实测播放（Zig 0.13.0 + MSVC/SDK 环境，
`zig build -Doptimize=ReleaseFast`）：桌面嵌入、DXVA 硬解（NV12）、
DirectComposition 呈现、无缝循环、GIF、配置热重载、退出握手均验证正常。
产物约 639 KB / 552 KB（主程序 / 守护）。

**已知情况：内存比其他三套高约 88 MB。** 已排查到底：跳过 MF 解码器
（`KW_NO_READER=1`）提交内存从 301 MB 掉到 28 MB，两块大内存块同时消失；
MF 属性、D3D 设备参数、COM 生命周期逐项与 C 版比对无区别，差异在 MF 运行时
内部分配 surface 池的行为上，应用层没有安全的改法。这是对照实现的已知情况，
不是 bug，也修不动（详见根 README「多语言实现对照」）。

## 已知限制

- 只铺主显示器（与 cpp 相同）。
- 无托盘、无设置界面、无音频、无播放列表。
- 编译期需要 Windows SDK；运行时零依赖。
