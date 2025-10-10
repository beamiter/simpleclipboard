use libc::c_char;
use std::ffi::CStr;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::time::Duration;

use bincode::{Decode, Encode};

const MAX_BYTES: usize = 160 * 1024 * 1024;

#[derive(Debug, Encode, Decode)]
pub enum Msg {
    Ping { token: Option<String> },
    Set { text: String, token: Option<String> },
    Legacy { text: String },
}

#[derive(Debug, Encode, Decode)]
pub struct Ack {
    pub ok: bool,
    pub detail: Option<String>,
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
    let _ = s.set_read_timeout(Some(Duration::from_millis(1200))); // 读 ACK 的超时
    Ok(s)
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    // payload 格式：
    //   Set:    "address \x01 set  \x01 text  \x01 token?"
    //   Ping:   "address \x01 ping \x01 ''    \x01 token?"
    //   Legacy: "address \x01 set  \x01 text"
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

    let mut stream = match connect_with_timeout(address) {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let config = bincode::config::standard().with_limit::<MAX_BYTES>();

    let write_ok = if parts.len() == 2 {
        let text = parts[1].to_string();
        let msg = Msg::Legacy { text };
        bincode::encode_into_std_write(msg, &mut stream, config).is_ok()
    } else {
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
            _ => return 0,
        };

        bincode::encode_into_std_write(msg, &mut stream, config).is_ok()
    };

    if !write_ok {
        return 0;
    }

    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Write); // 半关闭写端，便于服务端读到 EOF

    // 读取 ACK（新守护进程支持）。为兼容旧版，如读取失败/超时则返回成功。
    let mut buf = Vec::new();
    let mut tmp = [0u8; 1024];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break, // EOF
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(_e) => {
                // 读失败或超时：旧守护不返回 ACK，保持旧行为（视为成功）
                return 1;
            }
        }
    }

    if buf.is_empty() {
        // 旧守护不返回 ACK，视为成功
        return 1;
    }

    match bincode::decode_from_slice::<Ack, _>(&buf, config) {
        Ok((ack, _consumed)) => {
            if ack.ok {
                1
            } else {
                0
            }
        }
        Err(_e) => {
            // ACK 解码失败也视为成功（兼容旧版）
            1
        }
    }
}
