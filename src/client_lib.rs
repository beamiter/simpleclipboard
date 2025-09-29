// src/client_lib.rs
use libc::c_char;
use std::ffi::CStr;
use std::io::Write;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

const MAX_BYTES: usize = 160 * 1024 * 1024; // 160MB

#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    let payload_cstr = unsafe {
        match CStr::from_ptr(payload).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        }
    };

    let (address_str, text_str) = match payload_cstr.split_once('\u{1}') {
        Some(t) => t,
        None => return 0,
    };

    // 尝试解析 socket 地址（以便 connect_timeout）
    let addrs = match address_str.to_socket_addrs() {
        Ok(a) => a.collect::<Vec<_>>(),
        Err(_) => return 0,
    };
    if addrs.is_empty() {
        return 0;
    }

    // 连接（可考虑缩短超时）
    let timeout = Duration::from_millis(800);
    let mut stream = match TcpStream::connect_timeout(&addrs[0], timeout) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    // 提升交互响应性
    let _ = stream.set_nodelay(true);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));

    let config = bincode::config::standard().with_limit::<MAX_BYTES>();
    // 直接编码 &str，避免 clone
    match bincode::encode_into_std_write(text_str, &mut stream, config) {
        Ok(_) => {
            let _ = stream.flush();
            1
        }
        Err(_) => 0,
    }
}
