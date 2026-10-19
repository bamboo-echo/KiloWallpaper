# KiloWallpaper — C++ 参考实现

Win32 原生 API 手写，**零第三方依赖**（只用 Windows SDK 与系统 DLL），
8 个文件 **1926 行**，编译出两个二进制共 **99.0 KB**。

> 这份实现的目的不是「功能最多」，而是「**最短的可读路径**跑通动态壁纸的全部难点」：
> DXVA 硬解、DirectComposition 零拷贝呈现、Explorer 桌面嵌入、图标层 z 序锚定、双进程守护。

---

## 文件清单

| 文件 | 行数 | 职责 |
| --- | ---: | --- |
| `main.cpp` | 592 | 入口、窗口与消息循环、看门狗、渲染调度、配置解析与**热重载**、单实例互斥 |
| `d3dplayer.cpp` | 607 | 视频链路：Media Foundation `SourceReader` + DXVA 硬解 + D3D11 VideoProcessor + DirectComposition 呈现 + 无缝循环 |
| `desktop.cpp` | 371 | 桌面嵌入：Progman/WorkerW 结构探测、双向 z 序锚定、图标层打穿与恢复、多级兜底、嵌入策略标记 |
| `guard.cpp` | 140 | 独立进程名守护程序（保活 + 优雅退出响应） |
| `media.cpp` | 57 | GIF / 静态图解码（GDI+），帧延时表 |
| `render.cpp` | 63 | GIF 帧绘制与双缓冲后备缓冲管理 |
| `wallpaper.h` | 73 | 跨模块共享声明 |
| `d3dplayer.h` | 23 | 视频播放器对外接口 |
| **合计** | **1926** | |

辅助脚本：`build.bat`（编译）、`setup.bat`（安装并启动）、`uninstall.bat`（卸载）、
`关闭壁纸.bat`（优雅关闭）。

---

## 编译与运行

```bat
build.bat          rem 自动用 vswhere 定位 MSVC，任意 VS 2017+ 版本均可
setup.bat          rem 编译(如缺失) + 优雅停旧实例 + 桌面关闭脚本 + 开机自启 + 启动
uninstall.bat      rem 优雅停止 + 移除开机自启与桌面脚本
```

`build.bat` 单独编译一个文件时也可以直接调 `cl`，源文件之间没有生成依赖。
编译选项固定为 `/O2 /EHsc /MD /DUNICODE /D_UNICODE`，链接 `user32 gdi32 gdiplus mfplat
mfreadwrite mfuuid d3d11 dxgi shlwapi ole32 comctl32 uxtheme`。

关闭请用 `关闭壁纸.bat` / `uninstall.bat`，**不要 `taskkill /f`**：守护进程会在 1 秒内把它拉回来。

---

## 工作原理

### 1. 桌面嵌入（`desktop.cpp`）

Windows 11 24H2+/25H2 的桌面是「raised desktop」结构：

```
Progman  (WS_EX_NOREDIRECTIONBITMAP)
  ├─ SHELLDLL_DefView   (WS_EX_LAYERED)  ← 图标层，标准外观，绝不修改
  │    └─ SysListView32
  └─ WorkerW            (全屏)            ← 系统壁纸绘制层，z 在 DefView 之下
```

主路径是**挂到 `Progman` 下 + 双向 z 锚定**：

1. 壁纸窗口 `SetParent` 到 `Progman`，并加 `WS_EX_LAYERED`（`bAlpha=0xFF`）——
   这是把 D3D11 内容呈现在跨进程子窗口上的前提；改用 WorkerW 子树在 24H2+ 上不合成第三方子窗口（GDI/D3D 都不显示）。
2. 把壁纸窗口插到 `SHELLDLL_DefView`（图标层）**之后** → 图标永远在壁纸之上，桌面右键、图标选中、文字阴影全是系统原状。
3. 把系统 `WorkerW`（壁纸层）压到壁纸窗口**之后** → 否则会被黑的系统壁纸层盖住，壁纸「消失」。**缺这一步是实测复现过的坑。**

另外两处必须做的事：

