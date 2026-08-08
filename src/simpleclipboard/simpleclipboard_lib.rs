pub mod protocol;

use libc::c_char;
use protocol::{
    Ack, AuthKeys, FRAME_HEADER_BYTES, MAX_ACK_BYTES, PlainRequest, ServerHello, WireAck,
    WireRequest, ack_limit, decode_ack_payload, decode_hello_payload, derive_auth_keys,
    encode_request_frame, open_ack, parse_header, seal_request, validate_ack_length,
};
use std::ffi::CStr;
use std::fmt;
use std::io::{Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::LazyLock;
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::time::{Duration, Instant};

const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
const IO_TIMEOUT: Duration = Duration::from_millis(1200);
const FIELD_SEPARATOR: char = '\u{1}';
const ABI_V2: &str = "SCB2";
const RESOLVER_QUEUE: usize = 8;
const AMBIGUOUS_CLIPBOARD_DETAIL: &str = "clipboard_outcome_unknown";

type Resolution = std::io::Result<Vec<SocketAddr>>;

struct ResolveJob {
    address: String,
    reply: SyncSender<Resolution>,
}

static RESOLVER: LazyLock<Option<SyncSender<ResolveJob>>> = LazyLock::new(|| {
    let (sender, receiver) = mpsc::sync_channel::<ResolveJob>(RESOLVER_QUEUE);
    std::thread::Builder::new()
        .name("simpleclipboard-resolver".to_owned())
        .spawn(move || {
            while let Ok(job) = receiver.recv() {
                let result = job
                    .address
                    .to_socket_addrs()
                    .map(|addresses| addresses.collect::<Vec<_>>());
                let _ = job.reply.send(result);
            }
        })
        .ok()
        .map(|_| sender)
});

/// One request plus the keys derived from the caller's token, if any.
pub struct ClientRequest {
    request: PlainRequest,
    keys: Option<AuthKeys>,
}

impl ClientRequest {
    pub fn new(request: PlainRequest, token: &str) -> Self {
        Self {
            request,
            keys: (!token.is_empty()).then(|| derive_auth_keys(token)),
        }
    }

    fn mutates_clipboard(&self) -> bool {
        matches!(
            &self.request,
            PlainRequest::Set { .. } | PlainRequest::Legacy { .. }
        )
    }
}

#[derive(Debug)]
pub enum ClientError {
    InvalidPayload,
    Io(std::io::Error),
    Protocol(protocol::ProtocolError),
    OutcomeUnknown,
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidPayload => f.write_str("invalid client payload"),
            Self::Io(error) => write!(f, "I/O failed: {error}"),
            Self::Protocol(error) => write!(f, "protocol failed: {error}"),
            Self::OutcomeUnknown => f.write_str("clipboard request outcome is unknown"),
        }
    }
}

impl From<std::io::Error> for ClientError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<protocol::ProtocolError> for ClientError {
    fn from(value: protocol::ProtocolError) -> Self {
        Self::Protocol(value)
    }
}

fn resolver_error(kind: std::io::ErrorKind, detail: &'static str) -> ClientError {
    ClientError::Io(std::io::Error::new(kind, detail))
}

fn await_resolution(
    receiver: &Receiver<Resolution>,
    deadline: Instant,
) -> Result<Vec<SocketAddr>, ClientError> {
    match receiver.recv_timeout(deadline_remaining(deadline)?) {
        Ok(Ok(addresses)) if !addresses.is_empty() => Ok(addresses),
        Ok(Ok(_)) => Err(ClientError::InvalidPayload),
        Ok(Err(error)) => Err(ClientError::Io(error)),
        Err(mpsc::RecvTimeoutError::Timeout) => Err(resolver_error(
            std::io::ErrorKind::TimedOut,
            "address resolution deadline exceeded",
        )),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(resolver_error(
            std::io::ErrorKind::BrokenPipe,
            "address resolver stopped",
        )),
    }
}

fn resolve_with_deadline(address: &str, deadline: Instant) -> Result<Vec<SocketAddr>, ClientError> {
    if let Ok(address) = address.parse::<SocketAddr>() {
        return Ok(vec![address]);
    }

    let Some(resolver) = RESOLVER.as_ref() else {
        return Err(resolver_error(
            std::io::ErrorKind::Other,
            "address resolver could not start",
        ));
    };
    let (reply, result) = mpsc::sync_channel(1);
    resolver
        .try_send(ResolveJob {
            address: address.to_owned(),
            reply,
        })
        .map_err(|error| match error {
            TrySendError::Full(_) => resolver_error(
                std::io::ErrorKind::WouldBlock,
                "address resolver queue is full",
            ),
            TrySendError::Disconnected(_) => {
                resolver_error(std::io::ErrorKind::BrokenPipe, "address resolver stopped")
            }
        })?;
    await_resolution(&result, deadline)
}

