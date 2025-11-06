use libc::c_char;
use std::ffi::CStr;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpStream, ToSocketAddrs};
use std::time::Duration;

use bincode::{Decode, Encode};

const MAX_BYTES: usize = 160 * 1024 * 1024;
// 帧格式魔术字
const FRAME_MAGIC: &[u8; 4] = b"SCB1";

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
    let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
    let _ = s.set_read_timeout(Some(Duration::from_secs(10))); // 放宽 ACK 读取超时
    Ok(s)
}

#[unsafe(no_mangle)]
pub extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    // payload 格式：
    //   Set:    "address \x01 set  \x01 text  \x01 token?"
    //   Ping:   "address \x01 ping \x01 ''    \x01 token?"
    //   Legacy: "address \x01 set  \x01 text"（兼容旧调用）
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

    // 构造消息并用帧格式写出
    let msg = if parts.len() == 2 {
        let text = parts[1].to_string();
        Msg::Legacy { text }
    } else {
        let action = parts[1];
        let text = if parts.len() >= 3 { parts[2] } else { "" };
        let token = if parts.len() >= 4 && !parts[3].is_empty() {
            Some(parts[3].to_string())
        } else {
            None
        };
        match action {
            "ping" => Msg::Ping { token },
            "set" => Msg::Set { text: text.to_string(), token },
            _ => return 0,
        }
    };

    let msg_buf = match bincode::encode_to_vec(msg, config) {
        Ok(buf) => buf,
        Err(_) => return 0,
    };

    // 写帧头 + 长度 + 负载
    if stream.write_all(FRAME_MAGIC).is_err() {
        return 0;
    }
    if stream
        .write_all(&(msg_buf.len() as u32).to_be_bytes())
        .is_err()
    {
        return 0;
    }
    if stream.write_all(&msg_buf).is_err() {
        return 0;
    }
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Write); // 半关闭写端，便于服务端尽快读到 EOF（旧服务端兼容）

    // 读取 ACK：优先新帧；不是帧头则回退旧方式
    let mut magic = [0u8; 4];
    match stream.read_exact(&mut magic) {
        Ok(()) => {}
        Err(_e) => {
            // 旧守护不返回 ACK：保持旧行为（视为成功）
            return 1;
        }
    }

    if &magic != FRAME_MAGIC {
        // 回退旧 ACK：把已读 4 字节当作 ACK 开头，继续读到 EOF
        let mut buf = magic.to_vec();
        let mut tmp = [0u8; 1024];
        loop {
            match stream.read(&mut tmp) {
                Ok(0) => break,
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                Err(_e) => {
                    // 旧守护或读取失败：兼容旧行为，视为成功
                    return 1;
                }
            }
        }
        // 尝试解码；失败也视为成功以兼容旧版
        match bincode::decode_from_slice::<Ack, _>(&buf, config) {
            Ok((ack, _)) => {
                if ack.ok {
                    1
                } else if matches!(ack.detail.as_deref(), Some("forward_failed_fallback_ok")) {
                    // 转发失败但本地 fallback 成功：视为成功，避免 Vim 端强制走 OSC52
                    1
                } else {
                    0
                }
            }
            Err(_) => 1,
        }
    } else {
        // 新帧 ACK
        let mut len_buf = [0u8; 4];
        if stream.read_exact(&mut len_buf).is_err() {
            return 1; // 兼容旧版
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len == 0 || len > MAX_BYTES {
            return 0;
        }
        let mut buf = vec![0u8; len];
        if stream.read_exact(&mut buf).is_err() {
            return 1; // 兼容旧版
        }
        match bincode::decode_from_slice::<Ack, _>(&buf, config) {
            Ok((ack, _)) => {
                if ack.ok {
                    1
                } else if matches!(ack.detail.as_deref(), Some("forward_failed_fallback_ok")) {
                    1
                } else {
                    0
                }
            }
            Err(_) => 1,
        }
    }
}
