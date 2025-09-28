// src/client_lib.rs

use libc::c_char;
use std::ffi::CStr;
use std::net::TcpStream;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    let payload_cstr = unsafe {
        match CStr::from_ptr(payload).to_str() {
            Ok(s) => s,
            Err(_) => {
                eprintln!("[Rust Error] Payload is not valid UTF-8");
                return 0;
            }
        }
    };
    // eprintln!("[Rust Received] Raw Payload: {:?}", payload_cstr);

    // 使用 \u{1} (即 \x01) 作为分隔符
    // String::split_once 是一个更安全、更符合 Rust 习惯的写法
    if let Some((address_str, text_str)) = payload_cstr.split_once('\u{1}') {
        // eprintln!("[Rust Parsed] Address: {}, Text: {}", address_str, text_str);
        match TcpStream::connect(address_str) {
            Ok(mut stream) => {
                let config = bincode::config::standard();
                match bincode::encode_into_std_write(text_str.to_string(), &mut stream, config) {
                    Ok(_) => 1,
                    Err(e) => {
                        eprintln!("[Rust Error] Bincode encode failed: {}", e);
                        0
                    }
                }
            }
            Err(e) => {
                eprintln!("[Rust Error] TCP connect failed: {}", e);
                0
            }
        }
    } else {
        // 如果找不到分隔符，说明格式错误
        eprintln!("[Rust Error] Separator not found in payload.");
        0
    }
}
