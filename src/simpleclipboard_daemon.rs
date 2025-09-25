// src/daemon.rs

use arboard::Clipboard;
use lazy_static::lazy_static;
use listenfd::ListenFd;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Mutex;

// 使用 XDG_RUNTIME_DIR 更安全；无则退回 /tmp
fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn socket_path() -> PathBuf {
    runtime_dir().join("simpleclipboard.sock")
}

fn pid_path() -> PathBuf {
    runtime_dir().join("simpleclipboard.pid")
}

lazy_static! {
    static ref CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(Clipboard::new().ok());
}

fn set_clipboard_text(text: String) {
    let mut lock = CLIPBOARD.lock().unwrap();

    // 若实例为空尝试重建
    if lock.is_none() {
        *lock = Clipboard::new().ok();
    }

    if let Some(cb) = lock.as_mut() {
        if let Err(e) = cb.set_text(text.clone()) {
            eprintln!("[Daemon] set_text failed: {:?}, retry re-init...", e);
            // 失败后重建再试一次
            *lock = Clipboard::new().ok();
            if let Some(cb2) = lock.as_mut() {
                if let Err(e2) = cb2.set_text(text) {
                    eprintln!("[Daemon] set_text still failed after reinit: {:?}", e2);
                } else {
                    println!("[Daemon] Successfully set clipboard (after reinit).");
                }
            } else {
                eprintln!("[Daemon] Clipboard not available after reinit.");
            }
        } else {
            println!("[Daemon] Successfully set clipboard.");
        }
    } else {
        eprintln!("[Daemon] Clipboard is not available.");
    }
}

fn handle_client(mut stream: UnixStream) {
    println!("[Daemon] Client connected.");

    const MAX_BYTES: usize = 16 * 1024 * 1024;
    let config = bincode::config::standard().with_limit::<MAX_BYTES>();

    // 通过结果的类型标注，明确 D=String，让编译器完成推断
    let res: Result<String, _> = bincode::decode_from_std_read(&mut stream, config);

    match res {
        Ok(text) => {
            println!("[Daemon] Received {} bytes of text.", text.len());
            set_clipboard_text(text);
        }
        Err(e) => {
            eprintln!("[Daemon] Error deserializing data: {}", e);
        }
    }
}

fn main() -> std::io::Result<()> {
    let pid_file = pid_path();
    let sock_path = socket_path();

    // 写 PID 文件
    let pid = std::process::id();
    fs::write(&pid_file, pid.to_string())?;
    println!(
        "[Daemon] Started with PID: {}. Wrote to {:?}",
        pid, pid_file
    );

    // 清理旧 socket
    if sock_path.exists() {
        let _ = fs::remove_file(&sock_path);
    }

    let mut listenfd = ListenFd::from_env();
    let listener = if let Some(l) = listenfd.take_unix_listener(0)? {
        println!("[Daemon] Using listener from systemd/listenfd.");
        l
    } else {
        println!("[Daemon] Binding to socket at {:?}", sock_path);
        let l = UnixListener::bind(&sock_path)?;
        // 限制权限
        let _ = fs::set_permissions(&sock_path, fs::Permissions::from_mode(0o600));
        l
    };

    println!("[Daemon] Server listening on {:?}", sock_path);

    // 优雅退出时清理 socket 与 pid 文件（需要 ctrlc 依赖）
    {
        let sock_for_drop = sock_path.clone();
        let pid_for_drop = pid_file.clone();
        ctrlc::set_handler(move || {
            let _ = fs::remove_file(&sock_for_drop);
            let _ = fs::remove_file(&pid_for_drop);
            std::process::exit(0);
        })
        .ok();
    }

    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                std::thread::spawn(|| handle_client(stream));
            }
            Err(e) => {
                eprintln!("[Daemon] Connection failed: {}", e);
            }
        }
    }

    Ok(())
}
