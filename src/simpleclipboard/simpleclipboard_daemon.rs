use arboard::Clipboard;
use bincode::{Decode, Encode};
use log::{debug, info, warn};
use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::task;
use tokio::time::timeout;

const MAX_BYTES: usize = 10 * 1024 * 1024; // 10 MiB，剪贴板文本足够
const READ_TIMEOUT: Duration = Duration::from_secs(30);
const HANDLE_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_CONCURRENT: usize = 256;
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

fn pid_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("simpleclipboard.pid")
}

fn listen_address() -> String {
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "127.0.0.1:12343".to_string())
}

fn final_addr() -> Option<String> {
    let v = env::var("SIMPLECLIPBOARD_FINAL_ADDR").unwrap_or_default();
    if v.is_empty() { None } else { Some(v) }
}

fn expected_token() -> Option<String> {
    match env::var("SIMPLECLIPBOARD_TOKEN") {
        Ok(s) if !s.is_empty() => Some(s),
        _ => None,
    }
}

fn token_ok(provided: &Option<String>) -> bool {
    match expected_token() {
        None => true,
        Some(exp) => provided.as_ref().is_some_and(|s| s == &exp),
    }
}

static CLIPBOARD: LazyLock<Mutex<Option<Clipboard>>> =
    LazyLock::new(|| Mutex::new(Clipboard::new().ok()));

async fn set_clipboard_text_async(text: String) -> bool {
    task::spawn_blocking(move || {
        let mut lock = CLIPBOARD.lock().unwrap();
        if lock.is_none() {
            *lock = Clipboard::new().ok();
        }
        if let Some(cb) = lock.as_mut() {
            if cb.set_text(text.clone()).is_ok() {
                return true;
            }
            // 失败后重建再试一次
            *lock = Clipboard::new().ok();
            if let Some(cb2) = lock.as_mut() {
                return cb2.set_text(text).is_ok();
            }
        }
        false
    })
    .await
    .unwrap_or(false)
}

// 转发到最终地址时保留"旧协议"以兼容（写完整 bincode，读到 EOF）
async fn forward_legacy_async(addr: &str, text: String) -> io::Result<()> {
    let mut s = TcpStream::connect(addr).await?;
    let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
    let msg = Msg::Legacy { text };
    let mut buf = Vec::new();
    bincode::encode_into_std_write(msg, &mut buf, cfg)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "encode failed"))?;
    s.write_all(&buf).await?;
    s.flush().await?;
    Ok(())
}

/// 处理剪贴板设置逻辑（Set 和 Legacy 共用）
async fn handle_set_text(text: String, final_addr: &Option<String>) -> Ack {
    if let Some(addr) = final_addr {
        match forward_legacy_async(addr, text.clone()).await {
            Ok(()) => Ack { ok: true, detail: Some("forwarded".into()) },
            Err(e) => {
                warn!("Relay forward failed: {e}. Fallback to local clipboard");
                let ok = set_clipboard_text_async(text).await;
                Ack {
                    ok: false,
                    detail: Some(if ok { "forward_failed_fallback_ok" } else { "forward_failed_fallback_err" }.into()),
                }
            }
        }
    } else {
        let ok = set_clipboard_text_async(text).await;
        Ack {
            ok,
            detail: Some(if ok { "local_set_ok" } else { "local_set_err" }.into()),
        }
    }
}

async fn handle_msg(msg: Msg, final_addr: &Option<String>) -> Ack {
    match msg {
        Msg::Ping { token } => {
            if token_ok(&token) {
                info!("Ping accepted");
                Ack { ok: true, detail: Some("ping_ok".into()) }
            } else {
                warn!("Ping rejected by token");
                Ack { ok: false, detail: Some("token_rejected".into()) }
            }
        }
        Msg::Set { text, token } => {
            if !token_ok(&token) {
                warn!("Set rejected by token");
                Ack { ok: false, detail: Some("token_rejected".into()) }
            } else {
                handle_set_text(text, final_addr).await
            }
        }
        Msg::Legacy { text } => handle_set_text(text, final_addr).await,
    }
}

