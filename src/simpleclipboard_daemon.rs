// src/simpleclipboard_daemon.rs

use arboard::Clipboard;
use lazy_static::lazy_static;
use std::env;
use std::fs;
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Mutex;

// === 新增常量：定义本地守护进程的固定地址（SSH 隧道的目标） ===
const FINAL_DAEMON_ADDR: &str = "127.0.0.1:12345";

// 获取监听地址，优先从环境变量读取，否则使用默认值
fn listen_address() -> String {
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "0.0.0.0:12345".to_string())
}

fn pid_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("simpleclipboard.pid")
}

lazy_static! {
    static ref CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(Clipboard::new().ok());
}

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

// === handle_client 函数被重写以支持中继逻辑 ===
fn handle_client(mut stream: TcpStream) {
    println!("[Daemon] Client connected from {:?}.", stream.peer_addr().ok());

    const MAX_BYTES: usize = 160 * 1024 * 1024;
    let config = bincode::config::standard().with_limit::<MAX_BYTES>();
    let res: Result<String, _> = bincode::decode_from_std_read(&mut stream, config);

    match res {
        Ok(text) => {
            println!("[Daemon] Received {} bytes of text.", text.len());

            // 尝试连接到最终的目标守护进程（即 SSH 隧道）
            match TcpStream::connect(FINAL_DAEMON_ADDR) {
                Ok(mut forward_stream) => {
                    // 如果连接成功，说明当前是“中继模式”
                    println!("[Daemon] Acting as a relay, forwarding data to {}.", FINAL_DAEMON_ADDR);
                    let bincode_config = bincode::config::standard();
                    match bincode::encode_into_std_write(text, &mut forward_stream, bincode_config) {
                        Ok(_) => println!("[Daemon] Data forwarded successfully."),
                        Err(e) => eprintln!("[Daemon] Relay encode/send failed: {}", e),
                    }
                }
                Err(_) => {
                    // 如果连接失败，说明当前是“最终模式”（或者隧道没开）
                    // 回退到原始行为：直接设置本地剪贴板
                    println!("[Daemon] Not in relay mode (or tunnel is down). Setting local clipboard.");
                    set_clipboard_text(text);
                }
            }
        }
        Err(e) => {
            eprintln!("[Daemon] Error deserializing data: {}", e);
        }
    }
}

fn main() -> std::io::Result<()> {
    let pid_file = pid_path();
    let pid = std::process::id();
    // 注意：中继守护进程也会写PID文件，但我们的逻辑依赖端口检查，所以影响不大。
    fs::write(&pid_file, pid.to_string())?;
    println!("[Daemon] Started with PID: {}. Wrote to {:?}", pid, pid_file);

    let address = listen_address();
    let listener = TcpListener::bind(&address)?;
    println!("[Daemon] Server listening on {}", address);

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
