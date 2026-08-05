use arboard::Clipboard;
use log::{debug, info, warn};
use simpleclipboard::protocol::{
    Ack, AuthKeys, Challenge, FRAME_HEADER_BYTES, Nonce, PlainRequest, ProtocolError, ServerHello,
    WireAck, WireRequest, decode_request_payload, derive_auth_keys, encode_ack_frame,
    encode_hello_frame, new_server_hello, open_request, parse_header, seal_ack,
};
use std::collections::{HashSet, VecDeque};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::mpsc::{self, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinSet;
use tokio::time::{sleep, timeout};

const READ_TIMEOUT: Duration = Duration::from_secs(3);
const HANDLE_TIMEOUT: Duration = Duration::from_secs(4);
const CLIPBOARD_TIMEOUT: Duration = Duration::from_millis(2500);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_CONCURRENT: usize = 4;
const CLIPBOARD_QUEUE: usize = 16;
const MAX_TOKEN_BYTES: usize = 4096;
const REPLAY_CACHE_ENTRIES: usize = 4096;

const COMMAND_QUEUED: u8 = 0;
const COMMAND_STARTED: u8 = 1;
const COMMAND_FINISHED: u8 = 2;
const COMMAND_CANCELLED: u8 = 3;

#[derive(Clone)]
struct ClipboardWorker {
    sender: SyncSender<ClipboardCommand>,
}

struct ClipboardCommand {
    text: String,
    deadline: Instant,
    phase: Arc<AtomicU8>,
    reply: oneshot::Sender<Result<(), &'static str>>,
}

impl ClipboardWorker {
    fn start() -> io::Result<Self> {
        let mut clipboard = None;
        Self::start_with(move |text| set_clipboard_text(&mut clipboard, text))
    }

    fn start_with<F>(mut operation: F) -> io::Result<Self>
    where
        F: FnMut(String) -> Result<(), &'static str> + Send + 'static,
    {
        let (sender, receiver) = mpsc::sync_channel::<ClipboardCommand>(CLIPBOARD_QUEUE);
        std::thread::Builder::new()
            .name("simpleclipboard-worker".to_owned())
            .spawn(move || {
                while let Ok(command) = receiver.recv() {
                    if Instant::now() >= command.deadline {
                        let _ = command.phase.compare_exchange(
                            COMMAND_QUEUED,
                            COMMAND_CANCELLED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        );
                        let _ = command.reply.send(Err("clipboard_expired"));
                        continue;
                    }
                    if command
                        .phase
                        .compare_exchange(
                            COMMAND_QUEUED,
                            COMMAND_STARTED,
                            Ordering::AcqRel,
                            Ordering::Acquire,
                        )
                        .is_err()
                    {
                        let _ = command.reply.send(Err("clipboard_expired"));
                        continue;
                    }
                    let result = operation(command.text);
                    command.phase.store(COMMAND_FINISHED, Ordering::Release);
                    let _ = command.reply.send(result);
                }
            })?;
        Ok(Self { sender })
    }

    async fn set_text(&self, text: String) -> Result<(), &'static str> {
        self.set_text_with_timeout(text, CLIPBOARD_TIMEOUT).await
    }

    async fn set_text_with_timeout(
        &self,
        text: String,
        operation_timeout: Duration,
    ) -> Result<(), &'static str> {
        let (reply, mut result) = oneshot::channel();
        let phase = Arc::new(AtomicU8::new(COMMAND_QUEUED));
        self.sender
            .try_send(ClipboardCommand {
                text,
                deadline: Instant::now() + operation_timeout,
                phase: phase.clone(),
                reply,
            })
            .map_err(|error| match error {
                TrySendError::Full(_) => "clipboard_busy",
                TrySendError::Disconnected(_) => "clipboard_worker_stopped",
            })?;
        match timeout(operation_timeout, &mut result).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(worker_disconnect_detail(phase.load(Ordering::Acquire))),
            Err(_) => match phase.compare_exchange(
                COMMAND_QUEUED,
                COMMAND_CANCELLED,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => Err("clipboard_expired"),
                Err(COMMAND_FINISHED) => result
                    .try_recv()
                    .unwrap_or(Err("clipboard_outcome_unknown")),
                Err(COMMAND_STARTED) => Err("clipboard_outcome_unknown"),
                Err(_) => Err("clipboard_expired"),
            },
        }
    }
}

