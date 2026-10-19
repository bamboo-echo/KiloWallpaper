# 参与 KiloWallpaper

这是一个「最小可读的桌面嵌入参考实现」，不是功能最全的壁纸软件。
提交前请读完下面几条，它们都是这个项目实际踩过的坑。

## 构建

| 目录 | 命令 | 备注 |
| --- | --- | --- |
| `cpp/` | `build.bat` | vswhere 定位 MSVC，VS2017+ 即可 |
| `c/` | `build.bat` | 同上，链接 psapi.lib（资源快照日志用） |
| `rust/` | `cargo build --release` | windows crate，只链系统 DLL |
| `zig/` | `zig build` | 需 MSVC/SDK 环境（vcvars64） |

CI（`.github/workflows/build.yml`）会在每次 push/PR 上并行编译五套，
跑 PE 有效性自检，并用 `tools/verify_claims.py` 校验 README 数字。

## 硬性约定

- **零第三方运行时依赖**。四套实现都只链 Windows 系统 DLL。
  引第三方库前先想清楚是否违背项目定位。
- **`.bat` / `.cmd` 必须 GBK（或 UTF-8 with BOM）+ CRLF**。
  git 默认写入的 UTF-8 无 BOM + LF 在中文系统 cmd.exe 下会断行错乱
  （rem 注释被当命令执行）。写完用 `od` 验编码。
- **内存数字必须带口径**：工作集(总) / 工作集(专用 WorkingSetPrivate) /
  提交(PrivateUsage) 三者能差 2~15 倍，混用比过会出错。
- **素材不入库**。`assets/` 在 `.gitignore` 里，只放使用者自己的文件。
- **关闭走握手**：写 `wallpaper.quit`，进程处理后写 `wallpaper.graceful`。
  禁止 `taskkill /f`（守护会在 1 秒内把壁纸拉回来）。
- **改 cpp 的行数/体积要同步 README**：`verify_claims.py` 对行数精确校验、
  对体积有 4096B 容差，不同步 CI 会红。

## 提交信息

中文，一句话说清做了什么 + 为什么。踩到的坑写进 commit message，
别只写「fix bug」。
