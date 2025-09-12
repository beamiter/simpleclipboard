// src/lib.rs
use std::ffi::CStr;
use std::io::Write;
use std::net::Shutdown;
use std::os::raw::{c_char, c_int};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;

const MAX_BYTES: usize = 16 * 1024 * 1024; // 16MB 上限，按需调整

fn socket_candidates() -> Vec<PathBuf> {
    let mut v = Vec::new();
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            v.push(PathBuf::from(dir).join("simpleclipboard.sock"));
        }
    }
    // 回退到 /tmp
    v.push(PathBuf::from("/tmp/simpleclipboard.sock"));
    v
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard(input: *const c_char) -> c_int {
    if input.is_null() {
        return 0;
    }

    let text: String = unsafe { CStr::from_ptr(input).to_string_lossy().into_owned() };
    if text.len() > MAX_BYTES {
        return 0;
    }

    // 逐个尝试候选 socket 路径
    for path in socket_candidates() {
        match UnixStream::connect(&path) {
            Ok(mut stream) => {
                let config = bincode::config::standard();
                // 直接写入流，避免额外分配
                if bincode::encode_into_std_write(&text, &mut stream, config).is_err() {
                    // 换下一个候选路径
                    continue;
                }
                let _ = stream.flush();
                let _ = stream.shutdown(Shutdown::Write);
                return 1; // 成功
            }
            Err(_) => {
                // 尝试下一个候选路径
                continue;
            }
        }
    }

    0 // 所有候选路径都失败
}
