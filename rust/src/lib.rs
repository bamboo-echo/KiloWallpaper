// lib.rs — KiloWallpaper (Rust) 公共库
//
// 两个 bin（main / guard）共用这里的模块。unsafe 的 Win32/COM 调用尽量收敛在
// 各模块内部，业务逻辑保持安全代码为主。

pub mod common;
pub mod d3dplayer;
pub mod desktop;
pub mod media;
pub mod render;
pub mod state;
