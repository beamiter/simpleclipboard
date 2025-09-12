// src/daemon.rs

use arboard::Clipboard;
use lazy_static::lazy_static;
use listenfd::ListenFd;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Mutex;

const SOCKET_PATH: &str = "/tmp/simpleclipboard.sock";
// --- 新增：从这里也引用 PID_FILE ---
const PID_FILE: &str = "/tmp/simpleclipboard.pid";

lazy_static! {
    static ref CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(Clipboard::new().ok());
}

fn handle_client(mut stream: UnixStream) {
    // ... (这部分代码保持不变)
    println!("[Daemon] Client connected.");
    let mut buffer = Vec::new();
    match stream.read_to_end(&mut buffer) {
        Ok(_) => {
            let config = bincode::config::standard();
            let (text, _len): (String, usize) = match bincode::decode_from_slice(&buffer, config) {
                Ok(decoded) => decoded,
                Err(e) => {
                    eprintln!("[Daemon] Error deserializing data: {}", e);
                    return;
                }
            };

            println!("[Daemon] Received {} bytes of text.", text.len());

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
    // --- 关键修改：守护进程自己写入 PID 文件 ---
    // 1. 获取自己的 PID
    let pid = std::process::id();

    // 2. 将 PID 写入文件
    fs::write(PID_FILE, pid.to_string())?;
    println!("[Daemon] Started with PID: {}. Wrote to {}", pid, PID_FILE);
    // -----------------------------------------

    let path = Path::new(SOCKET_PATH);
    if path.exists() {
        fs::remove_file(path)?;
    }

    let mut listenfd = ListenFd::from_env();
    let listener = if let Some(l) = listenfd.take_unix_listener(0)? {
        println!("[Daemon] Using listener from systemd/listenfd.");
        l
    } else {
        println!("[Daemon] Binding to socket at {}", SOCKET_PATH);
        UnixListener::bind(path)?
    };

    println!("[Daemon] Server listening on {}", SOCKET_PATH);

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