fn connect_with_timeout(address: &str) -> Result<TcpStream, ClientError> {
    let deadline = Instant::now() + CONNECT_TIMEOUT;
    let addresses = resolve_with_deadline(address, deadline)?;

    let mut last_error = None;
    for socket_address in addresses {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match TcpStream::connect_timeout(&socket_address, remaining) {
            Ok(stream) => {
                stream.set_nodelay(true)?;
                stream.set_write_timeout(Some(IO_TIMEOUT))?;
                stream.set_read_timeout(Some(IO_TIMEOUT))?;
                return Ok(stream);
            }
            Err(error) => last_error = Some(error),
        }
    }

    Err(ClientError::Io(last_error.unwrap_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::TimedOut, "connection deadline exceeded")
    })))
}

/// Sends one request and returns the daemon's answer.
///
/// Shared verbatim by the in-process `libcall` entry points and by the
/// `simpleclipboard-client` binary the plugin drives with `job_start()`, so the
/// two can never drift on framing, sealing or response binding.
pub fn send_request(address: &str, request: &ClientRequest) -> Result<Ack, ClientError> {
    if address.is_empty() {
        return Err(ClientError::InvalidPayload);
    }

    let mut stream = connect_with_timeout(address)?;
    let deadline = Instant::now() + IO_TIMEOUT;
    let hello = read_hello_from_stream(&mut stream, deadline)?;
    let (wire_request, request_nonce) = match request.keys.as_ref() {
        Some(keys) => {
            let (wire, nonce) = seal_request(keys, &hello.challenge, &request.request)?;
            (wire, Some(nonce))
        }
        None => (WireRequest::Plain(request.request.clone()), None),
    };
    let frame = encode_request_frame(&wire_request)?;
    write_all_until(&mut stream, &frame, deadline)?;
    after_frame_sent(request, || {
        stream.set_write_timeout(Some(deadline_remaining(deadline)?))?;
        stream.flush()?;
        stream.shutdown(Shutdown::Write)?;

        let limit = ack_limit(&request.request);
        let response = read_ack_from_stream(&mut stream, deadline, limit)?;
        match (request.keys.as_ref(), request_nonce, response) {
            (None, None, WireAck::Plain(ack)) => Ok(ack),
            (Some(keys), Some(nonce), response) => {
                Ok(open_ack(keys, &hello.challenge, &nonce, &response, limit)?)
            }
            _ => Err(protocol::ProtocolError::UnexpectedProtection.into()),
        }
    })
}

fn after_frame_sent<T>(
    request: &ClientRequest,
    operation: impl FnOnce() -> Result<T, ClientError>,
) -> Result<T, ClientError> {
    match operation() {
        Err(_) if request.mutates_clipboard() => Err(ClientError::OutcomeUnknown),
        result => result,
    }
}

#[cfg(test)]
fn read_ack(reader: &mut impl Read) -> Result<WireAck, ClientError> {
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    reader.read_exact(&mut header)?;
    let payload_length = parse_header(&header)?;
    validate_ack_length(payload_length, MAX_ACK_BYTES)?;
    let mut payload = vec![0_u8; payload_length];
    reader.read_exact(&mut payload)?;
    Ok(decode_ack_payload(&payload, MAX_ACK_BYTES)?)
}

fn read_ack_from_stream(
    stream: &mut TcpStream,
    deadline: Instant,
    limit: usize,
) -> Result<WireAck, ClientError> {
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    read_exact_until(stream, &mut header, deadline)?;
    let payload_length = parse_header(&header)?;
    // Bounded by what the request that was actually sent may be answered with,
    // so a ping cannot make this allocate a Get-sized buffer.
    validate_ack_length(payload_length, limit)?;
    let mut payload = vec![0_u8; payload_length];
    read_exact_until(stream, &mut payload, deadline)?;
    Ok(decode_ack_payload(&payload, limit)?)
}

fn read_hello_from_stream(
    stream: &mut TcpStream,
    deadline: Instant,
) -> Result<ServerHello, ClientError> {
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    read_exact_until(stream, &mut header, deadline)?;
    let payload_length = parse_header(&header)?;
    validate_ack_length(payload_length, MAX_ACK_BYTES)?;
    let mut payload = vec![0_u8; payload_length];
    read_exact_until(stream, &mut payload, deadline)?;
    Ok(decode_hello_payload(&payload)?)
}

fn deadline_remaining(deadline: Instant) -> std::io::Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "request deadline exceeded",
        ))
    } else {
        Ok(remaining)
    }
}

