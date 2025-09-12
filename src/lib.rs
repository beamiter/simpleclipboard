// src/lib.rs

use std::ffi::CStr;
use std::io::Write;
use std::os::raw::{c_char, c_int};
use std::os::unix::net::UnixStream;

const SOCKET_PATH: &str = "/tmp/simpleclipboard.sock";

#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard(input: *const c_char) -> c_int {
    if input.is_null() {
        return 0; // 输入为空
    }

    let text: String = unsafe { CStr::from_ptr(input).to_string_lossy().into_owned() };

    // 尝试连接到守护进程的 socket
    match UnixStream::connect(SOCKET_PATH) {
        Ok(mut stream) => {
            // --- 修改这里 ---
            let config = bincode::config::standard();
            let encoded: Vec<u8> = match bincode::encode_to_vec(&text, config) {
                Ok(enc) => enc,
                Err(_) => return 0, // 序列化失败
            };
            // ----------------

            // 将数据写入流
            match stream.write_all(&encoded) {
                Ok(_) => 1, // 发送成功
                Err(_) => 0, // 写入失败
            }
        }
        Err(_) => {
            // 连接守护进程失败
            0
        }
    }
}
