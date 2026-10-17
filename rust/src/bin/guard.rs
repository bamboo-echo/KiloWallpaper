// guard.rs — KiloWallpaper (Rust) 独立守护进程，对齐 cpp/guard.cpp
//
// 独立进程名 DynamicWallpaperGuard.exe；主进程被强杀后约 1 秒内拉起；
// 看到 wallpaper.graceful 且主进程确实已退出时，自己退出、绝不复活。

use std::thread::sleep;
use std::time::Duration;

use kilowallpaper::common;

fn main() {
    if !common::create_single_instance("DynamicWallpaper_Guard") {
        return;
    }
    common::write_pid_file("wallpaper.guard.pid");
    common::register_restart();

    let mut just_launched = false;
    loop {
        sleep(Duration::from_secs(1));

        if common::file_exists("wallpaper.graceful") {
            // 先确认主进程确实已退出再消费 graceful，避免误删新会话的 ok。
            if !common::is_our_process(
                common::read_pid_file("wallpaper.main.pid"),
                "DynamicWallpaper.exe",
            ) {
                common::delete_file("wallpaper.graceful");
                common::delete_file("wallpaper.ok");
                return;
            }
            common::delete_file("wallpaper.graceful");
            continue;
        }

        if common::is_our_process(
            common::read_pid_file("wallpaper.main.pid"),
            "DynamicWallpaper.exe",
        ) {
            just_launched = false;
            continue;
        }

        // 从未成功初始化则不保活；刚拉起过一次又不见则停（防重启风暴）。
        if !common::file_exists("wallpaper.ok") || just_launched {
            return;
        }

        // 不要代删 wallpaper.quit：那是用户的关闭请求，留给主进程消费。
        just_launched = true;
        common::delete_file("wallpaper.ok");
        common::launch_exe("DynamicWallpaper.exe");
    }
}
