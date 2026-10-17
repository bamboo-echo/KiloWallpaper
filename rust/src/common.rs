// common.rs — KiloWallpaper (Rust) 跨模块共享工具
//
// 对应 cpp/ 中散落在 main.cpp / guard.cpp 的共用逻辑：日志、exe 目录、
// 标记文件（原子替换）、配置解析（wallpaper.txt 首行，UTF-8+BOM）、
// 单实例互斥、进程互认、进程拉起、重启管理器注册。
//
// 这里刻意把 unsafe 的 Win32 / COM 调用收敛在一处（薄封装），业务代码尽量安全。

use std::io::Write as _;
use std::path::Path;

use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::Security::*;
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::System::LibraryLoader::*;
use windows::Win32::System::Threading::*;
use windows::Win32::System::SystemInformation::GetLocalTime;

pub const MAX_PATH_LEN: usize = 260;

// ---------- 字符串工具 ----------

/// 把 Rust 字符串转成以 0 结尾的 UTF-16 向量（供 PCWSTR/PWSTR 使用）。
pub fn wide(s: &str) -> Vec<u16> {
    let mut v: Vec<u16> = s.encode_utf16().collect();
    v.push(0);
    v
}

/// 从 UTF-16（可能含中间 0）读出到首个 0 为止的字符串。
pub fn from_wide(p: &[u16]) -> String {
    let end = p.iter().position(|&c| c == 0).unwrap_or(p.len());
    String::from_utf16_lossy(&p[..end])
}

// ---------- exe 目录 / 路径 ----------

/// 当前进程 exe 所在目录（含结尾反斜杠）；整个目录可任意移动而不失联。
pub fn exe_dir() -> String {
    let mut buf = [0u16; MAX_PATH_LEN];
    unsafe {
        GetModuleFileNameW(None, &mut buf);
    }
    let full = from_wide(&buf);
    match full.rfind('\\') {
        Some(i) => full[..i + 1].to_string(),
        None => String::new(),
    }
}

/// 当前进程 exe 的完整路径。
pub fn exe_full_path() -> String {
    let mut buf = [0u16; MAX_PATH_LEN];
    unsafe {
        GetModuleFileNameW(None, &mut buf);
    }
    from_wide(&buf)
}

// ---------- 日志（对齐 cpp 的结构化前缀 [embed]/[d3d]/...） ----------

fn now_string() -> String {
    unsafe {
        let st = GetLocalTime();
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond
        )
    }
}

/// 追加式日志，写入 exe 目录 debug.log。tag 形如 "embed"/"d3d"/"main"。
pub fn log(tag: &str, msg: &str) {
    let path = format!("{}debug.log", exe_dir());
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = writeln!(f, "{} [{}] {}", now_string(), tag, msg);
    }
}

// ---------- 标记文件（exe 目录，原子替换防并发空读） ----------

/// 写 pid 标记：先写临时文件再原子替换，避免读侧读到空文件误判对方退出。
pub fn write_pid_file(name: &str) {
    let dir = exe_dir();
    let tmp = format!("{}{}.tmp", dir, name);
    let final_p = format!("{}{}", dir, name);
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&tmp)
    {
        let _ = writeln!(f, "{}", std::process::id());
    }
    unsafe {
        let _ = MoveFileExW(
            PCWSTR::from_raw(wide(&tmp).as_ptr()),
            PCWSTR::from_raw(wide(&final_p).as_ptr()),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        );
    }
}

/// 读 pid 标记（解析失败返回 0）。
pub fn read_pid_file(name: &str) -> u32 {
    let p = format!("{}{}", exe_dir(), name);
    if let Ok(c) = std::fs::read_to_string(&p) {
        c.trim().parse::<u32>().unwrap_or(0)
    } else {
        0
    }
}

/// 写一个空标记文件（如 wallpaper.ok / wallpaper.graceful / wallpaper.quit 的占位）。
pub fn write_marker(name: &str) {
    let p = format!("{}{}", exe_dir(), name);
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&p);
}