fn worker_disconnect_detail(phase: u8) -> &'static str {
    if matches!(phase, COMMAND_STARTED | COMMAND_FINISHED) {
        "clipboard_outcome_unknown"
    } else {
        "clipboard_worker_stopped"
    }
}

fn set_clipboard_text(clipboard: &mut Option<Clipboard>, text: String) -> Result<(), &'static str> {
    if clipboard.is_none() {
        *clipboard = Clipboard::new().ok();
    }
    let Some(active) = clipboard.as_mut() else {
        return Err("clipboard_unavailable");
    };
    if active.set_text(text.clone()).is_ok() {
        return Ok(());
    }

    *clipboard = Clipboard::new().ok();
    let Some(retry) = clipboard.as_mut() else {
        return Err("clipboard_unavailable");
    };
    retry.set_text(text).map_err(|_| "clipboard_set_failed")
}

struct ReplayCache {
    capacity: usize,
    order: VecDeque<Nonce>,
    seen: HashSet<Nonce>,
}

impl ReplayCache {
    fn new(capacity: usize) -> Self {
        Self {
            capacity,
            order: VecDeque::with_capacity(capacity),
            seen: HashSet::with_capacity(capacity),
        }
    }

    fn insert_if_new(&mut self, nonce: Nonce) -> bool {
        if self.seen.contains(&nonce) {
            return false;
        }
        if self.order.len() == self.capacity
            && let Some(expired) = self.order.pop_front()
        {
            self.seen.remove(&expired);
        }
        self.order.push_back(nonce);
        self.seen.insert(nonce);
        true
    }
}

struct AppState {
    auth_keys: Option<AuthKeys>,
    clipboard: ClipboardWorker,
    replay: Mutex<ReplayCache>,
}

fn ack(ok: bool, detail: &'static str) -> Ack {
    Ack {
        ok,
        detail: Some(detail.to_owned()),
    }
}

async fn handle_plain_request(state: &AppState, request: PlainRequest) -> Ack {
    match request {
        PlainRequest::Ping => ack(true, "ping_ok"),
        PlainRequest::Set { text } => {
            debug!("Set request accepted ({} bytes)", text.len());
            match state.clipboard.set_text(text).await {
                Ok(()) => ack(true, "clipboard_set_ok"),
                Err(detail) => {
                    warn!("Clipboard operation failed: {detail}");
                    ack(false, detail)
                }
            }
        }
        PlainRequest::Legacy { text } => {
            debug!("Legacy set request accepted ({} bytes)", text.len());
            match state.clipboard.set_text(text).await {
                Ok(()) => ack(true, "clipboard_set_ok"),
                Err(detail) => {
                    warn!("Clipboard operation failed: {detail}");
                    ack(false, detail)
                }
            }
        }
    }
}

async fn process_request(
    state: &AppState,
    challenge: &Challenge,
    request: WireRequest,
) -> Result<WireAck, ProtocolError> {
    match (state.auth_keys.as_ref(), request) {
        (None, WireRequest::Plain(request)) => {
            Ok(WireAck::Plain(handle_plain_request(state, request).await))
        }
        (Some(_), WireRequest::Plain(_)) => {
            warn!("Plaintext request rejected while authentication is enabled");
            Ok(WireAck::Plain(ack(false, "authentication_required")))
        }
        (None, WireRequest::Authenticated { .. }) => {
            warn!("Authenticated request rejected because no token is configured");
            Ok(WireAck::Plain(ack(false, "authentication_not_configured")))
        }
        (Some(keys), WireRequest::Authenticated { nonce, ciphertext }) => {
            let request = open_request(keys, challenge, &nonce, &ciphertext)?;
            drop(ciphertext);
            let fresh = state
                .replay
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert_if_new(nonce);
            let response = if fresh {
                handle_plain_request(state, request).await
            } else {
                warn!("Authenticated request replay rejected");
                ack(false, "replay_rejected")
            };
            seal_ack(keys, challenge, nonce, &response)
        }
    }
}

