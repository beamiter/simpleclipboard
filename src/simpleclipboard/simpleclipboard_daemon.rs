use arboard::Clipboard;
use bincode::{Decode, Encode};
use lazy_static::lazy_static;
use std::convert::Infallible;
use std::env;
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task;
use tokio::time::timeout;
use tower::{Service, ServiceBuilder, ServiceExt};
use tracing::{debug, info, warn};
use tracing_subscriber::EnvFilter;

const MAX_BYTES: usize = 160 * 1024 * 1024;
const READ_TIMEOUT: Duration = Duration::from_secs(30);
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
        Some(exp) => provided.as_ref().map(|s| s == &exp).unwrap_or(false),
    }
}

lazy_static! {
    static ref CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(Clipboard::new().ok());
}

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

// 转发到最终地址时保留“旧协议”以兼容（写完整 bincode，读到 EOF）
async fn forward_legacy_async(addr: &str, text: String) -> io::Result<()> {
    let mut s = tokio::net::TcpStream::connect(addr).await?;
    let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
    let msg = Msg::Legacy { text };
    let mut buf = Vec::new();
    bincode::encode_into_std_write(msg, &mut buf, cfg)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "encode failed"))?;
    tokio::io::AsyncWriteExt::write_all(&mut s, &buf).await?;
    tokio::io::AsyncWriteExt::flush(&mut s).await?;
    Ok(())
}

#[derive(Clone)]
struct Handler {
    final_addr: Option<Arc<String>>,
}

impl Handler {
    fn new() -> Self {
        Self {
            final_addr: final_addr().map(Arc::new),
        }
    }
}

type BoxFut = std::pin::Pin<Box<dyn std::future::Future<Output = Result<Ack, Infallible>> + Send>>;

impl Service<Msg> for Handler {
    type Response = Ack;
    type Error = Infallible;
    type Future = BoxFut;

    fn poll_ready(
        &mut self,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        std::task::Poll::Ready(Ok(()))
    }

    fn call(&mut self, msg: Msg) -> Self::Future {
        let final_addr = self.final_addr.clone();

        Box::pin(async move {
            let ack = match msg {
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
                    } else if let Some(addr) = final_addr {
                        match forward_legacy_async(&addr, text.clone()).await {
                            Ok(()) => Ack { ok: true, detail: Some("forwarded".into()) },
                            Err(e) => {
                                warn!("Relay forward failed: {e}. Fallback to local clipboard");
                                let ok = set_clipboard_text_async(text).await;
                                // 保持原始语义：fallback 成功也 ok=false，让客户端自行决定是否走 OSC52。
                                Ack { ok: false, detail: Some(if ok { "forward_failed_fallback_ok" } else { "forward_failed_fallback_err" }.into()) }
                            }
                        }
                    } else {
                        let ok = set_clipboard_text_async(text).await;
                        if ok {
                            Ack { ok: true, detail: Some("local_set_ok".into()) }
                        } else {
                            Ack { ok: false, detail: Some("local_set_err".into()) }
                        }
                    }
                }
                Msg::Legacy { text } => {
                    if let Some(addr) = final_addr {
                        match forward_legacy_async(&addr, text.clone()).await {
                            Ok(()) => Ack { ok: true, detail: Some("forwarded".into()) },
                            Err(e) => {
                                warn!("Legacy relay forward failed: {e}. Fallback to local clipboard");
                                let ok = set_clipboard_text_async(text).await;
                                Ack { ok: false, detail: Some(if ok { "forward_failed_fallback_ok" } else { "forward_failed_fallback_err" }.into()) }
                            }
                        }
                    } else {
                        let ok = set_clipboard_text_async(text).await;
                        if ok {
                            Ack { ok: true, detail: Some("local_set_ok".into()) }
                        } else {
                            Ack { ok: false, detail: Some("local_set_err".into()) }
                        }
                    }
                }
            };
            Ok(ack)
        })
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
        let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
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
                let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
                let (msg, _): (Msg, usize) = bincode::decode_from_slice(&buf, cfg)
                    .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "decode failed"))?;
                Ok(msg)
            }
            Ok(Err(e)) => Err(e),
            Err(_) => Err(io::Error::new(io::ErrorKind::TimedOut, "legacy read timeout")),
        }
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> io::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

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

    let builder = ServiceBuilder::new()
        .concurrency_limit(1024)
        .rate_limit(200, Duration::from_secs(1))
        .timeout(Duration::from_secs(30));

    let base_handler = Handler::new();

    loop {
        let (mut stream, peer) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                warn!("accept error: {e}");
                continue;
            }
        };

        let handler = base_handler.clone();
        let mut svc = builder.clone().service(handler);

        tokio::spawn(async move {
            match read_full_msg(&mut stream).await {
                Ok(msg) => {
                    debug!("msg: {:?}", msg);
                    if let Err(e) = svc.ready().await {
                        warn!("service not ready: {e}");
                        return;
                    }
                    match svc.call(msg).await {
                        Ok(ack) => {
                            // 编码并写回 ACK（新协议帧）
                            let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
                            match bincode::encode_to_vec(ack, cfg) {
                                Ok(ack_buf) => {
                                    let mut header = [0u8; 8];
                                    header[..4].copy_from_slice(FRAME_MAGIC);
                                    header[4..].copy_from_slice(&(ack_buf.len() as u32).to_be_bytes());
                                    let _ = stream.write_all(&header).await;
                                    let _ = stream.write_all(&ack_buf).await;
                                    let _ = stream.flush().await;
                                    let _ = stream.shutdown().await;
                                }
                                Err(e) => {
                                    warn!("encode ack failed: {e}");
                                }
                            }
                        }
                        Err(_e) => {
                            // Infallible
                        }
                    }
                }
                Err(e) => {
                    warn!("read/decode from {peer:?} failed: {e}");
                }
            }
        });
    }
}
