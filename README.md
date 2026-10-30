# KiloWallpaper

[![build](https://github.com/bamboo-echo/KiloWallpaper/actions/workflows/build.yml/badge.svg)](https://github.com/bamboo-echo/KiloWallpaper/actions/workflows/build.yml)

**下载**：[Releases](https://github.com/bamboo-echo/KiloWallpaper/releases/latest) 提供五套实现的
即用 exe（主程序 + 守护成对，解压即用，不装任何运行时）。文件名带语言前缀：
`DynamicWallpaper-cpp.exe` / `-c.exe` / `-rust.exe` / `-zig.exe` / `-asm.exe`。
自己日常用选 **c 版**（视频方案里体积最小、CPU 最低）；以 **cpp 版**为参考基准（本文数字由它产出）。
换素材：编辑 exe 旁的 `wallpaper.txt` 首行，3 秒内热切换。

用 Win32 原生 API 手写的极简动态壁纸。**播放 2K 视频时只占一个逻辑核的约 2~4%，
常驻内存约 6.5 MB** —— 「极小占用」说的是这个**运行时开销**，不是文件大小。

> 这是一份**最小可读的 Windows 桌面嵌入参考实现**：
> 2021 行 C++ 串起 DXVA 硬解 → DirectComposition 零拷贝呈现 → Progman/WorkerW 嵌入 →
> 图标层双向 z 序锚定 → 双进程守护。功能刻意做得少，代码刻意写得短。
> 可执行文件名仍为 `DynamicWallpaper.exe` / `DynamicWallpaperGuard.exe`。

---

## 特点一：运行时开销极小（实测）

**这里的「极小占用」指程序跑起来后的资源消耗** —— CPU、内存、GPU。
和二进制文件多大是两回事，不要混淆。

测试条件：Windows 11 (build 26300)，32 逻辑核，2560×1600 屏（150% 缩放），播放 2560×1440
10 秒循环 H.264 视频，20 秒采样窗口，取稳定运行阶段数值。**均为本机实测，非普适性能保证。**

| 运行时指标 | 实测 | 备注 |
| --- | --- | --- |
| CPU（主进程） | **2.3 ~ 4.1 % 单核 / 0.07 ~ 0.13 % 整机** | 20 s 内累计 453~828 ms（随画面内容波动） |
| CPU（守护进程） | **0.00 %** | 1 秒拍空闲轮询 |
| 常驻内存 | **~6.5 MB** | 即任务管理器「内存」列 / 专用工作集 `WorkingSetPrivate` |
| GPU `video` 引擎 | **13.9 %**（`3d` 15.2 %） | 出现 `video` 引擎即证明走 **DXVA 硬解**，解码在 GPU 上 |
| 内存 · 工作集 | 12 ~ 20 MB | |
| 内存 · 提交 | 213 ~ 219 MB | D3D11/DXVA 解码器预留面池；5 分钟 30 点采样净 −0.08 MB，不是泄漏 |
| 句柄 / 线程 | 1073 / 42 | |

作为对比：Electron / WebView2 类方案光**运行时**常驻内存就要 100 MB 以上，
CPU 也是一个核跑不满。这里整个程序（含守护进程）常驻约 6.5 MB。

> 内存那一行有一个实现细节要说明：程序在播放稳定 **5 秒后主动调用
> `SetProcessWorkingSetSize(-1,-1)` 归还备用页**（`d3dplayer.cpp` 的延迟 trim）。
> 所以任务管理器里的 ~6.5 MB 是 trim 之后的读数；提交内存 213~219 MB 才是
> DXVA 解码器面池的真实预留量，两者并不矛盾。

## 特点二：可执行文件本身也很小

项目名 **Kilo**-Wallpaper 就是从「主程序 70 KB 级（kilobyte 级）」来的。
这一项是**磁盘占用**，和上面的运行时开销是两个独立指标：

| 磁盘指标 | 大小 | 备注 |
| --- | ---: | --- |
| 主程序二进制 | **70.0 KB**（71,680 B） | MSVC `/O2`，只链接 Windows 系统 DLL |
| 守护进程二进制 | **29.0 KB**（29,696 B） | |
| **两个合计** | **99.0 KB** | 加上配置文件与脚本，整个目录约 100 KB 量级 |

（小提示：不同 MSVC 补丁版本生成的 exe 会差几百字节，属正常现象。）

### 其他特点

- **零第三方依赖**：只用 Windows SDK 与系统 DLL（`user32` `gdi32` `gdiplus` `mfplat`
  `mfreadwrite` `d3d11` `dxgi` `dcomp` `shlwapi` `ole32` `comctl32` `uxtheme`），没有 NuGet、没有 vcpkg、没有 CMake。
- **硬件解码 + 零拷贝优先**：视频走 Media Foundation + D3D11 DXVA 硬解。首选路径把
  解码器输出的 GPU 纹理直接建 VideoProcessor 输入视图（零拷贝，实测日志 `zerocopy path`）；
  零拷贝不可用时自动回退到系统内存 `UpdateSubresource` 上传路径。全程不做 CPU 读回。
- **真正嵌进桌面**：窗口 `SetParent` 到 Explorer 的 `Progman` 下，
  把壁纸窗口排在图标层 `SHELLDLL_DefView` 之后、系统壁纸层 `WorkerW` 之前（双向 z 序锚定），
  **图标始终显示在壁纸之上**，桌面右键、拖动图标都正常。
- **无缝循环**：交换链全程保留上一帧，`SetCurrentPosition(0)` 失败时分级回退，
  不可能闪出系统壁纸。
- **改配置即换壁纸（热重载）**：直接改 `wallpaper.txt` 第一行，3 秒内自动切换，
  **不必关闭壁纸、不必重启进程**。新素材打不开会自动回滚到上一个能放的素材，不会黑屏；
  启动时用命令行指定了素材则以命令行为准（命令行优先），此时不响应配置改动。
- **无广告、无 UAC、无网络、无遥测**：程序不发起任何网络请求。

---

## 多语言实现对照

仓库里有**五套**独立实现，都只用 Windows 系统 DLL，运行时不依赖任何第三方库。
共享同一套约定：配置文件 `wallpaper.txt`（放可执行文件旁边，不入库）、
窗口类名 `DynamicWallpaper`、退出握手 `wallpaper.quit` → `wallpaper.graceful`。

| 目录 | 语言 | 主程序 / 守护 | 体积合计 | 验证状态 |
| --- | --- | ---: | ---: | --- |
| [`cpp/`](cpp/) | C++ | 70.0 KB / 29.0 KB | **99.0 KB** | 本机全功能实测，本文性能数字由它产出 |
| [`c/`](c/) | C | 41.0 KB / 13.5 KB | 54.5 KB | 本机实测：视频、GIF、热重载、资源快照日志 |
| [`rust/`](rust/) | Rust | 188.0 KB / 131.5 KB | 319.5 KB | 编译通过，本机播放实测（NV12 DXVA） |
| [`zig/`](zig/) | Zig | ~639 KB / ~552 KB | ~1.16 MB | 编译通过，本机播放实测；内存比其他三套高约 88 MB，原因见下 |
| [`asm/`](asm/) | MASM x64 | 41.5 KB / — | **41.5 KB** | 本机实测：嵌入、热重载、资源快照、退出握手；**视频动态壁纸全链路**（2026-10-20：2K mp4、DXVA 硬解、DComp 呈现、无缝循环，截图确认全屏播放）；**图标层共存**（2026-10-21：z 序锚定修复后桌面图标完整显示在壁纸之上，与 cpp 逐项一致）；**静态图渲染在 Win11 24H2+ raised desktop 上不可见**（与 c 版 GDI+ 路径同症状，见下） |

**请以 `cpp/` 为准**：本文「特点一」里的 CPU / 内存数字、目录内的诊断工具链，
都以它为准。`c/`、`rust/`、`zig/`、`asm/` 是为了对照同一个问题在不同语言下的解法：
COM 接口怎么手写 vtable、Media Foundation 属性怎么拆包、DirectComposition 怎么接——
功能与 cpp 对齐，但不承诺运行时一致，也别拿它们的体积去跟 cpp 比"谁写得好"。

`c/` 早期是 cpp 去掉热重载前的快照，现在功能已经追平（热重载和 `wallpaper.embed`
标记是后来补的）。体积比 cpp 小 44%，来自 C++ 的异常/RTTI/iostream 开销，
不是写法更优。

`asm/` 是五套里最特殊的一件：**纯 MASM x64 汇编写成，零 CRT**（不链 msvcrt/ucrt），
ml64 不支持 `invoke`，全部调用手写 x64 调用约定（全局参数槽 + 手写栈布局）。
2026-10-20 补齐**视频动态壁纸全链路**（MF 解码 DXVA 硬解 / 软解回退 + D3D11 +
视频处理器 + DirectComposition 呈现 + 无缝循环），与 c 版逐条对齐；静态图路径
CPU 精确为 0。它是「最小可读的桌面嵌入 + 视频播放参考实现」：嵌入层级、0x052C
唤醒、DPI 感知、配置热重载、退出握手、`[res]` 资源快照全部都在，单文件 4836 行。
手写 x64 调用约定最硬的两个约束（助手函数影子空间 ≥32 字节、调用点 16 对齐）
及踩坑记录见 `asm/README.md`。

> **已知限制（2026-10-18 实测）**：asm 与 c 版的 **GDI+ 静态图路径在 Win11 24H2+
> 的 raised desktop 上不显示画面**（对照实验截图字节级相同：只有图标和系统默认
> 壁纸），而 DComp 视频路径有 GPU 负载证明正常合成——怀疑该桌面结构只合成
> DX/DComp 内容、不合成 GDI+ 绘制内容。嵌入/z 序/退出链路本身全部验证正常。

四套在同一素材（2560×1440 / 24fps）下实测，取 trim 之后的稳定段：

| 实现 | CPU 单核 | 工作集 | 私有提交 | 二进制 |
| --- | ---: | ---: | ---: | ---: |
| cpp | 3.97% | 7.0 MB（专用） | 216 MB | 99.0 KB |
| c | 3.73% | 7.4 MB（专用） | 216 MB | 54.5 KB |
| rust | 3.71% | 12 MB（总） | 216 MB | 319.5 KB |
| zig | 5.93% | 105 MB（总） | 313 MB | ~1.18 MB |

（工作集两列口径不同：cpp/c 测的是专用工作集，rust/zig 只测了总工作集，
所以 zig 的 105 MB 里含与其他进程共享的页，不能直接和 7.4 MB 比。
私有提交四套同口径，都可比。）

私有提交那 216 MB 是 DXVA 解码器提前预留的帧池，四套都一样；连续采过 5 分钟，
曲线是平的（净变化 −0.08 MB）。

zig 多出来的 88 MB 查到了底：跳过 MF 解码器（`KW_NO_READER=1`）提交就从 301 MB
掉到 28 MB，两块大内存块同时消失。MF 属性、D3D 设备参数、COM 生命周期逐项比过，
和 C 版没有区别，差异在 MF 运行时内部分配 surface 池的行为上，应用层没有安全的改法。
这是对照实现的已知情况，不是 bug，也修不动。

四套对照实现的细节各见目录内 README。

其余目录：

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| [`assets/`](assets/) | 素材目录，**仅放使用者自己的文件，内容不入库** | — |
| [`tools/`](tools/) | 与语言无关的诊断脚本（检查嵌入层级 / 抓窗口层截图 / 恢复桌面 / 校验文档数字） | ✅ 可用 |

---

## 快速开始

要求：Windows 10 1809+ / Windows 11，Visual Studio 2017 及以上（含 Build Tools）带 Windows SDK 10。

```bat
rem 1. 编译（自动用 vswhere 定位 MSVC，任意 VS 版本都可）
cd cpp
build.bat

rem 2. 配置素材：把样例复制成自用配置，第一行改成你的素材路径
copy wallpaper.txt.example wallpaper.txt
notepad wallpaper.txt

rem 3. 安装并启动：复制关闭脚本到桌面、写开机自启快捷方式、启动壁纸
setup.bat
```

也可以完全不改配置文件，用命令行直接指定素材（命令行优先）：

```bat
DynamicWallpaper.exe "D:\videos\my_loop.mp4"
```

> 用命令行启动时，壁纸由命令行决定，之后改 `wallpaper.txt` **不会**生效（命令行优先）。
> 想用热重载，就别带命令行参数启动，让程序读 `wallpaper.txt`。

支持的素材：

| 类型 | 扩展名 | 链路 |
| --- | --- | --- |
| 视频 | `.mp4` `.mov` `.avi` `.wmv` `.mkv` `.webm` `.m4v` | Media Foundation + D3D11 + DXVA 硬解 |
| 动图 / 静态图 | `.gif` 及其他 GDI+ 可解码格式 | GDI+，按帧延时播放 |

缩放方式为 **cover**（铺满屏幕，宽高比不同时裁掉溢出部分）。无声音。只铺主显示器。

### 换壁纸（热重载）

壁纸开着的时候，直接用记事本改 `cpp\wallpaper.txt` 第一行的素材路径并存盘，
**最多 3 秒后自动切换**，不用关闭壁纸、不用重启。

```bat
notepad cpp\wallpaper.txt     ← 改第一行，存盘，等 3 秒
```

- 路径不存在 / 内容不是合法素材 → 保持上一个能放的素材继续播，日志写一行
  `reload-failed`，**不会黑屏**。
- 记事本"先清空再写"的中间态会被容忍，等你写完存盘后自然生效。
- 启动时用了命令行指定素材的话，这条不生效（命令行优先，见上）。

---

## 怎么关

**双击桌面上的「关闭壁纸.bat」**（`setup.bat` 已经帮你放好了），约 1~3 秒后主进程与守护进程一起退出，窗口无任何提示是正常的。

⚠️ **不要用任务管理器强杀，也不要换 `taskkill /f`**：守护进程会在 1 秒内把壁纸重新拉起来，
Windows 重启管理器（`RegisterApplicationRestart`）也可能一并复活它——这就是很多人觉得
「这个壁纸关不掉」的原因。脚本走的是标记文件握手：

```
关闭壁纸.bat  →  写 wallpaper.quit  →  主进程轮询到后正常退出（写 wallpaper.graceful）
                                   →  守护进程看到 wallpaper.graceful 后退出
```

## 怎么彻底卸载

```bat
rem 在 cpp 目录下执行：停止壁纸 + 删除开机自启快捷方式 + 删除桌面的关闭脚本
uninstall.bat
```

然后直接删掉整个项目文件夹即可。程序**不在注册表写任何东西**，不装服务，不留卸载残留。

手动卸载等价于三步：① 双击「关闭壁纸.bat」停掉；② 删掉「启动」文件夹里的 `动态壁纸.lnk`；
③ 删掉桌面上的「关闭壁纸.bat」。剩下整个目录删掉就行。

---

## 关于守护进程与开机自启（请先读这段）

`DynamicWallpaperGuard.exe` 是一个独立进程名的小守护程序，只做一件事：
主进程被**外部强杀**时在 1 秒内把它拉回来。

- 它是**防误杀的，不是防卸载的**：`关闭壁纸.bat` / `uninstall.bat` 走的是优雅退出协议，
  守护进程看到 `wallpaper.graceful` 会立刻自己退出，绝不复活。
- 如果你不想要这个行为，直接不运行 `setup.bat` 的启动步骤即可——
  手动双击 `DynamicWallpaper.exe` 时守护进程仍会起（这是设计），
  但删掉启动快捷方式后它就不会开机自启。
- 本项目的三个「看起来像流氓软件」的机制（守护保活 / 重启管理器 / 开机自启）
  都是为了解决同一个问题：**动态壁纸被误杀后黑屏**。它们全部可以通过上面的方式关掉。

---

## 已知限制

- 只铺**主显示器**，无多屏支持。
- 无托盘图标、无设置界面、无音频、无播放列表。
- 界面与文档目前以中文为主。
- 个别编码的视频系统解不了，会启动失败并把原因写进 `debug.log`。

### 各 Windows 版本的验证状态（请如实看待）

嵌入逻辑针对不同 Windows 版本有三条路径，**实测覆盖度不一样**：

| 路径 | 适用版本 | 验证状态 |
| --- | --- | --- |
| `progman-layered` | Win11 24H2 / 25H2 的 raised desktop | ✅ **已实测**（本机 Win11 build 26300：图标在壁纸之上、无黑屏、DXVA 硬解正常） |
| `workerw-child` | Win10 / pre-24H2 经典 WorkerW 结构 | ⚠️ **未在真机验证**：代码按该结构的社区通行方案实现，但本机无 Win10 机器，运行效果未经实测 |
| `toplevel-fallback` | 上述都失败时的兜底 | ⚠️ **未验证**，且**已知会盖住桌面图标**，仅为「不黑屏」保底 |

程序每次嵌入成功都会把当前走通的策略名写进 exe 同目录的 `wallpaper.embed`；
`python tools\check_embed.py` 的第二行会直接打印它。
**如果你在 Win10 上发现壁纸盖住了图标，先看这个文件**：不是 `progman-layered`
就说明你的桌面结构不在主路径上，落在上面第二、三行的未验证区间。

---

## 素材与版权声明

- **视频 / 动图素材不随本仓库分发**（`.gitignore` 排除了 `assets/` 下的内容）。
  演示素材属于作者私有资产，请自备素材。
- AI 生成素材注意合规：若你把 AI 生成的视频作为壁纸再分发，请遵守
  《人工智能生成合成内容标识办法》，**保留容器内的 `ContentProducer` / TC270/TC260
  数字签名等隐式标识，不要剥离**。
- 本项目只调用 Windows 自带的解码器，不捆绑、不转码任何第三方编解码库。

## 许可证

[MIT](LICENSE)。可自由商用、修改、再分发，保留版权声明即可。
如需 Apache-2.0 等带专利授权条款的许可证，可以自行替换 `LICENSE` 文件。

---

## CI

每次 push 到 `main`、每个 PR 以及推 `v*` tag 都会跑
[.github/workflows/build.yml](.github/workflows/build.yml)：

1. **五套实现并行编译**（`windows-2022` runner）：`cpp\build.bat`、`c\build.bat`、
   `cargo build --release`（rust）、`zig build`（zig，runner 里现下载官方 0.13.0）、
   `asm\build.bat`（ml64 + link，零 CRT）。每套产物各自上传为 artifact 并做
   PE 有效性自检（别人可下载即用，无需自己装工具链）。
2. **校验 README 数字**：跑 `tools\verify_claims.py`，README 里写的行数与
   二进制体积必须与实际一致，否则 CI 变红。
   —— 这条专门防「改了代码忘了更新文档里的数字」。
3. **tag 汇总发布**：推 `v*` tag 时下载全部产物，加语言前缀（防四套同名 exe
   互相覆盖）打包成 zip，创建 GitHub Release。asm 版只有主程序，无守护成对。
4. **零第三方 action**：只用 checkout / upload-artifact / download-artifact / cache，
   工具链靠 runner 预装（MSVC 2022、Rust stable、Python、gh CLI）与各 `build.bat`
   自带的 `vswhere` 定位，不需要额外的 setup action。

> **CI 验证不了什么**：runner 里没有 Explorer 桌面（无 `Progman` / `WorkerW`），
> 所以「桌面嵌入是否真的生效」CI 无法验证。那部分由 `wallpaper.embed` 策略标记
> 与本文「各 Windows 版本的验证状态」一节承担。CI 只保证**能编译 + 数字不漂**。
