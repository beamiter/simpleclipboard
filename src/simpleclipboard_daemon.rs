// src/simpleclipboard_daemon.rs
use arboard::Clipboard;
use lazy_static::lazy_static;
use std::env;
use std::fs;
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

const MAX_BYTES: usize = 160 * 1024 * 1024; // 160MB

fn listen_address() -> String {
    // 更安全的默认值：仅本机访问
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "127.0.0.1:12344".to_string())
}

fn final_addr() -> String {
    env::var("SIMPLECLIPBOARD_FINAL_ADDR").unwrap_or_else(|_| "127.0.0.1:12345".to_string())
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
    if lock.is_none() {
        *lock = Clipboard::new().ok();
    }
    if let Some(cb) = lock.as_mut() {
        if let Err(_) = cb.set_text(text.clone()) {
            *lock = Clipboard::new().ok();
            if let Some(cb2) = lock.as_mut() {
                let _ = cb2.set_text(text);
            }
        }
    }
}

fn handle_client(mut stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_nodelay(true);

    let config = bincode::config::standard().with_limit::<MAX_BYTES>();
    let res: Result<String, _> = bincode::decode_from_std_read(&mut stream, config);

    if let Ok(text) = res {
        // relay 优先尝试
        if let Ok(mut forward_stream) = TcpStream::connect(final_addr()) {
            let _ = forward_stream.set_nodelay(true);
            let _ = forward_stream.set_write_timeout(Some(Duration::from_secs(2)));
            let bconfig = bincode::config::standard().with_limit::<MAX_BYTES>();
            let _ = bincode::encode_into_std_write(text, &mut forward_stream, bconfig);
            let _ = forward_stream.flush();
        } else {
            set_clipboard_text(text);
        }
    }
}

fn main() -> std::io::Result<()> {
    let address = listen_address();
    let listener = TcpListener::bind(&address)?;
    // 只有 bind 成功后才写 pid
    let pid_file = pid_path();
    let pid = std::process::id();
    fs::write(&pid_file, pid.to_string())?;

    {
        let pid_for_drop = pid_file.clone();
        ctrlc::set_handler(move || {
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
            Err(_) => { /* 可按需日志 */ }
        }
    }

    // 退出时清理 pid（正常情况不会到达）
    let _ = fs::remove_file(pid_file);
    Ok(())
}
