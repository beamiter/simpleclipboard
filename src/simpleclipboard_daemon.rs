// src/simpleclipboard_daemon.rs

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
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::task;
use tokio::time::timeout;
use tower::{Service, ServiceBuilder, ServiceExt};
use tracing::{debug, info, warn};
use tracing_subscriber::EnvFilter;

const MAX_BYTES: usize = 160 * 1024 * 1024; // 160MB
const READ_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Encode, Decode)]
pub enum Msg {
    Ping { token: Option<String> },
    Set { text: String, token: Option<String> },
    Legacy { text: String },
}

fn pid_path() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("simpleclipboard.pid")
}

fn listen_address() -> String {
    // 更安全的默认：仅本机
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "127.0.0.1:12344".to_string())
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

async fn set_clipboard_text_async(text: String) {
    // arboard 是阻塞 API，放到阻塞线程池
    let _ = task::spawn_blocking(move || {
        let mut lock = CLIPBOARD.lock().unwrap();
        if lock.is_none() {
            *lock = Clipboard::new().ok();
        }
        if let Some(cb) = lock.as_mut() {
            if let Err(_) = cb.set_text(text.clone()) {
                *lock = Clipboard::new().ok();
                if let Some(cb2) = lock.as_mut() {
                    let _ = cb2.set_text(text);
                }
            }
        }
    })
    .await;
}

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

type BoxFut = std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), Infallible>> + Send>>;

impl Service<Msg> for Handler {
    type Response = ();
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
            match msg {
                Msg::Ping { token } => {
                    if token_ok(&token) {
                        // 协议无响应，直接返回
                        info!("Ping accepted");
                    } else {
                        warn!("Ping rejected by token");
                    }
                }
                Msg::Set { text, token } => {
                    if token_ok(&token) {
                        if let Some(addr) = final_addr {
                            if let Err(e) = forward_legacy_async(&addr, text.clone()).await {
                                warn!("Relay forward failed: {e}. Fallback to local clipboard");
                                set_clipboard_text_async(text).await;
                            }
                        } else {
                            set_clipboard_text_async(text).await;
                        }
                    } else {
                        warn!("Set rejected by token");
                    }
                }
                Msg::Legacy { text } => {
                    if let Some(addr) = final_addr {
                        if let Err(e) = forward_legacy_async(&addr, text.clone()).await {
                            warn!("Legacy relay forward failed: {e}. Fallback to local clipboard");
                            set_clipboard_text_async(text).await;
                        }
                    } else {
                        set_clipboard_text_async(text).await;
                    }
                }
            }
            Ok(())
        })
    }
}

async fn read_full_msg(mut stream: TcpStream) -> io::Result<Msg> {
    // 读到 EOF（客户端写完会关），并设置超时和大小限制
    let mut buf = Vec::new();
    let read_res = timeout(READ_TIMEOUT, async {
        let mut tmp = [0u8; 16 * 1024];
        loop {
            let n = stream.read(&mut tmp).await?;
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
            if buf.len() > MAX_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "message too large",
                ));
            }
        }
        Ok::<(), io::Error>(())
    })
    .await;

    match read_res {
        Ok(Ok(())) => {
            let cfg = bincode::config::standard().with_limit::<MAX_BYTES>();
            let (msg, _consumed): (Msg, usize) = bincode::decode_from_slice(&buf, cfg)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "decode failed"))?;
            Ok(msg)
        }
        Ok(Err(e)) => Err(e),
        Err(_) => Err(io::Error::new(io::ErrorKind::TimedOut, "read timeout")),
    }
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> io::Result<()> {
    // 日志初始化：可用 RUST_LOG=info/simpleclipboard=debug 控制
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    let address = listen_address();
    let listener = TcpListener::bind(&address).await?;
    info!("Listening on {address}");

    // 写 pidfile
    let pid_file = pid_path();
    let pid = std::process::id();
    fs::write(&pid_file, pid.to_string())?;

    // Ctrl+C 清理
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
        .timeout(Duration::from_secs(5));
    // .load_shed() // 需要时开启过载丢弃

    let base_handler = Handler::new();

    loop {
        let (stream, peer) = match listener.accept().await {
            Ok(s) => s,
            Err(e) => {
                warn!("accept error: {e}");
                continue;
            }
        };

        let handler = base_handler.clone();
        let mut svc = builder.clone().service(handler);

        tokio::spawn(async move {
            match read_full_msg(stream).await {
                Ok(msg) => {
                    debug!("msg: {:?}", msg);
                    if let Err(e) = svc.ready().await {
                        warn!("service not ready: {e}");
                        return;
                    }
                    if let Err(_e) = svc.call(msg).await {
                        // Error=Infallible，这里理论上不会到达
                    }
                }
                Err(e) => {
                    warn!("read/decode from {peer:?} failed: {e}");
                }
            }
        });
    }
}
