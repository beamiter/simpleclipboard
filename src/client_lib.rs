// src/client_lib.rs

use libc::c_char;
use std::ffi::CStr;
use std::net::TcpStream;

// 函数现在只接收一个参数
#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    let payload_cstr = unsafe {
        if payload.is_null() {
            return 0;
        }
        CStr::from_ptr(payload)
    };

    // 我们期望的格式是 "address\0text"
    // CStr::to_bytes_with_nul() 会包含结尾的 NUL，我们需要的是不包含的
    let payload_bytes = payload_cstr.to_bytes();

    // 寻找第一个 NUL 分隔符
    if let Some(nul_pos) = payload_bytes.iter().position(|&b| b == 0) {
        // 分割出地址和文本
        let address_bytes = &payload_bytes[..nul_pos];
        let text_bytes = &payload_bytes[nul_pos + 1..];

        let address_str = match std::str::from_utf8(address_bytes) {
            Ok(s) => s,
            Err(_) => return 0,
        };

        let text_str = match std::str::from_utf8(text_bytes) {
            Ok(s) => s.to_string(),
            Err(_) => return 0,
        };

        // --- 后续逻辑与之前相同 ---
        match TcpStream::connect(address_str) {
            Ok(mut stream) => {
                let config = bincode::config::standard();
                match bincode::encode_into_std_write(text_str, &mut stream, config) {
                    Ok(_) => 1,
                    Err(_) => 0,
                }
            }
            Err(_) => 0,
        }
    } else {
        // 如果找不到 NUL 分隔符，说明格式错误
        0
    }
}