async fn read_request(stream: &mut TcpStream) -> io::Result<WireRequest> {
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    timeout(READ_TIMEOUT, stream.read_exact(&mut header))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "frame header timeout"))??;
    let payload_length =
        parse_header(&header).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mut payload = vec![0_u8; payload_length];
    timeout(READ_TIMEOUT, stream.read_exact(&mut payload))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "frame payload timeout"))??;
    decode_request_payload(&payload)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

async fn write_ack(stream: &mut TcpStream, response: &WireAck) -> io::Result<()> {
    let frame = encode_ack_frame(response)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    stream.write_all(&frame).await?;
    stream.flush().await?;
    stream.shutdown().await
}

async fn write_hello(stream: &mut TcpStream, hello: &ServerHello) -> io::Result<()> {
    let frame = encode_hello_frame(hello)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    stream.write_all(&frame).await?;
    stream.flush().await
}

async fn serve_connection(
    mut stream: TcpStream,
    peer: SocketAddr,
    state: std::sync::Arc<AppState>,
) {
    let result = timeout(HANDLE_TIMEOUT, async {
        let hello = new_server_hello().map_err(io::Error::other)?;
        write_hello(&mut stream, &hello).await?;
        let request = read_request(&mut stream).await?;
        match &request {
            WireRequest::Plain(_) => debug!("Plaintext request from {peer}"),
            WireRequest::Authenticated { ciphertext, .. } => {
                debug!(
                    "Authenticated request from {peer} ({} encrypted bytes)",
                    ciphertext.len()
                )
            }
        }
        let response = process_request(&state, &hello.challenge, request)
            .await
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        write_ack(&mut stream, &response).await
    })
    .await;

    match result {
        Ok(Ok(())) => {}
        Ok(Err(error))
            if matches!(
                error.kind(),
                io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset
            ) =>
        {
            debug!("Connection from {peer} closed before a request")
        }
        Ok(Err(error)) => warn!("Connection from {peer} failed: {error}"),
        Err(_) => warn!("Connection from {peer} timed out"),
    }
}

fn listen_address() -> String {
    env::var("SIMPLECLIPBOARD_ADDR").unwrap_or_else(|_| "127.0.0.1:12343".to_owned())
}

fn expected_token() -> io::Result<Option<String>> {
    parse_expected_token(env::var("SIMPLECLIPBOARD_TOKEN"))
}

fn parse_expected_token(value: Result<String, env::VarError>) -> io::Result<Option<String>> {
    match value {
        Ok(token) if token.len() > MAX_TOKEN_BYTES => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("SIMPLECLIPBOARD_TOKEN exceeds {MAX_TOKEN_BYTES} bytes"),
        )),
        Ok(token) if !token.is_empty() => Ok(Some(token)),
        Ok(_) | Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(_)) => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "SIMPLECLIPBOARD_TOKEN is not valid UTF-8",
        )),
    }
}

fn validate_exposure(address: SocketAddr, authentication_enabled: bool) -> io::Result<()> {
    if address.ip().is_loopback() || authentication_enabled {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        "refusing non-loopback TCP listener without SIMPLECLIPBOARD_TOKEN",
    ))
}