fn write_all_until(
    stream: &mut TcpStream,
    mut bytes: &[u8],
    deadline: Instant,
) -> std::io::Result<()> {
    while !bytes.is_empty() {
        stream.set_write_timeout(Some(deadline_remaining(deadline)?))?;
        match stream.write(bytes) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WriteZero,
                    "failed to write request frame",
                ));
            }
            Ok(written) => bytes = &bytes[written..],
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn read_exact_until(
    stream: &mut TcpStream,
    mut bytes: &mut [u8],
    deadline: Instant,
) -> std::io::Result<()> {
    while !bytes.is_empty() {
        stream.set_read_timeout(Some(deadline_remaining(deadline)?))?;
        match stream.read(bytes) {
            Ok(0) => {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "response frame was truncated",
                ));
            }
            Ok(read) => bytes = &mut bytes[read..],
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn parse_v2_payload(payload: &str) -> Result<(&str, ClientRequest), ClientError> {
    let mut fields = payload.splitn(5, FIELD_SEPARATOR);
    if fields.next() != Some(ABI_V2) {
        return Err(ClientError::InvalidPayload);
    }
    let address = fields.next().ok_or(ClientError::InvalidPayload)?;
    let action = fields.next().ok_or(ClientError::InvalidPayload)?;
    let token = fields.next().ok_or(ClientError::InvalidPayload)?;
    let text = fields.next().ok_or(ClientError::InvalidPayload)?;
    if address.is_empty() || token.contains(FIELD_SEPARATOR) {
        return Err(ClientError::InvalidPayload);
    }
    let request = match action {
        "ping" if text.is_empty() => PlainRequest::Ping,
        "set" => PlainRequest::Set {
            text: text.to_owned(),
        },
        _ => return Err(ClientError::InvalidPayload),
    };
    Ok((address, ClientRequest::new(request, token)))
}

fn parse_legacy_payload(payload: &str) -> Result<(&str, ClientRequest), ClientError> {
    let (address, remainder) = payload
        .split_once(FIELD_SEPARATOR)
        .ok_or(ClientError::InvalidPayload)?;
    if address.is_empty() {
        return Err(ClientError::InvalidPayload);
    }

    for action in ["ping", "set"] {
        let prefix = format!("{action}{FIELD_SEPARATOR}");
        if let Some(arguments) = remainder.strip_prefix(&prefix) {
            let (text, token) = arguments
                .rsplit_once(FIELD_SEPARATOR)
                .unwrap_or((arguments, ""));
            let request = match action {
                "ping" if text.is_empty() => PlainRequest::Ping,
                "set" => PlainRequest::Set {
                    text: text.to_owned(),
                },
                _ => return Err(ClientError::InvalidPayload),
            };
            return Ok((address, ClientRequest::new(request, token)));
        }
    }

    Ok((
        address,
        ClientRequest::new(
            PlainRequest::Legacy {
                text: remainder.to_owned(),
            },
            "",
        ),
    ))
}

/// 1 success, 2 outcome unknown, 0 definitive failure.
///
/// The same three values the FFI returns and the client binary exits with, so
/// the Vim side reads one vocabulary whichever transport it used.
pub fn ack_result(ack: &Ack) -> i32 {
    if ack.ok {
        1
    } else if ack.detail.as_deref() == Some(AMBIGUOUS_CLIPBOARD_DETAIL) {
        // The worker already started an operation that cannot be cancelled.  A
        // fallback now could race and be overwritten by that late operation.
        2
    } else {
        0
    }
}

unsafe fn call_from_c(
    payload: *const c_char,
    parser: for<'a> fn(&'a str) -> Result<(&'a str, ClientRequest), ClientError>,
) -> i32 {
    if payload.is_null() {
        return 0;
    }

    catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: The exported C ABI requires a valid, NUL-terminated string.
        let payload = unsafe { CStr::from_ptr(payload) };
        let payload = match payload.to_str() {
            Ok(value) => value,
            Err(_) => return 0,
        };
        let (address, request) = match parser(payload) {
            Ok(value) => value,
            Err(_) => return 0,
        };
        match send_request(address, &request) {
            Ok(ack) => ack_result(&ack),
            Err(ClientError::OutcomeUnknown) => 2,
            Err(_) => 0,
        }
    }))
    .unwrap_or(0)
}

