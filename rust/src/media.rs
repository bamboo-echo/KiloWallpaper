// media.rs — GIF / 静态图解码（GDI+ 平面 API），对齐 cpp/media.cpp
//
// windows crate 的 GdiPlus 模块直接映射 gdiplus.dll 的导出函数（Status / InterpolationMode
// 都是 newtype，比较时需 Status(0)）。帧维度函数真实名带 Image 前缀。

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;

use windows::core::{GUID, PCWSTR};
use windows::Win32::Graphics::GdiPlus::*;

use crate::state::{CUR_FRAME, DELAYS, FRAME_COUNT, IMG, LAST_HR};

const PROPERTY_TAG_FRAME_DELAY: u32 = 0x5100;
pub const FRAME_DIMENSION_TIME: GUID = GUID::from_u128(0x6aedbd6d_3fb5_418a_83a6_7f45229dc872);

pub fn is_video_file(path: &str) -> bool {
    let lower = path.to_lowercase();
    [".mp4", ".mov", ".avi", ".wmv", ".mkv", ".webm", ".m4v"]
        .iter()
        .any(|e| lower.ends_with(e))
}

pub fn load_gif(path: &str) -> bool {
    unsafe {
        let old = IMG.get();
        if !old.is_null() {
            let _ = GdipDisposeImage(old);
            IMG.set(std::ptr::null_mut());
        }

        let wide: Vec<u16> = OsStr::new(path)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut img: *mut GpImage = std::ptr::null_mut();
        if GdipLoadImageFromFile(PCWSTR(wide.as_ptr()), &mut img) != Status(0) || img.is_null() {
            LAST_HR.set(0x80004005u32 as i32);
            return false;
        }
        IMG.set(img);

        let mut dim_count: u32 = 0;
        if GdipImageGetFrameDimensionsCount(img, &mut dim_count) != Status(0) || dim_count == 0 {
            return false;
        }
        let mut dims = vec![GUID::default(); dim_count as usize];
        if GdipImageGetFrameDimensionsList(img, dims.as_mut_ptr(), dim_count) != Status(0) {
            return false;
        }
        let dim = dims[0];

        let mut fc: u32 = 0;
        if GdipImageGetFrameCount(img, &dim, &mut fc) != Status(0) || fc == 0 {
            return false;
        }
        FRAME_COUNT.set(fc);

        let mut delays = vec![100u32; fc as usize];
        let mut size: u32 = 0;
        if GdipGetPropertyItemSize(img, PROPERTY_TAG_FRAME_DELAY, &mut size) == Status(0) && size > 0 {
            let mut buf = vec![0u8; size as usize];
            let p = buf.as_mut_ptr() as *mut PropertyItem;
            if GdipGetPropertyItem(img, PROPERTY_TAG_FRAME_DELAY, size, p) == Status(0) {
                let pi = &*p;
                let n = (pi.length / 4) as usize;
                let vals = std::slice::from_raw_parts(pi.value as *const i32, n);
                for (i, v) in vals.iter().enumerate().take(fc as usize) {
                    let ms = (*v as u32).saturating_mul(10);
                    delays[i] = ms.max(10);
                }
            }
        }
        if fc > 1 && delays[fc as usize - 1] < 10 {
            delays[fc as usize - 1] = delays[fc as usize - 2];
        }
        *DELAYS.borrow_mut() = delays;
        CUR_FRAME.set(0);
        LAST_HR.set(0);
        true
    }
}