/// 删除一个标记文件（忽略失败）。
pub fn delete_file(name: &str) {
    let p = format!("{}{}", exe_dir(), name);
    unsafe {
        let _ = DeleteFileW(PCWSTR::from_raw(wide(&p).as_ptr()));
    }
}

/// 标记文件是否存在（不区分类型）。
pub fn file_exists(name: &str) -> bool {
    let p = format!("{}{}", exe_dir(), name);
    unsafe { GetFileAttributesW(PCWSTR::from_raw(wide(&p).as_ptr())) != INVALID_FILE_ATTRIBUTES }
}

// ---------- 配置解析（wallpaper.txt 首行） ----------

fn strip_bom(bytes: &[u8]) -> &[u8] {
    if bytes.len() >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
        &bytes[3..]
    } else {
        bytes
    }
}

/// 去掉首尾空格/引号/制表符，截断到首个换行，再去掉尾部空白（对齐 cpp TrimPath）。
pub fn trim_path(s: &str) -> String {
    let mut s = s.to_string();
    while let Some(c) = s.chars().next() {
        if " \t\"".contains(c) {
            s.remove(0);
        } else {
            break;
        }
    }
    while let Some(c) = s.chars().last() {
        if " \t\"\r\n".contains(c) {
            s.pop();
        } else {
            break;
        }
    }
    if let Some(nl) = s.find(['\r', '\n']) {
        s.truncate(nl);
    }
    while let Some(c) = s.chars().last() {
        if " \t\"".contains(c) {
            s.pop();
        } else {
            break;
        }
    }
    s
}

/// 解析素材路径：命令行优先，否则读 wallpaper.txt 首行（严格 UTF-8，容忍 BOM，
/// 相对路径按 exe 目录解析）。返回规范化后的完整路径；解析失败/文件不存在返回空串。
pub fn resolve_media_path(cmd_line: Option<&str>) -> String {
    let mut s = String::new();
    if let Some(c) = cmd_line {
        if !c.is_empty() {
            s = trim_path(c);
        }
    }

    if s.is_empty() {
        let cfg = format!("{}wallpaper.txt", exe_dir());
        if let Ok(bytes) = std::fs::read(&cfg) {
            let bytes = strip_bom(&bytes);
            // 严格 UTF-8：配置文件应存为 UTF-8。非法字节直接判为“配置无效”，
            // 不要静默猜编码（否则得到一条打不开的路径）。
            match std::str::from_utf8(bytes) {
                Ok(text) => {
                    let first = text.lines().next().unwrap_or("").to_string();
                    s = trim_path(&first);
                }
                Err(_) => return String::new(),
            }
        }
    }

    if s.is_empty() {
        return String::new();
    }

    // 相对路径按 exe 目录解析。
    if Path::new(&s).is_relative() {
        s = format!("{}{}", exe_dir(), s);
    }

    // GetFullPathNameW：缓冲区不足时返回所需长度（>0 非 0），此时不能当成功用。
    let w = wide(&s);
    let mut full = [0u16; MAX_PATH_LEN];
    let n = unsafe { GetFullPathNameW(PCWSTR::from_raw(w.as_ptr()), Some(&mut full), None) };
    if n > 0 && n < MAX_PATH_LEN as u32 {
        s = from_wide(&full[..n as usize]);
    } else if n == 0 {
        return String::new();
    } else if unsafe {
        GetFileAttributesW(PCWSTR::from_raw(wide(&s).as_ptr())) == INVALID_FILE_ATTRIBUTES
    } {
        // 超长路径：按截断路径试一次，失败则报错返回。
        return String::new();
    }

    if unsafe { GetFileAttributesW(PCWSTR::from_raw(wide(&s).as_ptr())) == INVALID_FILE_ATTRIBUTES }
    {
        return String::new();
    }
    s
}

/// 按扩展名判定视频（交给 D3D 播放器）还是 GIF/静态图（交给 GDI+）。
pub fn is_video_file(path: &str) -> bool {
    let lower = path.to_lowercase();
    [".mp4", ".mov", ".avi", ".wmv", ".mkv", ".webm", ".m4v"]
        .iter()
        .any(|e| lower.ends_with(e))
}

