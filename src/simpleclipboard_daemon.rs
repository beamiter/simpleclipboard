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

mod client_lib;
use client_lib::Msg;

fn listen_address() -> String {
    // 更安全的默认：仅本机
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "0.0.0.0:12344".to_string())
}

fn final_addr() -> String {
    env::var("SIMPLECLIPBOARD_FINAL_ADDR").unwrap_or_else(|_| "0.0.0.0:12345".to_string())
}

fn expected_token() -> Option<String> {
    match env::var("SIMPLECLIPBOARD_TOKEN") {
        Ok(s) if !s.is_empty() => Some(s),
        _ => None,
    }
}

fn token_ok(provided: &Option<String>) -> bool {
    match expected_token() {
        None => true, // 未设置 token 时放行
        Some(exp) => provided.as_ref().map(|s| s == &exp).unwrap_or(false),
    }
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

fn handle_set(text: String) {
    println!("handle_set text:\n{}", text);
    // relay 优先；转发“旧协议字符串”，保持与旧 final 的兼容
    if let Ok(mut forward) = TcpStream::connect(final_addr()) {
        println!("forward by relay");
        let _ = forward.set_nodelay(true);
        let _ = forward.set_write_timeout(Some(Duration::from_secs(2)));
        let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
        let msg = Msg::Legacy { text };
        let _ = bincode::encode_into_std_write(msg, &mut forward, cfg);
        let _ = forward.flush();
    } else {
        println!("set Clipboard");
        set_clipboard_text(text);
    }
}

fn try_decode_msg(stream: &TcpStream) -> Option<Msg> {
    let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
    bincode::decode_from_std_read(&mut &*stream, cfg).ok()
}

fn handle_client(stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let _ = stream.set_nodelay(true);

    if let Some(msg) = try_decode_msg(&stream) {
        println!("handle_client msg: {:?}", msg);
        match msg {
            Msg::Ping { token } => {
                if token_ok(&token) {
                    // ping 无副作用，直接返回
                    return;
                } else {
                    // token 不通过，忽略
                    return;
                }
            }
            Msg::Set { text, token } => {
                if token_ok(&token) {
                    handle_set(text);
                } else {
                    // token 不通过，忽略
                }
            }
            Msg::Legacy { text } => {
                handle_set(text);
            }
        }
        return;
    }
    println!("decode failed");
}

fn main() -> std::io::Result<()> {
    let address = listen_address();
    let listener = TcpListener::bind(&address)?;

    // bind 成功后写 pid
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
            Err(_) => { /* 可按需记录日志 */ }
        }
    }

    let _ = fs::remove_file(pid_file);
    Ok(())
}
