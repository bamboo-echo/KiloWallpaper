# KiloWallpaper — C 参考实现

纯 C（C11）直接调用 Win32 API，**零第三方依赖**（只链接 Windows 系统 DLL），
与 `cpp/` 版功能等价：桌面嵌入、DXVA 硬解视频、GDI+ GIF、双进程守护、优雅关闭、
配置热重载（3 秒内换素材）、`wallpaper.embed` 策略标记、周期资源快照日志
（每 60s 记录工作集/提交/句柄/GDI/USER 对象数，排查内存泄漏用）。

> 这份实现的目的是证明同一套桌面嵌入与视频呈现链路在 **纯 C** 下同样成立：
> COM 接口手写 vtable、GDI+ 用 flat API、Media Foundation 属性用 `GetUINT64` 拆包。

---

## 文件清单

| 文件 | 职责 |
| --- | --- |
| `main.c` | 入口、窗口与消息循环、看门狗、渲染调度、配置解析、单实例、守护互保 |
| `desktop.c` | 桌面嵌入：Progman/WorkerW 探测、双向 z 序锚定、`0x052C` 唤醒、多级兜底 |
| `d3dplayer.c` | 视频链路：MF `SourceReader` + DXVA 硬解 + D3D11 VideoProcessor + DirectComposition + 无缝循环 |
| `media.c` | GIF / 静态图解码（GDI+ flat API），帧延时表 |
| `render.c` | GIF 帧绘制与双缓冲后备缓冲 |
| `guard.c` | 独立进程名守护（`DynamicWallpaperGuard.exe`） |
| `wallpaper.h` | 跨模块声明与 GDI+ flat API 垫片 |
| `d3dplayer.h` | 视频播放器对外接口 |

辅助：`build.bat`（编译）、`开启壁纸.bat`（启动）、`关闭壁纸.bat`（优雅关闭）。

---

## 编译与运行

```bat
build.bat                 rem 用 vswhere 定位 MSVC，编译两个 exe
DynamicWallpaper.exe "D:\videos\my_loop.mp4"   rem 命令行指定素材
```

或把素材路径写进 exe 旁的 `wallpaper.txt`（复制 `wallpaper.txt.example` 后修改）。

**关闭**：双击 `关闭壁纸.bat`（写 `wallpaper.quit` → 主进程消费 → 写 `wallpaper.graceful` → 守护退出）。
**不要 `taskkill /f`**：守护进程会在 1 秒内拉起，重启管理器也会复活。

---

## 与 cpp 版的实现差异（关键点）

| 主题 | cpp 版 | C 版 |
| --- | --- | --- |
| COM 调用 | `p->Method(args)` 隐式 this | `COMCALL(p, Method, args...)` = `p->lpVtbl->Method(p, args...)`，手写 vtable |
| DirectComposition | 直接 `#include <dcomp.h>` | SDK 的 `dcomp.h` 在 C 下无法包含（多重继承展开后成员重定义），手写 3 个接口的最小 vtable（偏移与真实接口一致） |
| GDI+ | C++ `Image` 类 | flat API：`GdipLoadImageFromFile` / `GdipImageGetFrameDimensionsCount` / `GdipImageGetFrameDimensionsList` 等（注意帧维度函数带 `Image` 前缀） |
| MF 属性 | `MFGetAttributeSize` / `MFGetAttributeRatio` | 这两个辅助函数**不在** mfplat/mfreadwrite 导入库（实测链接失败），改用 `IMFAttributes::GetUINT64` 手动拆包（高/低 32 位） |
| 内存管理 | RAII / 析构 | 手动 `malloc/free` + COM `Release`，退出路径统一释放 |

## 已落实的关键踩坑（与 cpp 完全一致）

- **桌面嵌入**：挂 Progman + `WS_EX_LAYERED`，插在 `SHELLDLL_DefView`（图标层）之后、系统 `WorkerW` 之前；嵌入前发 `0x052C` 唤醒 raised 状态；看门狗每 3 秒校准、`WorkerW` 消失时 5 秒限频重发。
- **DPI**：建窗前设 `PER_MONITOR_AWARE_V2`，否则跨 DPI 嵌入纯黑。
- **图标层零修改**：不改 `SysListView32` / `SHELLDLL_DefView` 任何属性。
- **视频**：DXVA 硬解（`MF_SOURCE_READER_D3D_MANAGER` + `IMFDXGIDeviceManager`），`ID3D10Multithread` 保护；DirectComposition 呈现；EOS → `SetCurrentPosition(0)` → `seek(1)` → 重建 reader 的分级无缝循环。
- **配置**：`wallpaper.txt` 只读首行，严格 UTF-8（非法编码直接判配置无效），容忍 BOM，相对路径按 exe 目录解析。
- **守护协议**：pid/marker 文件先写 `.tmp` 再 `MoveFileExW` 原子替换；主进程写 `wallpaper.ok` 后守护才保活；`wallpaper.quit` 由主进程消费，守护不代删。

## 已知限制

- 只铺主显示器（与 cpp 相同）。
- 无托盘、无设置界面、无音频、无播放列表。
- 本机编译需 Visual Studio 2017+（含 C 工具链）与 Windows SDK 10。