fn runtime_pid_path() -> Option<PathBuf> {
    if let Some(path) = env::var_os("SIMPLECLIPBOARD_PID_FILE") {
        if path == "-" {
            return None;
        }
        return Some(PathBuf::from(path));
    }
    if let Some(runtime_dir) = env::var_os("XDG_RUNTIME_DIR").filter(|path| !path.is_empty()) {
        return Some(PathBuf::from(runtime_dir).join("simpleclipboard.pid"));
    }
    #[cfg(unix)]
    let suffix = unsafe { libc::getuid() }.to_string();
    #[cfg(not(unix))]
    let suffix = std::process::id().to_string();
    Some(env::temp_dir().join(format!("simpleclipboard-{suffix}.pid")))
}

struct PidGuard {
    path: PathBuf,
    file: File,
}

impl PidGuard {
    fn acquire(path: &Path) -> io::Result<Self> {
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "PID path is not a regular file",
            ));
        }

        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            use std::os::unix::fs::{MetadataExt, PermissionsExt};

            // SAFETY: getuid and flock have no pointer arguments and the fd is open.
            let current_uid = unsafe { libc::getuid() };
            if metadata.uid() != current_uid {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "PID file is owned by another user",
                ));
            }
            let lock_result =
                unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if lock_result != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "another simpleclipboard daemon owns the PID file",
                ));
            }
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }

        file.set_len(0)?;
        writeln!(file, "{}", std::process::id())?;
        file.flush()?;
        Ok(Self {
            path: path.to_owned(),
            file,
        })
    }

    #[cfg(unix)]
    fn still_owns_path(&self) -> io::Result<bool> {
        use std::os::unix::fs::MetadataExt;

        let held = self.file.metadata()?;
        let current = fs::symlink_metadata(&self.path)?;
        Ok(current.is_file() && held.dev() == current.dev() && held.ino() == current.ino())
    }

    #[cfg(not(unix))]
    fn still_owns_path(&self) -> io::Result<bool> {
        // There is no portable stable file identity API. Leaving a stale file
        // is safer than unlinking a path another process may have replaced.
        Ok(false)
    }
}

impl Drop for PidGuard {
    fn drop(&mut self) {
        match self.still_owns_path() {
            Ok(true) => {
                if let Err(error) = fs::remove_file(&self.path)
                    && error.kind() != io::ErrorKind::NotFound
                {
                    warn!("Failed to remove PID file: {error}");
                }
            }
            Ok(false) => {}
            Err(error) => {
                if error.kind() != io::ErrorKind::NotFound {
                    warn!("Failed to verify PID file identity: {error}");
                }
            }
        }
    }
}

struct SimpleLogger;

impl log::Log for SimpleLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            eprintln!("[{}] {}", record.level(), record.args());
        }
    }

    fn flush(&self) {}
}

fn init_logger() {
    let raw = env::var("RUST_LOG").unwrap_or_else(|_| "info".to_owned());
    let configured = raw
        .split(',')
        .find_map(|part| part.strip_prefix("simpleclipboard="))
        .unwrap_or(&raw);
    let level = configured.parse().unwrap_or(log::LevelFilter::Info);
    let _ = log::set_logger(&SimpleLogger);
    log::set_max_level(level);
}

