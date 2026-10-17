// d3dplayer.h - D3D11 视频壁纸播放器（无缝循环版，替代 EVR 方案）
// 原理：SourceReader(DXVA 硬解) 逐帧读 + D3D11 VideoProcessor GPU 转换呈现。
// 循环 = 读完 seek 回 0 继续读，交换链全程保留上一帧 → 渲染管线永不中断，
// 循环点零闪屏（与 mpv/Wallpaper Engine 同一原理，零第三方依赖）。
#ifndef D3DPLAYER_H
#define D3DPLAYER_H

#include <windows.h>

// 初始化 D3D 设备/交换链/解码器并绑定壁纸窗口。成功返回 1。
int  D3DInit(HWND hwnd, const wchar_t* videoPath);

// 泵一帧：解码→GPU 转换→呈现；到末尾自动 seek 回 0 继续（无缝循环）。
// 返回下一帧间隔 ms（按视频帧率）。
UINT D3DPumpFrame(void);

// 壁纸窗口重建/重新嵌入后重绑（交换链自适应新窗口尺寸）。
void D3DSetWindow(HWND hwnd);

// 关闭并释放全部资源。
void D3DShutdown(void);

#endif // D3DPLAYER_H