- **嵌入前发 `0x052C` 给 Progman**，强制进入 raised 状态。开机或 explorer 重启后桌面可能退化回未 raised 状态（Progman 下只有 DefView、没有 WorkerW），此时系统壁纸由 DWM 直绘在最底层，会把我们的窗口盖住。看门狗每 3 秒校准一次 z 序，发现 WorkerW 消失时会重发 `0x052C` 自愈（5 秒限频）。
- **DPI 感知必须在建窗前设为 `PER_MONITOR_AWARE_V2`**。进程若不是 Per-Monitor V2，跨 DPI 上下文 `SetParent` 进 Explorer 后 DWM 会拒绝合成窗口内容 → **纯黑**（已实测复现，见 `main.cpp` 的 `SetProcessDpiAwarenessContext` 调用）。

多级兜底（按顺序尝试，任一成功即止）。**注意三者实测覆盖度不同**：

| 顺序 | 策略名 | 方案 | 验证状态 |
| --- | --- | --- | --- |
| 1 | `progman-layered` | Progman 子窗口 + 双向 z 锚定 | ✅ 已实测（Win11 24H2+/25H2 主路径） |
| 2 | `workerw-child` | 图标层 WorkerW 之后的空 WorkerW 子窗口 | ⚠️ 未在真机验证（pre-24H2 / Win10 经典结构，按社区方案实现） |
| 3 | `toplevel-fallback` | 顶层窗口压到底 | ⚠️ 未验证，且**已知会盖住图标**，仅保底不黑屏 |

当前生效的策略名写在 exe 同目录的 `wallpaper.embed` 里，
`tools/check_embed.py` 第二行会打印它——排查跨版本问题时先看这个。

### 2. 关于图标层：本实现**零修改**

系统图标列表（`SysListView32` / `SHELLDLL_DefView`）**本来就不绘制自己的背景**
——否则系统壁纸永远看不见。实测它的 `LVM_GETBKCOLOR` 就是 `CLR_NONE`。
所以壁纸能显示，靠的是 z 序（壁纸窗口排在图标层之后、系统壁纸层之前，见上），
**不需要也不应该去改图标层的任何属性**。

> 历史版本曾尝试"打穿"图标层：先是品红色键 + 鼠标穿透转发，后是只把背景色设成
> `CLR_NONE`。两者都已删除——品红色键实测产生**黑色图标残缺 + 右键弹出图标菜单**；
> 而 `CLR_NONE` 本来就是系统默认，那段代码没有任何调用点，是死代码。
> 现在的代码对图标层**零写入**：图标、文字、右键菜单、扩展样式全为系统原状。
> （`tools/restore_desktop.py` 是另一个话题，见 tools/README.md——它用于图标层
> 被**其它程序**改坏时手动复位，本程序运行期间不会动它。）

### 3. 视频链路：DXVA 硬解 + 零拷贝呈现（`d3dplayer.cpp`）

```
MP4 ──MF SourceReader（MF_READWRITE_D3D_MANAGER + IMFDXGIDeviceManager → DXVA）──▶ NV12 纹理
                                                                                    │ UpdateSubresource
                                                                                    ▼
                       D3D11 VideoProcessor：NV12→RGB 色彩转换 + 缩放到屏幕分辨率
                                                                                    │
                                                       Composition 交换链（FLIP 模型）Present（垂直同步）
                                                                                    │
                                                                        DirectComposition Visual → 子窗口
```

- **DXVA 硬解**走 `MF_SOURCE_READER_D3D_MANAGER` 把解码器绑到我们的 D3D11 device 上，
  解码与呈现共用同一个 device。代价是必须给 device 开多线程保护（`ID3D10Multithread`），
  因为 Media Foundation 的解码工作线程会并发访问它。
- **色彩转换与缩放交给 GPU**（`ID3D11VideoProcessor`），CPU 每帧只做一次
  `UpdateSubresource` 上传，不读回、不转码。
- **呈现用 DirectComposition**：`IDCompositionDevice` 把交换链挂到窗口句柄上。
  把 D3D 内容放进一个**跨进程的子窗口**，这是实测唯一可靠的路径。

**无缝循环（这是整份实现最核心的一个设计）**：