#[cfg(unix)]
async fn shutdown_signal() -> io::Result<()> {
    use tokio::signal::unix::{SignalKind, signal};

    let mut terminate = signal(SignalKind::terminate())?;
    let mut hangup = signal(SignalKind::hangup())?;
    tokio::select! {
        result = tokio::signal::ctrl_c() => result,
        _ = terminate.recv() => Ok(()),
        _ = hangup.recv() => Ok(()),
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() -> io::Result<()> {
    tokio::signal::ctrl_c().await
}

/// Runs one authenticated request through the protocol, in-process.
///
/// The installer needs to know that the binary it just built actually works,
/// and a version string only proves the file is not corrupt.  Everything a
/// real request touches before it reaches the clipboard — key derivation, AEAD
/// sealing, framing, and the response binding that ties an ack to its request
/// nonce — is exercised here.  The clipboard itself is left alone: it needs a
/// display server, which an installer cannot assume.
fn self_test() -> io::Result<()> {
    let fail = |stage: &str, error: ProtocolError| io::Error::other(format!("{stage}: {error}"));

    let keys = derive_auth_keys("self-test token");
    let hello = new_server_hello().map_err(|error| fail("server hello", error))?;
    let challenge: Challenge = hello.challenge;

    let sent = PlainRequest::Set {
        text: "simpleclipboard self-test 第一行\n".to_owned(),
    };
    let (wire, request_nonce) = simpleclipboard::protocol::seal_request(&keys, &challenge, &sent)
        .map_err(|error| fail("sealing the request", error))?;

    // Through the wire encoding and back, the way the daemon receives it.
    let frame = simpleclipboard::protocol::encode_request_frame(&wire)
        .map_err(|error| fail("encoding the request frame", error))?;
    let payload = &frame[FRAME_HEADER_BYTES..];
    let decoded =
        decode_request_payload(payload).map_err(|error| fail("decoding the request", error))?;
    let WireRequest::Authenticated { nonce, ciphertext } = decoded else {
        return Err(io::Error::other(
            "a sealed request decoded as unauthenticated",
        ));
    };
    let opened = open_request(&keys, &challenge, &nonce, &ciphertext)
        .map_err(|error| fail("opening the request", error))?;
    if opened != sent {
        return Err(io::Error::other(
            "the request did not survive the round trip",
        ));
    }

    // And the ack back, including the binding that stops a replayed response.
    let ack = Ack {
        ok: true,
        detail: None,
    };
    let sealed_ack = seal_ack(&keys, &challenge, request_nonce, &ack)
        .map_err(|error| fail("sealing the ack", error))?;
    let returned =
        simpleclipboard::protocol::open_ack(&keys, &challenge, &request_nonce, &sealed_ack)
            .map_err(|error| fail("opening the ack", error))?;
    if returned != ack {
        return Err(io::Error::other("the ack did not survive the round trip"));
    }
    Ok(())
}

fn print_help() {
    println!(
        "simpleclipboard-daemon {}\n\n\
         Usage: simpleclipboard-daemon [--help | --version | --self-test]\n\n\
         Environment:\n  \
         SIMPLECLIPBOARD_ADDR      listen address (default 127.0.0.1:12343)\n  \
         SIMPLECLIPBOARD_TOKEN     optional pre-shared key; required off loopback\n  \
         SIMPLECLIPBOARD_PID_FILE  PID path, or '-' to disable\n  \
         RUST_LOG                  error, warn, info, debug or trace",
        env!("CARGO_PKG_VERSION")
    );
}

fn handle_cli() -> io::Result<bool> {
    let mut arguments = env::args_os().skip(1);
    let Some(argument) = arguments.next() else {
        return Ok(true);
    };
    if arguments.next().is_some() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "only one command-line option is supported",
        ));
    }
    match argument.to_str() {
        Some("--help" | "-h") => {
            print_help();
            Ok(false)
        }
        Some("--version" | "-V") => {
            println!("simpleclipboard-daemon {}", env!("CARGO_PKG_VERSION"));
            Ok(false)
        }
        Some("--self-test") => {
            self_test()?;
            println!("ok");
            Ok(false)
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unknown option; use --help",
        )),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> io::Result<()> {
    if !handle_cli()? {
        return Ok(());
    }
    init_logger();

    let configured_address = listen_address();
    let token = expected_token()?;
    let listener = TcpListener::bind(&configured_address).await?;
    let local_address = listener.local_addr()?;
    validate_exposure(local_address, token.is_some())?;
    let _pid_guard = runtime_pid_path()
        .as_deref()
        .map(PidGuard::acquire)
        .transpose()?;
    let auth_keys = token.as_deref().map(derive_auth_keys);
    drop(token);
    let state = Arc::new(AppState {
        auth_keys,
        clipboard: ClipboardWorker::start()?,
        replay: Mutex::new(ReplayCache::new(REPLAY_CACHE_ENTRIES)),
    });

    info!("Listening on {local_address}");
    let mut connections = JoinSet::new();
    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);

    loop {
        tokio::select! {
            signal_result = &mut shutdown => {
                signal_result?;
                info!("Shutdown requested");
                break;
            }
            Some(result) = connections.join_next(), if !connections.is_empty() => {
                if let Err(error) = result {
                    warn!("Connection task failed: {error}");
                }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, peer)) if connections.len() < MAX_CONCURRENT => {
                        connections.spawn(serve_connection(stream, peer, state.clone()));
                    }
                    Ok((_stream, peer)) => warn!("Connection limit reached; rejecting {peer}"),
                    Err(error) => {
                        warn!("Accept failed: {error}");
                        sleep(Duration::from_millis(100)).await;
                    }
                }
            }
        }
    }

    drop(listener);
    let drain = async {
        while let Some(result) = connections.join_next().await {
            if let Err(error) = result {
                warn!("Connection task failed during shutdown: {error}");
            }
        }
    };
    if timeout(SHUTDOWN_TIMEOUT, drain).await.is_err() {
        warn!("Timed out draining connections; aborting remaining tasks");
        connections.abort_all();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use simpleclipboard::protocol::{CHALLENGE_BYTES, open_ack, seal_request};
    use std::ffi::OsString;
    use std::net::IpAddr;

    fn test_state(auth_keys: Option<AuthKeys>) -> AppState {
        AppState {
            auth_keys,
            clipboard: ClipboardWorker::start_with(|_| Ok(())).unwrap(),
            replay: Mutex::new(ReplayCache::new(8)),
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn authenticated_request_succeeds_once_and_replay_is_rejected() {
        let keys = derive_auth_keys("secret");
        let state = test_state(Some(keys.clone()));
        let challenge = [3_u8; CHALLENGE_BYTES];
        let (request, nonce) = seal_request(&keys, &challenge, &PlainRequest::Ping).unwrap();

        let first = process_request(&state, &challenge, request.clone())
            .await
            .unwrap();
        let first_ack = open_ack(&keys, &challenge, &nonce, &first).unwrap();
        assert!(first_ack.ok);

        let replay = process_request(&state, &challenge, request).await.unwrap();
        let replay_ack = open_ack(&keys, &challenge, &nonce, &replay).unwrap();
        assert!(!replay_ack.ok);
        assert_eq!(replay_ack.detail.as_deref(), Some("replay_rejected"));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn authentication_mode_rejects_plaintext_requests() {
        let state = test_state(Some(derive_auth_keys("secret")));
        let challenge = [4_u8; CHALLENGE_BYTES];
        let response = process_request(
            &state,
            &challenge,
            WireRequest::Plain(PlainRequest::Set {
                text: "must-not-reach-clipboard".to_owned(),
            }),
        )
        .await
        .unwrap();
        let WireAck::Plain(response) = response else {
            panic!("expected plaintext rejection");
        };
        assert_eq!(response.detail.as_deref(), Some("authentication_required"));
    }

    #[test]
    fn non_loopback_requires_authentication() {
        let loopback = SocketAddr::new(IpAddr::from([127, 0, 0, 1]), 12343);
        let exposed = SocketAddr::new(IpAddr::from([0, 0, 0, 0]), 12343);
        assert!(validate_exposure(loopback, false).is_ok());
        assert!(validate_exposure(exposed, true).is_ok());
        assert_eq!(
            validate_exposure(exposed, false).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_token_is_an_error_instead_of_disabling_authentication() {
        use std::os::unix::ffi::OsStringExt;

        let error = parse_expected_token(Err(env::VarError::NotUnicode(OsString::from_vec(vec![
            0xff,
        ]))))
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn replay_cache_is_bounded() {
        let mut cache = ReplayCache::new(2);
        assert!(cache.insert_if_new([1_u8; simpleclipboard::protocol::NONCE_BYTES]));
        assert!(cache.insert_if_new([2_u8; simpleclipboard::protocol::NONCE_BYTES]));
        assert!(!cache.insert_if_new([1_u8; simpleclipboard::protocol::NONCE_BYTES]));
        assert!(cache.insert_if_new([3_u8; simpleclipboard::protocol::NONCE_BYTES]));
        assert!(cache.insert_if_new([1_u8; simpleclipboard::protocol::NONCE_BYTES]));
        assert_eq!(cache.order.len(), 2);
        assert_eq!(cache.seen.len(), 2);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn queued_expired_clipboard_operation_is_skipped() {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let worker_seen = seen.clone();
        let (started, started_rx) = mpsc::sync_channel(1);
        let (release, release_rx) = mpsc::sync_channel(1);
        let worker = ClipboardWorker::start_with(move |text| {
            worker_seen
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .push(text.clone());
            if text == "first" {
                let _ = started.send(());
                let _ = release_rx.recv();
            }
            Ok(())
        })
        .unwrap();

        let (first_reply, first_result) = oneshot::channel();
        worker
            .sender
            .try_send(ClipboardCommand {
                text: "first".to_owned(),
                deadline: Instant::now() + Duration::from_secs(2),
                phase: Arc::new(AtomicU8::new(COMMAND_QUEUED)),
                reply: first_reply,
            })
            .unwrap();
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let second = worker
            .set_text_with_timeout("expired".to_owned(), Duration::from_millis(30))
            .await;
        assert_eq!(second, Err("clipboard_expired"));
        release.send(()).unwrap();
        assert_eq!(first_result.await.unwrap(), Ok(()));
        worker
            .set_text_with_timeout("barrier".to_owned(), Duration::from_secs(1))
            .await
            .unwrap();

        assert_eq!(
            *seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner()),
            ["first".to_owned(), "barrier".to_owned()]
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn in_progress_clipboard_timeout_is_explicitly_ambiguous() {
        let executed = Arc::new(AtomicU8::new(0));
        let worker_executed = executed.clone();
        let worker = ClipboardWorker::start_with(move |_| {
            worker_executed.store(1, Ordering::Release);
            std::thread::sleep(Duration::from_millis(400));
            Ok(())
        })
        .unwrap();

        let started = Instant::now();
        let result = worker
            .set_text_with_timeout("slow".to_owned(), Duration::from_millis(150))
            .await;
        assert_eq!(result, Err("clipboard_outcome_unknown"));
        assert_eq!(executed.load(Ordering::Acquire), 1);
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn worker_disconnect_after_start_is_ambiguous() {
        assert_eq!(
            worker_disconnect_detail(COMMAND_QUEUED),
            "clipboard_worker_stopped"
        );
        assert_eq!(
            worker_disconnect_detail(COMMAND_STARTED),
            "clipboard_outcome_unknown"
        );
        assert_eq!(
            worker_disconnect_detail(COMMAND_FINISHED),
            "clipboard_outcome_unknown"
        );
    }

    #[cfg(unix)]
    #[test]
    fn pid_file_does_not_follow_symlinks() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let victim = directory.path().join("victim");
        let pid_path = directory.path().join("daemon.pid");
        fs::write(&victim, "do-not-touch").unwrap();
        symlink(&victim, &pid_path).unwrap();

        assert!(PidGuard::acquire(&pid_path).is_err());
        assert_eq!(fs::read_to_string(&victim).unwrap(), "do-not-touch");
    }

    #[cfg(unix)]
    #[test]
    fn pid_guard_cleans_up() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("daemon.pid");
        {
            let _guard = PidGuard::acquire(&path).unwrap();
            assert!(path.is_file());
        }
        assert!(!path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn pid_guard_does_not_unlink_a_replacement_path() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("daemon.pid");
        let moved = directory.path().join("original.pid");
        let guard = PidGuard::acquire(&path).unwrap();
        fs::rename(&path, &moved).unwrap();
        fs::write(&path, "replacement").unwrap();

        drop(guard);

        assert_eq!(fs::read_to_string(&path).unwrap(), "replacement");
        assert!(moved.exists());
    }
}