// 新协议读取：优先尝试帧格式（magic + len + payload），否则回退旧协议（读到 EOF）
async fn read_full_msg(stream: &mut TcpStream) -> io::Result<Msg> {
    let mut magic = [0u8; 4];
    match timeout(READ_TIMEOUT, stream.read_exact(&mut magic)).await {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => return Err(e),
        Err(_) => return Err(io::Error::new(io::ErrorKind::TimedOut, "read magic timeout")),
    }

    let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();

    if &magic == FRAME_MAGIC {
        let mut len_buf = [0u8; 4];
        match timeout(READ_TIMEOUT, stream.read_exact(&mut len_buf)).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err(io::Error::new(io::ErrorKind::TimedOut, "read length timeout")),
        }
        let len = u32::from_be_bytes(len_buf) as usize;
        if len == 0 || len > MAX_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid frame length"));
        }
        let mut buf = vec![0u8; len];
        match timeout(READ_TIMEOUT, stream.read_exact(&mut buf)).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err(io::Error::new(io::ErrorKind::TimedOut, "read payload timeout")),
        }
        let (msg, _): (Msg, usize) = bincode::decode_from_slice(&buf, cfg)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "decode failed"))?;
        Ok(msg)
    } else {
        // 旧协议：把已读的 4 字节当作消息一部分继续读到 EOF
        let mut buf = magic.to_vec();
        let read_res = timeout(READ_TIMEOUT, async {
            let mut tmp = [0u8; 16 * 1024];
            loop {
                let n = stream.read(&mut tmp).await?;
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&tmp[..n]);
                if buf.len() > MAX_BYTES {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "message too large"));
                }
            }
            Ok::<(), io::Error>(())
        })
        .await;

        match read_res {
            Ok(Ok(())) => {
                let (msg, _): (Msg, usize) = bincode::decode_from_slice(&buf, cfg)
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "decode failed"))?;
                Ok(msg)
            }
            Ok(Err(e)) => Err(e),
            Err(_) => Err(io::Error::new(io::ErrorKind::TimedOut, "legacy read timeout")),
        }
    }
}

async fn write_ack(stream: &mut TcpStream, ack: Ack) {
    let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
    let Ok(ack_buf) = bincode::encode_to_vec(ack, cfg) else {
        warn!("encode ack failed");
        return;
    };
    let mut header = [0u8; 8];
    header[..4].copy_from_slice(FRAME_MAGIC);
    header[4..].copy_from_slice(&(ack_buf.len() as u32).to_be_bytes());
    let _ = stream.write_all(&header).await;
    let _ = stream.write_all(&ack_buf).await;
    let _ = stream.flush().await;
    let _ = stream.shutdown().await;
}

struct SimpleLogger;

impl log::Log for SimpleLogger {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            eprintln!("[{}] {}", record.level(), record.args());
        }
    }

    fn flush(&self) {}
}

fn init_logger() {
    let level = env::var("RUST_LOG")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(log::LevelFilter::Info);
    let _ = log::set_logger(&SimpleLogger);
    log::set_max_level(level);
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    init_logger();

    let address = listen_address();
    let listener = TcpListener::bind(&address).await?;
    info!("Listening on {address}");

    let pid_file = pid_path();
    let pid = std::process::id();
    fs::write(&pid_file, pid.to_string())?;

    {
        let pid_file_clone = pid_file.clone();
        tokio::spawn(async move {
            let _ = tokio::signal::ctrl_c().await;
            let _ = fs::remove_file(&pid_file_clone);
            std::process::exit(0);
        });
    }

    let final_addr = final_addr();
    let semaphore = std::sync::Arc::new(Semaphore::new(MAX_CONCURRENT));

    loop {
        let (mut stream, peer) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                warn!("accept error: {e}");
                continue;
            }
        };

        let final_addr = final_addr.clone();
        let permit = semaphore.clone().acquire_owned().await;

        tokio::spawn(async move {
            let _permit = permit;
            let result = timeout(HANDLE_TIMEOUT, async {
                match read_full_msg(&mut stream).await {
                    Ok(msg) => {
                        debug!("msg from {peer:?}: {msg:?}");
                        let ack = handle_msg(msg, &final_addr).await;
                        write_ack(&mut stream, ack).await;
                    }
                    Err(e) => {
                        warn!("read/decode from {peer:?} failed: {e}");
                    }
                }
            })
            .await;
            if result.is_err() {
                warn!("handle timeout for {peer:?}");
            }
        });
    }
}
