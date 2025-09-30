// src/client_lib.rs

use libc::c_char;
use std::ffi::CStr;
use std::io::Write;
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use bincode::{Decode, Encode};

const MAX_BYTES: usize = 160 * 1024 * 1024; // 160MB

#[derive(Debug, Encode, Decode)]
pub enum Msg {
    Ping { token: Option<String> },
    Set { text: String, token: Option<String> },
    Legacy { text: String },
}

fn connect_with_timeout(addr: &str) -> std::io::Result<TcpStream> {
    let addrs = addr.to_socket_addrs()?.collect::<Vec<_>>();
    if addrs.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "no addr",
        ));
    }
    let timeout = Duration::from_millis(800);
    let s = TcpStream::connect_timeout(&addrs[0], timeout)?;
    let _ = s.set_nodelay(true);
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
    Ok(s)
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    // payload 字符串格式：
    // 旧协议： "address \x01 text"
    // 新协议：
    //   Set:  "address \x01 set  \x01 text  \x01 token?"
    //   Ping: "address \x01 ping \x01 ''    \x01 token?"
    let payload_cstr = unsafe {
        match CStr::from_ptr(payload).to_str() {
            Ok(s) => s,
            Err(_) => return 0,
        }
    };

    let parts: Vec<&str> = payload_cstr.split('\u{1}').collect();
    if parts.len() < 2 {
        return 0;
    }
    let address = parts[0];

    // 建立连接
    let mut stream = match connect_with_timeout(address) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let config = bincode::config::standard().with_limit::<MAX_BYTES>();

    if parts.len() == 2 {
        // 旧协议：发送纯字符串（保持向后兼容）
        let text = parts[1].to_string();
        let msg = Msg::Legacy { text };
        match bincode::encode_into_std_write(msg, &mut stream, config) {
            Ok(_) => {
                let _ = stream.flush();
                1
            }
            Err(_) => 0,
        }
    } else {
        // 新协议：解析 action + text + token
        let action = parts[1];
        let text = if parts.len() >= 3 { parts[2] } else { "" };
        let token = if parts.len() >= 4 && !parts[3].is_empty() {
            Some(parts[3].to_string())
        } else {
            None
        };

        let msg = match action {
            "ping" => Msg::Ping { token },
            "set" => Msg::Set {
                text: text.to_string(),
                token,
            },
            _ => {
                // 未知 action，当作失败
                return 0;
            }
        };

        match bincode::encode_into_std_write(msg, &mut stream, config) {
            Ok(_) => {
                let _ = stream.flush();
                1
            }
            Err(_) => 0,
        }
    }
}
