// src/client_lib.rs

use libc::c_char;
use std::ffi::CStr;
use std::net::TcpStream;

const MAX_BYTES: usize = 160 * 1024 * 1024; // 160MB 限制

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    let payload_cstr = unsafe {
        match CStr::from_ptr(payload).to_str() {
            Ok(s) => s,
            Err(_) => {
                // eprintln!("[Rust Error] Payload is not valid UTF-8");
                return 0;
            }
        }
    };

    if let Some((address_str, text_str)) = payload_cstr.split_once('\u{1}') {
        match TcpStream::connect(address_str) {
            Ok(mut stream) => {
                let config = bincode::config::standard().with_limit::<MAX_BYTES>();
                match bincode::encode_into_std_write(text_str.to_string(), &mut stream, config) {
                    Ok(_) => 1,
                    Err(e) => {
                        // eprintln!("[Rust Error] Bincode encode failed: {}", e);
                        0
                    }
                }
            }
            Err(e) => {
                // eprintln!("[Rust Error] TCP connect failed: {}", e);
                0
            }
        }
    } else {
        // eprintln!("[Rust Error] Separator not found in payload.");
        0
    }
}
