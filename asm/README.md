# KiloWallpaper — ASM 参考实现（MASM x64）

纯 MASM x64 汇编，**零 CRT**（不链 msvcrt / ucrt），只用 Windows 系统 DLL。
单文件 `main.asm`（4836 行）实现完整壁纸：桌面嵌入、图标层双向 z 序锚定、
配置热重载、退出握手、周期资源快照日志，以及**视频动态壁纸全链路**——
MF 解码（DXVA 硬解优先、软解自动回退）+ D3D11 + 视频处理器 +
DirectComposition 呈现 + 无缝循环。静态图渲染 CPU 精确为 0。

> 定位：五套实现里最特殊的一件——证明「桌面嵌入 + 视频播放」可以压进一份
> 零 CRT 的纯汇编。ml64 不支持 `invoke`，全部调用手写 x64 调用约定
> （全局参数槽 `g_a1..g_a10` + 手写栈布局）；COM 虚调用统一走
> `CC0..CC6` 助手（`g_a1`=对象、`g_a2`=vtable 槽位、`g_a3..`=参数）。

---

## 文件清单

| 文件 | 职责 |
| --- | --- |
| `main.asm` | 全部功能：入口、窗口与消息循环、看门狗、GDI+ 静态图、视频链（MF/D3D11/DXVA/DComp）、桌面嵌入、热重载、退出握手、资源快照 |
| `build.bat` | 编译（ml64 + link，零 CRT，vswhere 定位 MSVC） |
| `关闭壁纸.bat` | 优雅关闭（写 `wallpaper.quit` 握手） |
| `wallpaper.txt.example` | 素材路径配置模板 |

运行期生成（已被 .gitignore 忽略）：`DynamicWallpaper.exe`、`main.obj`、
`debug.log`、`wallpaper.embed`、`wallpaper.txt`。

## 编译与运行

```bat
build.bat                      rem vswhere 定位 MSVC + vcvarsall x64，产物 DynamicWallpaper.exe
DynamicWallpaper.exe           rem 直接双击运行；也可命令行指定素材（命令行优先）
```

配置：把 `wallpaper.txt.example` 复制为 `wallpaper.txt`（与 exe 同目录），
第一行写成素材路径（相对路径按 exe 所在目录解析）。视频（mp4/mkv/avi/wmv/
webm/m4v）走 D3D 播放链，图片走 GDI+；改第一行存盘约 3 秒内热切换，
不必重启；新素材打不开会自动保持上一个能放的素材。

**关闭**：双击 `关闭壁纸.bat`（写 `wallpaper.quit` → 主进程消费后正常退出）。
asm 版**没有守护进程**，不会被杀软互保，但请同样走握手而不要 `taskkill /f`——
与其余四套保持一致的习惯。嵌入成功的策略名也会写进 exe 同目录的
`wallpaper.embed`，在仓库根目录跑 `python tools\check_embed.py` 可自查。

**外部监控**（2026-10-21 加，补上"无守护"的缺口）：`monitor.ps1` 由计划任务
`KiloWallpaperMonitor` 每 2 分钟调用一次，检查五项并自愈——

| 检查 | 异常处置 |
| --- | --- |
| 进程存活 | 不在 → 经一次性计划任务重启（脱离调用方进程树） |
| 日志心跳 | `debug.log` 的 `[res]` 快照每 60s 一条，超 5 分钟无更新 = 消息循环卡死 → 重启 |
| CPU 停滞 | 心跳正常但 CPU 增量 < 间隔×1%（健康解码约 3~4%）→ 重启；睡眠间隔（>10min）跳过 |
| 新错误 | 只扫上次检查之后新增的日志行，命中 `failed` 记入监控日志 |
| z 序回归 | Progman 子窗口里 DefView 必须在壁纸窗口之上，否则图标被盖 → 重启重锚 |

事件与心跳全部记入 `asm/monitor.log`（`*.log` 已被 gitignore），状态基准
（时间/pid/CPU/行数）记 `asm/monitor.state`。手动跑一次：
`powershell -ExecutionPolicy Bypass -File asm\monitor.ps1`。

## 视频链实现要点（2026-10-20 实测对齐 c 版）

```
D3D11CreateDevice(VIDEO_SUPPORT|BGRA_SUPPORT)   失败退级 BGRA-only
  → QI ID3D10Multithread，SetMultithreadProtected(1)   MF 工作线程共用 device
  → QI ID3D11VideoDevice / ID3D11VideoContext
  → MFCreateDXGIDeviceManager + ResetDevice(device)
  → MFCreateSourceReaderFromByteStream（字节流打开，中文路径不走 FromURL）
      属性：MF_SOURCE_READER_D3D_MANAGER + MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS
      输出类型协商：DXVA 模式 RGB32 优先 / NV12 备选，软解模式相反
  → ReadSample 追帧（目标时间戳 = 起始墙钟 + 片长，每 tick 最多补 4 帧）
  → IMFDXGIBuffer 零拷贝：GetResource 拿 GPU 纹理 → VideoProcessorBlt
      （软解帧走 IMF2DBuffer/系统内存上传双路径）
  → 交换链（DXGI CreateSwapChainForComposition）+ DComp 设备/目标/视觉 → Present
  → EOS 无缝循环：SetCurrentPosition(0)，分级回退 seek(0)→seek(1)→重建 reader
```