老的 EVR 方案循环必须「会话结束 → 重建渲染器」，重建瞬间渲染器清屏 → 透出系统壁纸 → **闪一下**。
这里改成：读到 EOS 后直接 `SetCurrentPosition(0)` 回到开头继续解码，**交换链全程保留上一帧直到新帧 `Present`**，
渲染管线从不中断 → 物理上不可能闪屏。回退是分级进行的（更稳但更重）：

```
SetCurrentPosition(0) 失败 → seek(1) 强制真 seek → 仍然 EOS 才重建整个 SourceReader
```

（简化示意：实际每个 EOS 事件只尝试一次 seek，`pos = (g_loopRetry==0)?0:1`；seek 失败
或 `g_loopRetry>=2` 时直接重建 reader，见 `d3dplayer.cpp` 的 EOS 分支。）

失败信息按 `loopProbs` 标志限频写日志；循环日志只在「异常 / 首轮 / 每 500 轮」打一次，
否则 10 秒一轮的素材一天约 8640 行（≈550 KB/天），长期累积能把 debug.log 撑到数 MB
（曾实测占全部内容的 99.5%，这是踩过的坑）。

### 4. GIF / 静态图链路（`media.cpp` + `render.cpp`）

GDI+ 解码 + 读取每帧延时属性，`render.cpp` 用内存 DC 双缓冲按 **cover** 缩放绘制。
GIF 与视频的调度共用 `main.cpp` 里的 `SetTimer` 帧定时器。

### 5. 配置热重载（`main.cpp`）

看门狗每 3 秒调一次 `CheckMediaReload()`：重新解析 `wallpaper.txt`，
**比较解析后的完整路径**（而不是文件时间戳——时间戳会被复制文件、同秒多次写、
编辑器保存方式搅乱，产生大量假变更）。路径变了才重载。

三个边界处理，都是实测踩出来的：

- **编辑中间态**：记事本「先清空再写」时 `ResolveMediaPath` 读到空串或坏路径，
  一律返回空 → 本拍跳过，等下一拍。不会把壁纸搞没。
- **加载失败回滚**：新素材打不开 → 日志写一行 `reload-failed`，
  立刻把旧素材重新装回去。**绝不停在黑屏上**。
- **失败退避**：同一个坏路径失败后记进 `g_failedMedia`，配置内容不变就不再重试。
  否则看门狗每 3 秒重试一次，日志被刷满、CPU 空转（实测修复前 16 秒内重复失败 3 次以上）。

视频 ↔ GIF 切换时先 `D3DShutdown()` 拆掉另一条链路再装新的，
避免两条链路同时持有同一个窗口 / D3D 设备。
`D3DInit` 内部先调 `D3DShutdown()`，所以重载视频本质就是「重新 init 一次」。

### 6. 双进程守护（`guard.cpp`）

守护进程**故意用另一个进程名** `DynamicWallpaperGuard.exe`：优化软件按进程名批量清理时只会命中
`DynamicWallpaper.exe`，守护存活即可在 1 秒内拉起主进程。

主进程与守护都用 `RegisterApplicationRestart` 注册了 Windows 重启管理器，
所以外部 `TerminateProcess` 强杀也拦不住它——**这是「壁纸关不掉」传闻的来源**。

要让守护**不复活**，就必须走优雅退出握手（下表）。

### 7. 进程间协议：全在一个目录里的标记文件

所有标记文件都用 `GetModuleFileNameW` → 取 exe 所在目录定位，**因此整个目录随便搬到哪都不会失联**。

| 文件 | 写入者 | 语义 |
| --- | --- | --- |
| `wallpaper.txt` | 用户 | 素材路径（**只读第一行**，UTF-8，容忍 BOM，相对路径按 exe 目录解析） |
| `wallpaper.main.pid` | 主进程 | 记录主进程 pid，供守护探测存活 |
| `wallpaper.guard.pid` | 守护 | 记录守护 pid |
| `wallpaper.ok` | 主进程 | 初始化成功标记；守护**只有看到它才保活** |
| `wallpaper.quit` | `关闭壁纸.bat` | 关闭请求，由主进程消费后删除 |
| `wallpaper.graceful` | 主进程 | 优雅退出标记；守护见之即退，**不再复活** |
| `wallpaper.embed` | 主进程（desktop.cpp） | 当前生效的嵌入策略名（见上表），供诊断工具与用户自查 |
| `debug.log` | 各模块 | 追加式日志，同一目录 |

