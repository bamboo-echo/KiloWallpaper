# tools/

与实现语言无关的 Windows 桌面诊断脚本。它们**只读地**检查窗口层级，不改动系统设置；
只有 `restore_desktop.py` 会在嵌入异常时把桌面图标层恢复成系统默认外观。

| 脚本 | 用途 | 依赖 |
| --- | --- | --- |
| `check_embed.py` | 打印 `Progman` → `SHELLDLL_DefView` → `SysListView32` → 壁纸窗口的完整层级、父子关系、扩展样式与取样像素值。**排查「壁纸没显示 / 图标被盖住」第一个该跑的就是它。** | 无（仅标准库 `ctypes`） |
| `grab_layers.py` | 把桌面各层窗口分别用 `PrintWindow` 截图存到 `shots/`，肉眼确认每层实际渲染了什么。 | Pillow |
| `restore_desktop.py` | 把图标层 `SysListView32` 的 `WS_EX_LAYERED`、`SetWindowTheme`、透明背景等改动恢复成系统默认。**嵌入逻辑出错导致桌面图标不见了时用它救场。** | 无（仅标准库 `ctypes`） |

## 用法

```bat
python tools\check_embed.py
python tools\restore_desktop.py
pip install pillow
python tools\grab_layers.py
```

`grab_layers.py` 依赖 Pillow（`pip install pillow`）——这是三个工具里唯一的外部依赖，
其余两个只用 Python 标准库。

## 原理备注

- 壁纸窗口被 `SetParent` 嵌入 `Progman` 之后**不再是顶层窗口**，`FindWindow` 找不到它，
  所以脚本一律走「先拿 `Progman` / `SHELLDLL_DefView`，再 `EnumChildWindows` / `FindWindowEx` 递归找子窗口」的路径。
- 截图用 `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)`。DirectComposition 合成的内容
  用普通 `PrintWindow(...,0)` 会拿到黑图，必须用 `PW_RENDERFULLCONTENT (2)`。
- 输出目录 `shots/` 已在 `.gitignore` 中排除，不会被提交。
