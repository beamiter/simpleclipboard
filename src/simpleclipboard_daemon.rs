// src/simpleclipboard_daemon.rs

use arboard::Clipboard;
use lazy_static::lazy_static;
use std::fs;
use std::net::{TcpListener, TcpStream}; // <--- 修改点
use std::path::PathBuf;
use std::sync::Mutex;
use std::env; // <--- 新增，用于读取环境变量

// 获取监听地址，优先从环境变量读取，否则使用默认值
fn listen_address() -> String {
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "0.0.0.0:12345".to_string())
}

fn pid_path() -> PathBuf {
    // runtime_dir 函数保持不变
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("simpleclipboard.pid")
}

lazy_static! {
    static ref CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(Clipboard::new().ok());
}

// set_clipboard_text 函数保持不变...
fn set_clipboard_text(text: String) {
    let mut lock = CLIPBOARD.lock().unwrap();
    if lock.is_none() { *lock = Clipboard::new().ok(); }
    if let Some(cb) = lock.as_mut() {
        if let Err(e) = cb.set_text(text.clone()) {
            eprintln!("[Daemon] set_text failed: {:?}, retrying...", e);
            *lock = Clipboard::new().ok();
            if let Some(cb2) = lock.as_mut() {
                if let Err(e2) = cb2.set_text(text) {
                    eprintln!("[Daemon] set_text still failed: {:?}", e2);
                }
            }
        }
    } else {
        eprintln!("[Daemon] Clipboard is not available.");
    }
}

// 参数类型从 UnixStream 改为 TcpStream
fn handle_client(mut stream: TcpStream) {
    println!("[Daemon] Client connected from {:?}.", stream.peer_addr().ok());

    // bincode 序列化保持不变
    const MAX_BYTES: usize = 16 * 1024 * 1024;
    let config = bincode::config::standard().with_limit::<MAX_BYTES>();
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

    // 写 PID 文件逻辑保持不变
    let pid = std::process::id();
    fs::write(&pid_file, pid.to_string())?;
    println!("[Daemon] Started with PID: {}. Wrote to {:?}", pid, pid_file);

    // 移除所有 Unix Socket 相关代码
    // if sock_path.exists() { ... }

    // 监听 TCP 端口
    let address = listen_address();
    let listener = TcpListener::bind(&address)?;
    println!("[Daemon] Server listening on {}", address);

    // 优雅退出时清理 pid 文件
    {
        let pid_for_drop = pid_file.clone();
        ctrlc::set_handler(move || {
            let _ = fs::remove_file(&pid_for_drop);
            std::process::exit(0);
        }).ok();
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
