// src/daemon.rs

use arboard::Clipboard;
use lazy_static::lazy_static;
use listenfd::ListenFd;
use std::fs;
use std::io::Read;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Mutex;

// Unix Socket 的路径
const SOCKET_PATH: &str = "/tmp/simpleclipboard.sock";

lazy_static! {
    // 使用 Mutex 确保同一时间只有一个线程在操作剪贴板
    static ref CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(Clipboard::new().ok());
}

fn handle_client(mut stream: UnixStream) {
    println!("[Daemon] Client connected.");
    let mut buffer = Vec::new();
    match stream.read_to_end(&mut buffer) {
        Ok(_) => {
            // --- 修改这里 ---
            let config = bincode::config::standard();
            let (text, len): (String, usize) = match bincode::decode_from_slice(&buffer, config) {
                Ok(decoded) => decoded,
                Err(e) => {
                    eprintln!("[Daemon] Error deserializing data: {}", e);
                    return;
                }
            };
            // ----------------

            println!(
                "[Daemon] Received {} bytes of text (decoded {}).",
                buffer.len(),
                len
            );

            if let Some(cb) = &mut *CLIPBOARD.lock().unwrap() {
                match cb.set_text(text) {
                    Ok(_) => println!("[Daemon] Successfully set clipboard."),
                    Err(e) => eprintln!("[Daemon] Failed to set clipboard: {:?}", e),
                }
            } else {
                eprintln!("[Daemon] Clipboard is not available.");
            }
        }
        Err(e) => {
            eprintln!("[Daemon] Failed to read from stream: {}", e);
        }
    }
}

fn main() -> std::io::Result<()> {
    let path = Path::new(SOCKET_PATH);
    // 如果 socket 文件已存在，先删除它
    if path.exists() {
        fs::remove_file(path)?;
    }

    // 使用 listenfd 获取由 systemd 或其他工具提供的 listener
    let mut listenfd = ListenFd::from_env();
    let listener = if let Some(l) = listenfd.take_unix_listener(0)? {
        println!("[Daemon] Using listener from systemd/listenfd.");
        l
    } else {
        println!("[Daemon] Binding to socket at {}", SOCKET_PATH);
        UnixListener::bind(path)?
    };

    println!("[Daemon] Server listening on {}", SOCKET_PATH);

    // 接受传入的连接
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                // 为每个客户端生成一个新线程处理
                std::thread::spawn(|| handle_client(stream));
            }
            Err(e) => {
                eprintln!("[Daemon] Connection failed: {}", e);
            }
        }
    }

    Ok(())
}