日志关键行（`debug.log`，与 c 版逐字同格式）：

```
[embed] embed: progman-layered anchor hr=0x00000000
[d3d] swapchain: dcomp-model hr=0x00000000
[d3d] init ok 2560x1440 41ms NV12 DXVA hr=0x00000000
[d3d] frame: zerocopy path hr=0x00000000
[d3d] first present hr=0x00000000
[d3d] eos ts=10.16 loop=1 hr=0x00000000        rem 循环日志限频：首轮/每 500 轮/异常
```

实测资源占用与 c 版持平：稳态工作集约 15 MB（`SetProcessWorkingSetSize`
周期修剪），提交约 215 MB。

## x64 调用约定的坑（本文件最硬的实现约束）

手写栈布局的助手函数，`sub rsp` 量必须同时满足两条，缺一条就是静默崩：

1. **影子空间 ≥ 32 字节**：被调函数有权把 4 个寄存器参 spill 到
   `[rsp+8..rsp+40)`（入口视角）。只 `sub rsp,8` 的助手（如初代 CC0..CC3），
   被调函数的第 2 个 home slot 正好落在助手自己的返回地址上——
   d3d11 `SetMultithreadProtected` 一 spill 就把返回地址改成 rbp(0)，
   `ret` 后 rip=0、AV 现场 rsp 却停在调用者帧上，极难定位。
   正确量：`32 + N*8(栈参) + 8(对齐)`，即 S=0/1 用 `28h`、S=2/3 用 `38h`。
2. **调用点 rsp ≡ 0 (mod 16)**：入口 rsp ≡ 8，故减量须 ≡ 8 (mod 16)。
   `30h`(48) 这类"够大但 ≡0"的值会 misalign（曾发生在 CC5）。

另：`DCompositionCreateDevice` 首参是 IDXGIDevice **对象指针本身**而非
`&变量`；传错会被 dcomp 两层解引用后把 vtable 指针当函数调用（rip=vtable
数据地址）。`DCompositionCreateDevice(dxgiDev, &IID, &out)`。

## 与 cpp 版的差异

- 嵌入层级、`0x052C` 唤醒、DPI 感知（建窗前 `PER_MONITOR_AWARE_V2`）、
  双向 z 序锚定、配置热重载、退出握手、`[res]` 资源快照与 cpp 版同一套逻辑；
  视频链的格式协商 / 循环回退策略也与 c 版逐条对齐。
- 无守护进程：不提供 `DynamicWallpaperGuard.exe`，也没有开机自启脚本
  （开机自启用 `shell:startup` 里的 `动态壁纸.lnk`，现指向本目录 exe）。
- 全部调用手写，无 CRT、无 C 运行时依赖；`[res]` 快照经 `HWsprintfRes`
  手写格式化（`%.2f` 等价整数实现）。

## 已知限制

- **静态图在 Win11 24H2+ 的 raised desktop 上不显示画面**（2026-10-18 实测，
  与 c 版 GDI+ 路径同症状：对照实验截图字节级相同，只有图标和系统默认壁纸）。
  怀疑该桌面结构只合成 DX/DComp 内容、不合成 GDI+ 绘制内容。
  **视频（DComp）路径不受影响**：2026-10-20 实测全屏播放、硬解、循环正常，
  嵌入 / z 序 / 退出链路同样验证正常。
- 只铺主显示器；无托盘、无设置界面。
- 硬解依赖本机 GPU 的 DXVA 支持；失败时自动退软解（日志 `soft`），功能不减。

## 验证状态

本机（Win11 build 26300）实测通过：

- 静态图：嵌入、热重载、资源快照、退出握手（同 2026-10-18 结论）。
- 视频（2026-10-20）：2K(2560x1440) mp4 启动 → DXVA 硬解 → zerocopy →
  DComp 呈现 → 首帧 → EOS 无缝循环（10s 片，`loop=1` 后持续播放），
  稳态内存与 c 版持平；`wallpaper.quit` 握手干净退出；全屏截图确认画面可见。
- 图标层共存（2026-10-21）：修复 z 序锚定 bug 后，Progman 子窗口 z 序实测为
  `SHELLDLL_DefView(图标) → DynamicWallpaper(壁纸) → WorkerW(系统壁纸层)`，
  与 cpp 版逐项一致；最小化全部窗口截图确认桌面图标完整显示在壁纸之上。
  本机当前系统壁纸即 asm 版（自启 LNK 与登录计划任务均指向本目录）。
- 已修复的实现级 bug（均有现场证据）：CC0..CC3 影子空间不足致 rip=0 崩溃
  （cdb trace）、CC5 调用点 misalign、`gi_VideoDev` GUID 两字节错误、
  `DCompositionCreateDevice` 首参传错、`g_hwDecode` 标志误清零、
  **`EnsureWallpaperZOrder` 缓存路径寄存器复用**——`GetParent` 的返回值
  （父窗口 Progman）被当作 DefView/WorkerW 句柄传给 `SetWindowPos` 的
  `hWndInsertAfter`（非兄弟窗口，调用失败），壁纸留在图标层之上盖住桌面
  图标（2026-10-20 截图实证）；修为缓存命中时先把句柄换回 `rax`。
