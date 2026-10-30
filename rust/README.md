# KiloWallpaper — Rust 实现

用 Rust 调用 Win32 / COM，功能对齐 `cpp/`：桌面嵌入、DXVA 硬解视频、GDI+ GIF、
双进程守护、优雅关闭。运行时只依赖系统 DLL。

> 依赖说明：本实现用 `windows` crate（0.58）做 Win32 / COM 绑定。它是唯一的
> 外部 crate（编译期代码生成 + 链接系统 DLL，运行时不额外依赖）。之所以不用
> `windows-sys`，是因为后者 0.61 不含 Direct3D11 / Dxgi / MediaFoundation /
> DirectComposition 的 COM 接口定义。本机已缓存该 crate，可用
> `cargo build --offline`；换机器首次构建时 cargo 会联网拉取一次（属下载行为）。

---

## 文件清单

| 文件 | 职责 |
| --- | --- |
| `src/lib.rs` | 公共库（供两个 bin 共用） |
| `src/bin/main.rs` | 主进程：入口/窗口/看门狗/帧调度/配置/单实例/守护互保 |
| `src/bin/guard.rs` | 独立进程名守护进程 |
| `src/desktop.rs` | 桌面嵌入：Progman/WorkerW、双向 z 锚定、`0x052C`、兜底 |
| `src/d3dplayer.rs` | 视频：MF SourceReader + DXVA + D3D11 VideoProcessor + DComp + 无缝循环 |
| `src/media.rs` | GDI+ 平面 API 解码 GIF/静态图 |
| `src/render.rs` | GIF 双缓冲绘制（cover） |
| `src/common.rs` | 日志、exe 目录、pid/marker 原子替换、配置解析、进程互认/拉起、单实例、重启管理器 |
| `src/state.rs` | 跨模块共享状态（Cell/RefCell 收敛可变全局） |

辅助：`Cargo.toml`、`关闭壁纸.bat`。

---

## 编译与运行

```bash
cargo build --release --offline
```

产物：

```
target\release\DynamicWallpaper.exe
target\release\DynamicWallpaperGuard.exe
```

运行：

```bat
target\release\DynamicWallpaper.exe "D:\videos\my_loop.mp4"
```

或把路径写进 exe 旁的 `wallpaper.txt`（见 `wallpaper.txt.example`）。

**关闭**：把 `关闭壁纸.bat` 与 exe 放同目录，双击（写 `wallpaper.quit` →
主进程写 `wallpaper.graceful` → 守护退出）。不要 `taskkill /f`。

---

## 实现要点（与 cpp 对齐）

- **桌面嵌入**：挂 Progman + `WS_EX_LAYERED`，插在 `SHELLDLL_DefView` 之后、
  系统 `WorkerW` 之前；嵌入前发 `0x052C`；看门狗每 3 秒校准。
- **DPI**：建窗前 `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`。
- **图标层零修改**。
- **视频**：DXVA 硬解（`MF_SOURCE_READER_D3D_MANAGER` + `IMFDXGIDeviceManager`），
  `ID3D10Multithread` 保护；DirectComposition 呈现；EOS 分级无缝循环。
- **配置**：`wallpaper.txt` 首行、严格 UTF-8、容忍 BOM、相对路径按 exe 目录解析。
- **守护协议**：pid/marker 原子替换、`wallpaper.ok` 才保活、`graceful` 即退。

## 安全性

unsafe 的 Win32 / COM 调用收敛在各模块内部（`d3dplayer.rs` / `desktop.rs` /
`render.rs` / `common.rs`），业务逻辑以安全代码为主；全局可变状态用
`Cell` / `RefCell` 收敛在 `state.rs`，避免 unsafe 散落。

## 验证状态

`cargo build --release --offline` 已在本机编译通过（`windows` 0.58.0 本地缓存，无联网下载）：

| 产物 | 大小 |
| --- | ---: |
| `DynamicWallpaper.exe` | 192,512 B |
| `DynamicWallpaperGuard.exe` | 134,656 B |

运行时链路与 C 版一致：DXVA 硬解 → VideoProcessor → DirectComposition → vsync，
8ms 追帧调度、5 秒后 `SetProcessWorkingSetSize` 归还工作集、日志限频。
二进制比 C 版大来自 Rust std 静态链接，不影响运行时 CPU / 内存 / GPU 占用。

## 已知限制

- 只铺主显示器（与 cpp 相同）。
- 无托盘、无设置界面、无音频、无播放列表。