// ---------- 进程互认 / 拉起 ----------

/// pid 进程的可执行文件是否位于本 exe 目录且名为 exe_name。
/// QueryFullProcessImageNameW 失败时按“存活”处理（保守，避免误判把还在跑的
/// 进程再拉起一次）。
pub fn is_our_process(pid: u32, exe_name: &str) -> bool {
    if pid == 0 {
        return false;
    }
    unsafe {
        let h = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) {
            Ok(h) => h,
            Err(_) => return false,
        };
        let mut buf = [0u16; MAX_PATH_LEN];
        let mut cch = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(h, PROCESS_NAME_FORMAT(0), PWSTR::from_raw(buf.as_mut_ptr()), &mut cch)
            .is_ok();
        let _ = CloseHandle(h);
        if !ok {
            return true;
        }
        let path = from_wide(&buf);
        let (dir, fname) = match path.rfind('\\') {
            Some(i) => (path[..i + 1].to_string(), &path[i + 1..]),
            None => (String::new(), path.as_str()),
        };
        let self_full = exe_full_path();
        let (sdir, _) = match self_full.rfind('\\') {
            Some(i) => (&self_full[..i + 1], &self_full[i + 1..]),
            None => (self_full.as_str(), ""),
        };
        dir.eq_ignore_ascii_case(sdir) && fname.eq_ignore_ascii_case(exe_name)
    }
}

/// 拉起同名目录下的 exe（守护拉主进程 / 主进程拉守护）。
pub fn launch_exe(name: &str) {
    let exe = format!("{}{}", exe_dir(), name);
    unsafe {
        if GetFileAttributesW(PCWSTR::from_raw(wide(&exe).as_ptr())) == INVALID_FILE_ATTRIBUTES {
            return;
        }
        let mut wexe = wide(&exe);
        if wexe.len() - 1 >= MAX_PATH_LEN {
            return; // 与 resolve_media_path 相同的超长保护
        }
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let r = CreateProcessW(
            PCWSTR::from_raw(wexe.as_ptr()),
            PWSTR::from_raw(wexe.as_mut_ptr()),
            None,
            None,
            FALSE,
            DETACHED_PROCESS,
            None,
            None,
            &si,
            &mut pi,
        );
        if r.is_ok() {
            let _ = CloseHandle(pi.hProcess);
            let _ = CloseHandle(pi.hThread);
        }
    }
}

// ---------- 单实例互斥 ----------

/// 创建命名互斥体；返回 true 表示“本进程是首个持有者”。
pub fn create_single_instance(name: &str) -> bool {
    unsafe {
        match CreateMutexW(None, TRUE, PCWSTR::from_raw(wide(name).as_ptr())) {
            Ok(h) => {
                // 互斥体已存在时 CreateMutexW 仍返回有效句柄，但会置 last-error 为
                // ERROR_ALREADY_EXISTS；此时本进程是后来者。
                let already = GetLastError() == ERROR_ALREADY_EXISTS;
                if already {
                    let _ = CloseHandle(h);
                    false
                } else {
                    // 故意不关闭句柄：让互斥体随进程存活（对齐 cpp 行为）。
                    let _ = h;
                    true
                }
            }
            Err(_) => false,
        }
    }
}

// ---------- 重启管理器注册（防系统重启/强杀后由系统恢复） ----------

/// 注册 Windows 重启管理器（进程被外部强杀后系统自动拉起；正常退出码 0 不触发）。
pub fn register_restart() {
    unsafe {
        if let Ok(h) = GetModuleHandleW(w!("kernel32.dll")) {
            if let Some(p) = GetProcAddress(h, s!("RegisterApplicationRestart")) {
                type Fn = unsafe extern "system" fn(PCWSTR, u32) -> HRESULT;
                let f: Fn = std::mem::transmute(p);
                // 空命令行：重启时沿用原启动方式。
                let _ = f(PCWSTR::null(), 0);
            }
        }
    }
}