/// Sends an SCB2 ABI payload (`SCB2\x01address\x01action\x01token\x01text`).
///
/// The text field is last, so embedded U+0001 characters are preserved. Returns
/// 1 for success, 2 when a clipboard operation is already in progress but its
/// result is unknown, and 0 for a definitive failure.
///
/// # Safety
///
/// `payload` must point to a valid NUL-terminated C string for the duration of
/// this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_set_clipboard_tcp_v2(payload: *const c_char) -> i32 {
    // SAFETY: The caller upholds the exported ABI contract.
    unsafe { call_from_c(payload, parse_v2_payload) }
}

/// Compatibility entry point for the v0.1 Vim client payload.
///
/// Returns the same 0/1/2 status values as [`rust_set_clipboard_tcp_v2`].
///
/// # Safety
///
/// `payload` must point to a valid NUL-terminated C string for the duration of
/// this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_set_clipboard_tcp(payload: *const c_char) -> i32 {
    // SAFETY: The caller upholds the exported ABI contract.
    unsafe { call_from_c(payload, parse_legacy_payload) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::encode_ack_frame;
    use std::io::Cursor;
    use std::ptr;

    #[test]
    fn v2_payload_keeps_field_separator_in_text() {
        let payload = "SCB2\u{1}127.0.0.1:1\u{1}set\u{1}token\u{1}a\u{1}b";
        let (address, request) = parse_v2_payload(payload).unwrap();
        assert_eq!(address, "127.0.0.1:1");
        assert_eq!(
            request.request,
            PlainRequest::Set {
                text: "a\u{1}b".to_owned(),
            }
        );
        assert!(request.keys.is_some());
    }

    #[test]
    fn legacy_payload_uses_the_last_separator_for_token() {
        let payload = "127.0.0.1:1\u{1}set\u{1}a\u{1}b\u{1}token";
        let (_, request) = parse_legacy_payload(payload).unwrap();
        assert_eq!(
            request.request,
            PlainRequest::Set {
                text: "a\u{1}b".to_owned(),
            }
        );
        assert!(request.keys.is_some());
    }

    #[test]
    fn null_ffi_pointer_is_rejected() {
        // SAFETY: A null pointer is explicitly supported and rejected.
        assert_eq!(unsafe { rust_set_clipboard_tcp_v2(ptr::null()) }, 0);
    }

    #[test]
    fn client_requires_a_complete_valid_ack() {
        let mut ack = encode_ack_frame(&WireAck::Plain(Ack::status(
            true,
            Some("ping_ok".to_owned()),
        )))
        .unwrap();
        ack.pop();
        let result = read_ack(&mut Cursor::new(ack));
        assert!(matches!(result, Err(ClientError::Io(_))));

        let mut oversized_header = Vec::from(protocol::FRAME_MAGIC);
        oversized_header.extend_from_slice(&((protocol::MAX_ACK_BYTES + 1) as u32).to_be_bytes());
        let oversized = read_ack(&mut Cursor::new(oversized_header));
        assert!(matches!(oversized, Err(ClientError::Protocol(_))));
    }

    #[test]
    fn rejected_ack_is_not_reported_as_success() {
        let encoded = encode_ack_frame(&WireAck::Plain(Ack::status(
            false,
            Some("request_rejected".to_owned()),
        )))
        .unwrap();
        let WireAck::Plain(ack) = read_ack(&mut Cursor::new(encoded)).unwrap() else {
            panic!("expected plaintext ack");
        };
        assert_eq!(ack_result(&ack), 0);
    }

    #[test]
    fn ambiguous_clipboard_result_suppresses_immediate_fallback() {
        let ack = Ack::status(false, Some(AMBIGUOUS_CLIPBOARD_DETAIL.to_owned()));
        assert_eq!(ack_result(&ack), 2);
    }

    #[test]
    fn transport_failure_after_full_set_frame_is_ambiguous_but_ping_is_not() {
        let set = ClientRequest::new(
            PlainRequest::Set {
                text: "already sent".to_owned(),
            },
            "secret",
        );
        let set_result: Result<(), ClientError> = after_frame_sent(&set, || {
            Err(ClientError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "ack lost",
            )))
        });
        assert!(matches!(set_result, Err(ClientError::OutcomeUnknown)));

        let ping = ClientRequest::new(PlainRequest::Ping, "secret");
        let ping_result: Result<(), ClientError> = after_frame_sent(&ping, || {
            Err(ClientError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "ack lost",
            )))
        });
        assert!(matches!(ping_result, Err(ClientError::Io(_))));
    }

    #[test]
    fn resolution_wait_obeys_its_deadline() {
        let (_sender, receiver) = mpsc::sync_channel::<Resolution>(1);
        let started = Instant::now();
        let result = await_resolution(&receiver, started + Duration::from_millis(20));
        assert!(
            matches!(result, Err(ClientError::Io(ref error)) if error.kind() == std::io::ErrorKind::TimedOut)
        );
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