优雅关闭的完整链路：

```
关闭壁纸.bat  写 wallpaper.quit
      → 主进程看门狗 ConsumeQuitSignal() 消费它 → 写 wallpaper.graceful → 退出（退出码 0，不触发重启管理器）
      → 守护进程下一拍（1 秒）看到 wallpaper.graceful → 清掉 ok/graceful → 自己退出
```

两种「停止保活」的保险：主进程**从未成功初始化**过（没有 `wallpaper.ok`）时不保活；
**刚拉起过一次又立刻消失**时守护直接退出——防重启风暴。

---

## 排障

| 现象 | 先看什么 |
| --- | --- |
| 壁纸不显示 / 图标被盖 | **在仓库根目录**运行 `python tools\check_embed.py`（打印完整窗口层级、父子关系、扩展样式、当前嵌入策略、取样像素） |
| 改了 `wallpaper.txt` 没反应 | ① 是不是用**命令行**启动的（命令行优先，热重载不生效）；② 等够 3 秒；③ 看 `debug.log` 有没有 `reload-failed` |
| 换素材后黑屏 | 不该发生——失败会自动回滚。若真黑了，看 `debug.log` 的 `reload-failed` 行确认原因 |
| 桌面图标不见了 | **在仓库根目录**运行 `python tools\restore_desktop.py`（注意：它主动改写图标层，非回滚，见 tools/README.md） |
| 壁纸消失、只剩系统默认壁纸 | 大概率是桌面退化回未 raised 状态，看 `debug.log` 里的 `[embed] zorder: anchor FAILED` |
| 启动即退出 | `debug.log` 里的 `path=` / `hr=` 行；多半是 `wallpaper.txt` 第一行的路径不存在或不是合法素材 |
| 关不掉 | 你用的是 `taskkill`。用 `关闭壁纸.bat` |
| 想确认真的在硬解 | 任务管理器 → 性能 → GPU，看 `Video Decode` 引擎是否有占用（软解不会占它） |

> `tools/check_embed.py` 对 **GDI 路径（GIF/图片）** 的 `PrintWindow` 抓屏会显示全黑：
> 跨进程子窗口的 GDI 内容不会被 `PrintWindow` 捕获（`WndProc` 没有处理 `WM_PRINTCLIENT`），
> 而 D3D/DirectComposition 内容靠 `PW_RENDERFULLCONTENT` 可以正常抓到。
> **这是探针的限制，不是壁纸没画出来**——用 GIF 时请以肉眼或整屏截图为准。

> `tools/` 下的脚本一律在**仓库根目录**执行（它们是全语言共用的诊断工具，
> 不在 `cpp/` 里）；`tools/README.md` 有完整说明。

`debug.log` 的位置跟随 exe 所在目录（即本文件夹）。

## 已知限制与未做的事

- 只铺主显示器；多显示器需要把 `GetPrimaryMonitorRect()` 换成按 `MonitorEnumProc` 遍历。
- 无托盘、无设置界面、无音频、无播放列表。
- **嵌入路径 2 / 3（`workerw-child` / `toplevel-fallback`）没有在真机上验证过**：
  本机只有 Win11 build 26300，走的是路径 1。Win10 用户第一次跑请先看
  `wallpaper.embed` 里的策略名；如果是路径 3（顶层兜底）说明**桌面图标会被盖住**，
  属于已知缺陷，不是你的系统问题。
- `tools/check_embed.py` 抓不到 GDI（GIF/图片）内容的像素，见上面排障表末尾的说明。
- `guard.cpp` 的 `IsOurProcess()` 在 `QueryFullProcessImageName` 失败时按「存活」处理（保守策略，
  避免误判把还在跑的主进程再拉起一次）。
- 守护进程在「主进程不在且 `wallpaper.ok` 存在时」只补拉一次：若拉起后下一拍（1 秒）
  主进程仍不在，守护直接退出（防重启风暴），不无限重试。
