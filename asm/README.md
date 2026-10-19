# KiloWallpaper — ASM 参考实现（MASM x64）

纯 MASM x64 汇编，**零 CRT**（不链 msvcrt / ucrt），只用 Windows 系统 DLL。
单文件 `main.asm`（2178 行）实现**静态图片壁纸**：桌面嵌入、图标层双向 z 序锚定、
配置热重载、退出握手、周期资源快照日志。静态图渲染 CPU 精确为 0。

> 定位：五套实现里最特殊的一件——证明「桌面嵌入」这件事可以压到多小。
> MF / D3D 播放链在汇编里没有意义，因此范围只保留静态图（GDI+ 解码）。
> ml64 不支持 `invoke`，全部调用手写 x64 调用约定（全局参数槽 + 手写栈布局）。

---

## 文件清单

| 文件 | 职责 |
| --- | --- |
| `main.asm` | 全部功能：入口、窗口与消息循环、看门狗、GDI+ 解码与 cover 绘制、桌面嵌入、热重载、退出握手、资源快照 |
| `build.bat` | 编译（ml64 + link，零 CRT，vswhere 定位 MSVC） |
| `关闭壁纸.bat` | 优雅关闭（写 `wallpaper.quit` 握手） |
| `wallpaper.txt.example` | 素材路径配置模板 |

## 编译与运行

```bat
build.bat                      rem vswhere 定位 MSVC + vcvarsall x64，产物 DynamicWallpaper.exe
DynamicWallpaper.exe           rem 直接双击运行；也可命令行指定素材（命令行优先）
```

配置：把 `wallpaper.txt.example` 复制为 `wallpaper.txt`（与 exe 同目录），
第一行写成素材路径（相对路径按 exe 所在目录解析）。改第一行存盘约 3 秒内
热切换，不必重启；新素材打不开会自动保持上一个能放的素材。

**关闭**：双击 `关闭壁纸.bat`（写 `wallpaper.quit` → 主进程消费后正常退出）。
asm 版**没有守护进程**，不会被杀软互保，但请同样走握手而不要 `taskkill /f`——
与其余四套保持一致的习惯。嵌入成功的策略名也会写进 exe 同目录的
`wallpaper.embed`，在仓库根目录跑 `python tools\check_embed.py` 可自查。

## 与 cpp 版的差异

- 无 MF / D3D / DirectComposition：只支持静态图片（GDI+ 可解码格式），
  不做视频播放与 GIF 动画。
- 无守护进程：不提供 `DynamicWallpaperGuard.exe`，也没有开机自启脚本。
- 嵌入层级、`0x052C` 唤醒、DPI 感知（建窗前 `PER_MONITOR_AWARE_V2`）、
  双向 z 序锚定、配置热重载、退出握手、`[res]` 资源快照与 cpp 版同一套逻辑。

## 已知限制

- **静态图在 Win11 24H2+ 的 raised desktop 上不显示画面**（2026-10-18 实测，
  与 c 版 GDI+ 路径同症状：对照实验截图字节级相同，只有图标和系统默认壁纸；
  DComp 视频路径有 GPU 负载证明正常合成）。怀疑该桌面结构只合成 DX/DComp
  内容、不合成 GDI+ 绘制内容。嵌入 / z 序 / 退出链路本身验证正常。
- 只铺主显示器；无托盘、无设置界面。

## 验证状态

本机（Win11 build 26300）实测：桌面嵌入、配置热重载、资源快照日志、退出握手
均正常；上述 raised desktop 静态图不渲染为已知限制，详见根 README。
