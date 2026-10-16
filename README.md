# KiloWallpaper

用 Win32 原生 API 手写的极简动态壁纸。**零第三方依赖，两个二进制合计 92.5 KB，
播放 2K 视频时只占一个逻辑核的约 2~4%。**

> 名字来自它的体积：主程序正好 **64 KB**，两个二进制加起来 **92.5 KB** —— kilobyte 级，
> 这是「极小占用」最直接的说法。
> 本项目不是「又一个动态壁纸软件」，而是一份**最小可读的 Windows 桌面嵌入参考实现**：
> 1766 行 C++ 串起 DXVA 硬解 → DirectComposition 零拷贝呈现 → Progman/WorkerW 嵌入 →
> 图标层双向 z 序锚定 → 双进程守护。功能刻意做得少，代码刻意写得短。
> 可执行文件名仍为 `DynamicWallpaper.exe` / `DynamicWallpaperGuard.exe`。

---

## 特点：极小占用（实测）

测试条件：Windows 11 (build 26300)，32 逻辑核，2560×1600 屏（150% 缩放），播放 2560×1440
10 秒循环 H.264 视频，20 秒采样窗口，取稳定运行阶段数值。**均为本机实测，非普适性能保证。**

| 指标 | 实测 | 备注 |
| --- | --- | --- |
| 主程序二进制 | **64.0 KB**（65,536 B） | MSVC `/O2`，只链接 Windows 系统 DLL |
| 守护进程二进制 | **28.5 KB**（29,184 B） | |
| CPU（主进程） | **2.3 ~ 4.1 % 单核 / 0.07 ~ 0.13 % 整机** | 20 s 内累计 453~828 ms（随画面内容波动） |
| CPU（守护进程） | **0.00 %** | 1 秒拍空闲轮询 |
| GPU `video` 引擎 | **13.9 %**（`3d` 15.2 %） | 出现 `video` 引擎即证明走 **DXVA 硬解** |
| 内存 · 任务管理器「内存」列 | **~6.5 MB** | 即专用工作集 `WorkingSetPrivate`（5.5~11.3 波动） |
| 内存 · 工作集 | 12 ~ 20 MB | |
| 内存 · 提交 | 213 ~ 219 MB | D3D11/DXVA 解码器预留面池；5 分钟 30 点采样净 −0.08 MB，不是泄漏 |
| 句柄 / 线程 | 1073 / 42 | |

> 内存那一行有一个实现细节要说明：程序在播放稳定 **15 秒后主动调用
> `SetProcessWorkingSetSize(-1,-1)` 归还备用页**（`d3dplayer.cpp` 的延迟 trim）。
> 所以任务管理器里的 ~6.5 MB 是 trim 之后的读数；提交内存 213~219 MB 才是
> DXVA 解码器面池的真实预留量，两者并不矛盾。

作为对比：Electron / WebView2 类方案光运行时就要 100 MB 以上的常驻内存，
而这里连可执行文件本身都不到 100 KB。

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
- **无广告、无 UAC、无网络、无遥测**：程序不发起任何网络请求。

---

## 目录结构（为多语言实现预留）

`cpp/` 是当前的参考实现。其他语言版本按同样的约定各自建目录，共用根目录文档、`assets/` 与 `tools/`。

| 目录 | 内容 | 状态 |
| --- | --- | --- |
| [`cpp/`](cpp/) | C++ 参考实现（Win32 + D3D11 + Media Foundation） | ✅ 可用，1766 行 |
| `go/`（预留） | Go 实现（计划用 `syscall` + `golang.org/x/sys/windows`，不引入 cgo） | 计划中 |
| `asm/`（预留） | x64 汇编实现（只做最小呈现路径） | 计划中 |
| [`assets/`](assets/) | 素材目录，**仅放使用者自己的文件，内容不入库** | — |
| [`tools/`](tools/) | 与语言无关的诊断脚本（检查嵌入层级 / 抓窗口层截图 / 恢复桌面） | ✅ 可用 |

各语言实现共享的约定：素材路径配置文件叫 `wallpaper.txt`（放在可执行文件旁边，不入库），
窗口类名统一叫 `DynamicWallpaper`，退出握手统一用 `wallpaper.quit` → `wallpaper.graceful`。

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

支持的素材：

| 类型 | 扩展名 | 链路 |
| --- | --- | --- |
| 视频 | `.mp4` `.mov` `.avi` `.wmv` `.mkv` `.webm` `.m4v` | Media Foundation + D3D11 + DXVA 硬解 |
| 动图 / 静态图 | `.gif` 及其他 GDI+ 可解码格式 | GDI+，按帧延时播放 |

缩放方式为 **cover**（铺满屏幕，宽高比不同时裁掉溢出部分）。无声音。只铺主显示器。

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
