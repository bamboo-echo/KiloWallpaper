// state.rs — 跨模块共享的可变状态（对齐 cpp/ 的全局变量）。
//
// 程序是单线程消息循环（D3D 播放器同样在 UI 线程泵帧），不存在跨线程共享；
// 但 Rust 要求 `static` 必须 Sync，而 Cell/RefCell 不是。这里用零成本包装
// + `unsafe impl Sync` 兼顾二者：保留 Cell 的轻量 get/set，同时满足 static 约束。

use std::cell::{Cell, RefCell};

use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::GdiPlus::GpImage;

pub struct SyncCell<T>(pub Cell<T>);
unsafe impl<T> Sync for SyncCell<T> {}
impl<T: Copy> SyncCell<T> {
    pub fn get(&self) -> T {
        self.0.get()
    }
    pub fn set(&self, v: T) {
        self.0.set(v)
    }
}

pub struct SyncRefCell<T>(pub RefCell<T>);
unsafe impl<T> Sync for SyncRefCell<T> {}
impl<T> SyncRefCell<T> {
    pub fn borrow(&self) -> std::cell::Ref<'_, T> {
        self.0.borrow()
    }
    pub fn borrow_mut(&self) -> std::cell::RefMut<'_, T> {
        self.0.borrow_mut()
    }
}

/// 壁纸窗口（被嵌入 Explorer 桌面的那个窗口）。
pub static WALLPAPER_HWND: SyncCell<HWND> = SyncCell(Cell::new(HWND(std::ptr::null_mut())));
/// 消息宿主窗口（承载定时器 / 看门狗，隐藏的 message-only 窗口）。
pub static HOST_HWND: SyncCell<HWND> = SyncCell(Cell::new(HWND(std::ptr::null_mut())));
/// 当前嵌入的父窗口（desktop 模块写入，main 看门狗使用）。
pub static PARENT: SyncCell<HWND> = SyncCell(Cell::new(HWND(std::ptr::null_mut())));
/// 窗口客户区宽 / 高（像素）。
pub static WIN_W: SyncCell<i32> = SyncCell(Cell::new(0));
pub static WIN_H: SyncCell<i32> = SyncCell(Cell::new(0));
/// true=视频（D3D 播放器），false=GIF/静态图（GDI+）。
pub static IS_VIDEO: SyncCell<bool> = SyncCell(Cell::new(false));
/// RegisterWindowMessageW("TaskbarCreated") 的结果（探测桌面刷新）。
pub static TASKBAR_CREATED: SyncCell<u32> = SyncCell(Cell::new(0));

// ---------- media / render 共享状态 ----------
pub static IMG: SyncCell<*mut GpImage> = SyncCell(Cell::new(std::ptr::null_mut()));
pub static FRAME_COUNT: SyncCell<u32> = SyncCell(Cell::new(0));
pub static CUR_FRAME: SyncCell<u32> = SyncCell(Cell::new(0));
pub static DELAYS: SyncRefCell<Vec<u32>> = SyncRefCell(RefCell::new(Vec::new()));
pub static LAST_HR: SyncCell<i32> = SyncCell(Cell::new(0));
