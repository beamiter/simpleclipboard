use aes_gcm::{
    Aes256Gcm, Nonce as AesNonce,
    aead::{Aead, KeyInit, Payload},
};
use sha2::{Digest, Sha256};
use std::fmt;

pub const FRAME_MAGIC: [u8; 4] = *b"SCB1";
pub const FRAME_HEADER_BYTES: usize = 8;
pub const MAX_FRAME_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_ACK_BYTES: usize = 4096;
// A status ack carries a fixed vocabulary of short details, so 4 KiB is a
// generous bound and a useful one: it is how much a client is willing to read
// back from something claiming to be the daemon.  A Get reply carries the
// clipboard itself, which is request-sized rather than ack-sized, so it needs
// its own bound.  The two are kept separate rather than merged so that a ping
// or a set still cannot be answered with ten megabytes.
pub const MAX_DATA_ACK_BYTES: usize = MAX_FRAME_BYTES;
pub const NONCE_BYTES: usize = 12;
pub const CHALLENGE_BYTES: usize = 32;

pub type Nonce = [u8; NONCE_BYTES];
pub type Challenge = [u8; CHALLENGE_BYTES];

const KEY_BYTES: usize = 32;
const LENGTH_BYTES: usize = 4;
const AEAD_TAG_BYTES: usize = 16;

const TAG_PING: u8 = 0x01;
const TAG_SET: u8 = 0x02;
const TAG_LEGACY: u8 = 0x03;
const TAG_GET: u8 = 0x04;
const TAG_SERVER_HELLO: u8 = 0x10;
const TAG_REQUEST_PLAIN: u8 = 0x20;
const TAG_REQUEST_AUTHENTICATED: u8 = 0x21;
const TAG_ACK_PLAIN: u8 = 0x30;
const TAG_ACK_AUTHENTICATED: u8 = 0x31;
const TAG_ACK_BODY: u8 = 0x01;
const TAG_ACK_DATA_BODY: u8 = 0x02;
const TAG_NONE: u8 = 0x00;
const TAG_SOME: u8 = 0x01;

const SELECTION_CLIPBOARD: u8 = 0x00;
const SELECTION_PRIMARY: u8 = 0x01;

const PLAIN_REQUEST_PREFIX_BYTES: usize = 1;
const STRING_PREFIX_BYTES: usize = LENGTH_BYTES;
const WIRE_PLAIN_PREFIX_BYTES: usize = 1;
const WIRE_REQUEST_AUTH_OVERHEAD: usize = 1 + NONCE_BYTES + LENGTH_BYTES;
const ACK_BODY_MIN_BYTES: usize = 3;
const ACK_BODY_WITH_DETAIL_OVERHEAD: usize = 3 + LENGTH_BYTES;
const ACK_BODY_WITH_TEXT_OVERHEAD: usize = ACK_BODY_WITH_DETAIL_OVERHEAD + LENGTH_BYTES;
const WIRE_ACK_AUTH_OVERHEAD: usize = 1 + NONCE_BYTES + NONCE_BYTES + LENGTH_BYTES;
const MIN_REQUEST_CIPHERTEXT_BYTES: usize = AEAD_TAG_BYTES + PLAIN_REQUEST_PREFIX_BYTES;
const MIN_ACK_CIPHERTEXT_BYTES: usize = AEAD_TAG_BYTES + ACK_BODY_MIN_BYTES;

const REQUEST_KEY_DOMAIN: &[u8] = b"simpleclipboard/scb1/aes256gcm/request-key/v1\0";
const ACK_KEY_DOMAIN: &[u8] = b"simpleclipboard/scb1/aes256gcm/ack-key/v1\0";
const REQUEST_AAD: &[u8] = b"simpleclipboard/scb1/aes256gcm/request/v1";
const ACK_AAD: &[u8] = b"simpleclipboard/scb1/aes256gcm/ack/v1";

#[derive(Clone)]
pub struct AuthKeys {
    request: [u8; KEY_BYTES],
    ack: [u8; KEY_BYTES],
}

impl Drop for AuthKeys {
    fn drop(&mut self) {
        self.request.fill(0);
        self.ack.fill(0);
    }
}

/// Which of the platform's selections a request addresses.
///
/// X11 and Wayland expose two independent buffers: CLIPBOARD, filled by an
/// explicit copy, and PRIMARY, filled by merely selecting text and pasted with
/// the middle mouse button.  They are genuinely different destinations, so the
/// selection travels with the request instead of being a daemon-wide mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Selection {
    #[default]
    Clipboard,
    Primary,
}

impl Selection {
    fn tag(self) -> u8 {
        match self {
            Self::Clipboard => SELECTION_CLIPBOARD,
            Self::Primary => SELECTION_PRIMARY,
        }
    }

    fn from_tag(tag: u8) -> Result<Self, ProtocolError> {
        match tag {
            SELECTION_CLIPBOARD => Ok(Self::Clipboard),
            SELECTION_PRIMARY => Ok(Self::Primary),
            tag => Err(ProtocolError::UnknownTag(tag)),
        }
    }

    /// The name used on the command line and in the plugin's messages.
    pub fn name(self) -> &'static str {
        match self {
            Self::Clipboard => "clipboard",
            Self::Primary => "primary",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "clipboard" => Some(Self::Clipboard),
            "primary" => Some(Self::Primary),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlainRequest {
    Ping,
    Set { text: String },
    Legacy { text: String },
    Get { selection: Selection },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireRequest {
    Plain(PlainRequest),
    Authenticated { nonce: Nonce, ciphertext: Vec<u8> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerHello {
    pub challenge: Challenge,
}

/// The daemon's answer to one request.
///
/// `text` is `Some` only for a Get reply, and it is what splits an ack into two
/// wire shapes: a status body that is always tiny, and a data body that carries
/// a clipboard.  Keeping them one type keeps the sealing, framing and response
/// binding identical for both — only the length bound differs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ack {
    pub ok: bool,
    pub detail: Option<String>,
    pub text: Option<String>,
}

impl Ack {
    pub fn status(ok: bool, detail: Option<String>) -> Self {
        Self {
            ok,
            detail,
            text: None,
        }
    }

    pub fn data(text: String, detail: Option<String>) -> Self {
        Self {
            ok: true,
            detail,
            text: Some(text),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireAck {
    Plain(Ack),
    Authenticated {
        request_nonce: Nonce,
        nonce: Nonce,
        ciphertext: Vec<u8>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtocolError {
    InvalidMagic,
    InvalidLength(usize),
    UnexpectedEof,
    TrailingBytes,
    UnknownTag(u8),
    InvalidBoolean(u8),
    InvalidUtf8,
    AuthenticationFailed,
    Random(String),
    UnexpectedProtection,
    ResponseBinding,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidMagic => f.write_str("invalid frame magic"),
            Self::InvalidLength(length) => write!(f, "invalid frame length: {length}"),
            Self::UnexpectedEof => f.write_str("payload is truncated"),
            Self::TrailingBytes => f.write_str("trailing bytes in payload"),
            Self::UnknownTag(tag) => write!(f, "unknown protocol tag: 0x{tag:02x}"),
            Self::InvalidBoolean(value) => write!(f, "invalid boolean value: {value}"),
            Self::InvalidUtf8 => f.write_str("string is not valid UTF-8"),
            Self::AuthenticationFailed => f.write_str("authenticated message rejected"),
            Self::Random(detail) => write!(f, "secure random generation failed: {detail}"),
            Self::UnexpectedProtection => f.write_str("unexpected message protection mode"),
            Self::ResponseBinding => f.write_str("response is not bound to this request"),
        }
    }
}

impl std::error::Error for ProtocolError {}

struct Decoder<'a> {
    payload: &'a [u8],
    position: usize,
}

impl<'a> Decoder<'a> {
    fn new(payload: &'a [u8]) -> Self {
        Self {
            payload,
            position: 0,
        }
    }

    fn read_u8(&mut self) -> Result<u8, ProtocolError> {
        let value = self
            .payload
            .get(self.position)
            .copied()
            .ok_or(ProtocolError::UnexpectedEof)?;
        self.position += 1;
        Ok(value)
    }

    fn read_u32(&mut self) -> Result<u32, ProtocolError> {
        let bytes = self.read_array::<LENGTH_BYTES>()?;
        Ok(u32::from_be_bytes(bytes))
    }

    fn read_array<const N: usize>(&mut self) -> Result<[u8; N], ProtocolError> {
        let bytes = self.read_bytes(N)?;
        let mut output = [0_u8; N];
        output.copy_from_slice(bytes);
        Ok(output)
    }

    fn read_bytes(&mut self, length: usize) -> Result<&'a [u8], ProtocolError> {
        let end = self
            .position
            .checked_add(length)
            .ok_or(ProtocolError::InvalidLength(length))?;
        let bytes = self
            .payload
            .get(self.position..end)
            .ok_or(ProtocolError::UnexpectedEof)?;
        self.position = end;
        Ok(bytes)
    }

    fn read_length_prefixed(
        &mut self,
        minimum: usize,
        maximum: usize,
    ) -> Result<&'a [u8], ProtocolError> {
        let length = self.read_u32()? as usize;
        if length < minimum || length > maximum {
            return Err(ProtocolError::InvalidLength(length));
        }
        self.read_bytes(length)
    }

    fn remaining(&self) -> &'a [u8] {
        &self.payload[self.position..]
    }

    fn finish(self) -> Result<(), ProtocolError> {
        if self.position == self.payload.len() {
            Ok(())
        } else {
            Err(ProtocolError::TrailingBytes)
        }
    }
}

pub fn derive_auth_keys(token: &str) -> AuthKeys {
    AuthKeys {
        request: derive_key(REQUEST_KEY_DOMAIN, token),
        ack: derive_key(ACK_KEY_DOMAIN, token),
    }
}

fn derive_key(domain: &[u8], token: &str) -> [u8; KEY_BYTES] {
    let mut digest = Sha256::new();
    digest.update(domain);
    digest.update((token.len() as u64).to_be_bytes());
    digest.update(token.as_bytes());
    digest.finalize().into()
}

fn random_nonce() -> Result<Nonce, ProtocolError> {
    let mut nonce = [0_u8; NONCE_BYTES];
    getrandom::fill(&mut nonce).map_err(|error| ProtocolError::Random(error.to_string()))?;
    Ok(nonce)
}

pub fn new_server_hello() -> Result<ServerHello, ProtocolError> {
    let mut challenge = [0_u8; CHALLENGE_BYTES];
    getrandom::fill(&mut challenge).map_err(|error| ProtocolError::Random(error.to_string()))?;
    Ok(ServerHello { challenge })
}

fn cipher(key: &[u8; KEY_BYTES]) -> Result<Aes256Gcm, ProtocolError> {
    Aes256Gcm::new_from_slice(key).map_err(|_| ProtocolError::AuthenticationFailed)
}

fn checked_size(parts: &[usize], maximum: usize) -> Result<usize, ProtocolError> {
    let mut total = 0_usize;
    for part in parts {
        total = total
            .checked_add(*part)
            .ok_or(ProtocolError::InvalidLength(usize::MAX))?;
    }
    if total == 0 || total > maximum {
        Err(ProtocolError::InvalidLength(total))
    } else {
        Ok(total)
    }
}

fn append_length(output: &mut Vec<u8>, length: usize) -> Result<(), ProtocolError> {
    let length = u32::try_from(length).map_err(|_| ProtocolError::InvalidLength(length))?;
    output.extend_from_slice(&length.to_be_bytes());
    Ok(())
}

fn append_length_prefixed(output: &mut Vec<u8>, bytes: &[u8]) -> Result<(), ProtocolError> {
    append_length(output, bytes.len())?;
    output.extend_from_slice(bytes);
    Ok(())
}

fn encode_plain_request(request: &PlainRequest) -> Result<Vec<u8>, ProtocolError> {
    match request {
        PlainRequest::Ping => Ok(vec![TAG_PING]),
        PlainRequest::Get { selection } => Ok(vec![TAG_GET, selection.tag()]),
        PlainRequest::Set { text } | PlainRequest::Legacy { text } => {
            let length = checked_size(
                &[PLAIN_REQUEST_PREFIX_BYTES, STRING_PREFIX_BYTES, text.len()],
                MAX_FRAME_BYTES - WIRE_PLAIN_PREFIX_BYTES,
            )?;
            let mut output = Vec::with_capacity(length);
            output.push(if matches!(request, PlainRequest::Set { .. }) {
                TAG_SET
            } else {
                TAG_LEGACY
            });
            append_length_prefixed(&mut output, text.as_bytes())?;
            Ok(output)
        }
    }
}

fn decode_plain_request(payload: &[u8]) -> Result<PlainRequest, ProtocolError> {
    checked_size(&[payload.len()], MAX_FRAME_BYTES - WIRE_PLAIN_PREFIX_BYTES)?;
    let mut decoder = Decoder::new(payload);
    let tag = decoder.read_u8()?;
    let request = match tag {
        TAG_PING => PlainRequest::Ping,
        TAG_GET => PlainRequest::Get {
            selection: Selection::from_tag(decoder.read_u8()?)?,
        },
        TAG_SET | TAG_LEGACY => {
            let maximum = MAX_FRAME_BYTES
                - WIRE_PLAIN_PREFIX_BYTES
                - PLAIN_REQUEST_PREFIX_BYTES
                - STRING_PREFIX_BYTES;
            let bytes = decoder.read_length_prefixed(0, maximum)?;
            let text = std::str::from_utf8(bytes)
                .map_err(|_| ProtocolError::InvalidUtf8)?
                .to_owned();
            if tag == TAG_SET {
                PlainRequest::Set { text }
            } else {
                PlainRequest::Legacy { text }
            }
        }
        _ => return Err(ProtocolError::UnknownTag(tag)),
    };
    decoder.finish()?;
    Ok(request)
}

// How big this particular ack is allowed to get: a data body carries the
// clipboard, everything else is a fixed-vocabulary status line.
fn ack_body_limit(ack: &Ack) -> usize {
    if ack.text.is_some() {
        MAX_DATA_ACK_BYTES
    } else {
        MAX_ACK_BYTES
    }
}

fn wire_ack_limit(ack: &WireAck) -> usize {
    match ack {
        WireAck::Plain(ack) => ack_body_limit(ack),
        // The body is opaque once sealed, so the frame bound is the wider one;
        // the plaintext was already bounded by its own kind before sealing.
        WireAck::Authenticated { .. } => MAX_DATA_ACK_BYTES,
    }
}

fn encode_ack_body(ack: &Ack) -> Result<Vec<u8>, ProtocolError> {
    let maximum = ack_body_limit(ack) - WIRE_PLAIN_PREFIX_BYTES;
    let detail_bytes = ack.detail.as_deref().map(str::as_bytes);
    let text_bytes = ack.text.as_deref().map(str::as_bytes);
    let mut parts = vec![ACK_BODY_MIN_BYTES];
    if let Some(detail) = detail_bytes {
        // The detail keeps the status bound even in a data ack, matching what
        // the decoder is willing to read back.
        checked_size(
            &[ACK_BODY_WITH_DETAIL_OVERHEAD, detail.len()],
            MAX_ACK_BYTES - WIRE_PLAIN_PREFIX_BYTES,
        )?;
        parts.push(LENGTH_BYTES);
        parts.push(detail.len());
    }
    if let Some(text) = text_bytes {
        parts.push(LENGTH_BYTES);
        parts.push(text.len());
    }
    let length = checked_size(&parts, maximum)?;
    let mut output = Vec::with_capacity(length);
    output.push(if text_bytes.is_some() {
        TAG_ACK_DATA_BODY
    } else {
        TAG_ACK_BODY
    });
    output.push(u8::from(ack.ok));
    match detail_bytes {
        None => output.push(TAG_NONE),
        Some(detail) => {
            output.push(TAG_SOME);
            append_length_prefixed(&mut output, detail)?;
        }
    }
    if let Some(text) = text_bytes {
        append_length_prefixed(&mut output, text)?;
    }
    Ok(output)
}

fn decode_ack_body(payload: &[u8]) -> Result<Ack, ProtocolError> {
    // The body tag decides the bound before a single length is trusted, so a
    // status ack still cannot claim more than MAX_ACK_BYTES.
    let body_tag = *payload.first().ok_or(ProtocolError::UnexpectedEof)?;
    let maximum = match body_tag {
        TAG_ACK_BODY => MAX_ACK_BYTES,
        TAG_ACK_DATA_BODY => MAX_DATA_ACK_BYTES,
        tag => return Err(ProtocolError::UnknownTag(tag)),
    } - WIRE_PLAIN_PREFIX_BYTES;
    checked_size(&[payload.len()], maximum)?;
    let mut decoder = Decoder::new(payload);
    decoder.read_u8()?;
    let ok = match decoder.read_u8()? {
        0 => false,
        1 => true,
        value => return Err(ProtocolError::InvalidBoolean(value)),
    };
    let detail = match decoder.read_u8()? {
        TAG_NONE => None,
        TAG_SOME => {
            // A detail is a short status word whichever body carries it, so it
            // keeps the tight bound even inside a data ack.
            let bytes = decoder.read_length_prefixed(
                0,
                MAX_ACK_BYTES - WIRE_PLAIN_PREFIX_BYTES - ACK_BODY_WITH_DETAIL_OVERHEAD,
            )?;
            Some(
                std::str::from_utf8(bytes)
                    .map_err(|_| ProtocolError::InvalidUtf8)?
                    .to_owned(),
            )
        }
        tag => return Err(ProtocolError::UnknownTag(tag)),
    };
    let text = if body_tag == TAG_ACK_DATA_BODY {
        let bytes = decoder.read_length_prefixed(0, maximum - ACK_BODY_WITH_TEXT_OVERHEAD)?;
        Some(
            std::str::from_utf8(bytes)
                .map_err(|_| ProtocolError::InvalidUtf8)?
                .to_owned(),
        )
    } else {
        None
    };
    decoder.finish()?;
    Ok(Ack { ok, detail, text })
}

fn encode_wire_request(request: &WireRequest) -> Result<Vec<u8>, ProtocolError> {
    match request {
        WireRequest::Plain(request) => {
            let body = encode_plain_request(request)?;
            let length = checked_size(&[WIRE_PLAIN_PREFIX_BYTES, body.len()], MAX_FRAME_BYTES)?;
            let mut output = Vec::with_capacity(length);
            output.push(TAG_REQUEST_PLAIN);
            output.extend_from_slice(&body);
            Ok(output)
        }
        WireRequest::Authenticated { nonce, ciphertext } => {
            let length = checked_size(
                &[WIRE_REQUEST_AUTH_OVERHEAD, ciphertext.len()],
                MAX_FRAME_BYTES,
            )?;
            if ciphertext.len() < MIN_REQUEST_CIPHERTEXT_BYTES {
                return Err(ProtocolError::InvalidLength(ciphertext.len()));
            }
            let mut output = Vec::with_capacity(length);
            output.push(TAG_REQUEST_AUTHENTICATED);
            output.extend_from_slice(nonce);
            append_length_prefixed(&mut output, ciphertext)?;
            Ok(output)
        }
    }
}

fn decode_wire_request(payload: &[u8]) -> Result<WireRequest, ProtocolError> {
    validate_length(payload.len())?;
    let mut decoder = Decoder::new(payload);
    match decoder.read_u8()? {
        TAG_REQUEST_PLAIN => decode_plain_request(decoder.remaining()).map(WireRequest::Plain),
        TAG_REQUEST_AUTHENTICATED => {
            let nonce = decoder.read_array::<NONCE_BYTES>()?;
            let maximum = MAX_FRAME_BYTES - WIRE_REQUEST_AUTH_OVERHEAD;
            let ciphertext = decoder
                .read_length_prefixed(MIN_REQUEST_CIPHERTEXT_BYTES, maximum)?
                .to_vec();
            decoder.finish()?;
            Ok(WireRequest::Authenticated { nonce, ciphertext })
        }
        tag => Err(ProtocolError::UnknownTag(tag)),
    }
}

fn encode_server_hello(hello: &ServerHello) -> Vec<u8> {
    let mut output = Vec::with_capacity(1 + CHALLENGE_BYTES);
    output.push(TAG_SERVER_HELLO);
    output.extend_from_slice(&hello.challenge);
    output
}

fn decode_server_hello(payload: &[u8]) -> Result<ServerHello, ProtocolError> {
    validate_ack_length(payload.len(), MAX_ACK_BYTES)?;
    let mut decoder = Decoder::new(payload);
    let tag = decoder.read_u8()?;
    if tag != TAG_SERVER_HELLO {
        return Err(ProtocolError::UnknownTag(tag));
    }
    let challenge = decoder.read_array::<CHALLENGE_BYTES>()?;
    decoder.finish()?;
    Ok(ServerHello { challenge })
}

fn encode_wire_ack(ack: &WireAck) -> Result<Vec<u8>, ProtocolError> {
    let maximum = wire_ack_limit(ack);
    match ack {
        WireAck::Plain(ack) => {
            let body = encode_ack_body(ack)?;
            let length = checked_size(&[WIRE_PLAIN_PREFIX_BYTES, body.len()], maximum)?;
            let mut output = Vec::with_capacity(length);
            output.push(TAG_ACK_PLAIN);
            output.extend_from_slice(&body);
            Ok(output)
        }
        WireAck::Authenticated {
            request_nonce,
            nonce,
            ciphertext,
        } => {
            let length = checked_size(&[WIRE_ACK_AUTH_OVERHEAD, ciphertext.len()], maximum)?;
            if ciphertext.len() < MIN_ACK_CIPHERTEXT_BYTES {
                return Err(ProtocolError::InvalidLength(ciphertext.len()));
            }
            let mut output = Vec::with_capacity(length);
            output.push(TAG_ACK_AUTHENTICATED);
            output.extend_from_slice(request_nonce);
            output.extend_from_slice(nonce);
            append_length_prefixed(&mut output, ciphertext)?;
            Ok(output)
        }
    }
}

fn decode_wire_ack(payload: &[u8], limit: usize) -> Result<WireAck, ProtocolError> {
    validate_ack_length(payload.len(), limit)?;
    let mut decoder = Decoder::new(payload);
    match decoder.read_u8()? {
        TAG_ACK_PLAIN => decode_ack_body(decoder.remaining()).map(WireAck::Plain),
        TAG_ACK_AUTHENTICATED => {
            let request_nonce = decoder.read_array::<NONCE_BYTES>()?;
            let nonce = decoder.read_array::<NONCE_BYTES>()?;
            let maximum = limit - WIRE_ACK_AUTH_OVERHEAD;
            let ciphertext = decoder
                .read_length_prefixed(MIN_ACK_CIPHERTEXT_BYTES, maximum)?
                .to_vec();
            decoder.finish()?;
            Ok(WireAck::Authenticated {
                request_nonce,
                nonce,
                ciphertext,
            })
        }
        tag => Err(ProtocolError::UnknownTag(tag)),
    }
}

fn encrypt(
    key: &[u8; KEY_BYTES],
    nonce: &Nonce,
    plaintext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, ProtocolError> {
    cipher(key)?
        .encrypt(
            &AesNonce::from(*nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| ProtocolError::AuthenticationFailed)
}

fn decrypt(
    key: &[u8; KEY_BYTES],
    nonce: &Nonce,
    ciphertext: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, ProtocolError> {
    cipher(key)?
        .decrypt(
            &AesNonce::from(*nonce),
            Payload {
                msg: ciphertext,
                aad,
            },
        )
        .map_err(|_| ProtocolError::AuthenticationFailed)
}

fn request_aad(challenge: &Challenge) -> Vec<u8> {
    let mut aad = Vec::with_capacity(REQUEST_AAD.len() + challenge.len());
    aad.extend_from_slice(REQUEST_AAD);
    aad.extend_from_slice(challenge);
    aad
}

fn ack_aad(challenge: &Challenge, request_nonce: &Nonce) -> Vec<u8> {
    let mut aad = Vec::with_capacity(ACK_AAD.len() + challenge.len() + request_nonce.len());
    aad.extend_from_slice(ACK_AAD);
    aad.extend_from_slice(challenge);
    aad.extend_from_slice(request_nonce);
    aad
}

pub fn seal_request(
    keys: &AuthKeys,
    challenge: &Challenge,
    request: &PlainRequest,
) -> Result<(WireRequest, Nonce), ProtocolError> {
    seal_request_with_nonce(keys, challenge, request, random_nonce()?)
}

fn seal_request_with_nonce(
    keys: &AuthKeys,
    challenge: &Challenge,
    request: &PlainRequest,
    nonce: Nonce,
) -> Result<(WireRequest, Nonce), ProtocolError> {
    let plaintext = encode_plain_request(request)?;
    checked_size(
        &[WIRE_REQUEST_AUTH_OVERHEAD, plaintext.len(), AEAD_TAG_BYTES],
        MAX_FRAME_BYTES,
    )?;
    let aad = request_aad(challenge);
    let ciphertext = encrypt(&keys.request, &nonce, &plaintext, &aad)?;
    Ok((WireRequest::Authenticated { nonce, ciphertext }, nonce))
}

pub fn open_request(
    keys: &AuthKeys,
    challenge: &Challenge,
    nonce: &Nonce,
    ciphertext: &[u8],
) -> Result<PlainRequest, ProtocolError> {
    if ciphertext.len() < MIN_REQUEST_CIPHERTEXT_BYTES
        || ciphertext.len() > MAX_FRAME_BYTES - WIRE_REQUEST_AUTH_OVERHEAD
    {
        return Err(ProtocolError::InvalidLength(ciphertext.len()));
    }
    let aad = request_aad(challenge);
    let plaintext = decrypt(&keys.request, nonce, ciphertext, &aad)?;
    decode_plain_request(&plaintext)
}

pub fn seal_ack(
    keys: &AuthKeys,
    challenge: &Challenge,
    request_nonce: Nonce,
    ack: &Ack,
) -> Result<WireAck, ProtocolError> {
    seal_ack_with_nonce(keys, challenge, request_nonce, ack, random_nonce()?)
}

fn seal_ack_with_nonce(
    keys: &AuthKeys,
    challenge: &Challenge,
    request_nonce: Nonce,
    ack: &Ack,
    nonce: Nonce,
) -> Result<WireAck, ProtocolError> {
    let plaintext = encode_ack_body(ack)?;
    checked_size(
        &[WIRE_ACK_AUTH_OVERHEAD, plaintext.len(), AEAD_TAG_BYTES],
        ack_body_limit(ack),
    )?;
    let aad = ack_aad(challenge, &request_nonce);
    let ciphertext = encrypt(&keys.ack, &nonce, &plaintext, &aad)?;
    Ok(WireAck::Authenticated {
        request_nonce,
        nonce,
        ciphertext,
    })
}

/// Opens an authenticated ack, refusing anything larger than `limit`.
///
/// The caller knows which request it sent and therefore how large a legitimate
/// answer can be; passing that bound in is what stops a ping from being
/// answered with a ten-megabyte allocation.
pub fn open_ack(
    keys: &AuthKeys,
    challenge: &Challenge,
    expected_request_nonce: &Nonce,
    response: &WireAck,
    limit: usize,
) -> Result<Ack, ProtocolError> {
    let WireAck::Authenticated {
        request_nonce,
        nonce,
        ciphertext,
    } = response
    else {
        return Err(ProtocolError::UnexpectedProtection);
    };
    if request_nonce != expected_request_nonce {
        return Err(ProtocolError::ResponseBinding);
    }
    if ciphertext.len() < MIN_ACK_CIPHERTEXT_BYTES
        || ciphertext.len() > limit - WIRE_ACK_AUTH_OVERHEAD
    {
        return Err(ProtocolError::InvalidLength(ciphertext.len()));
    }
    let aad = ack_aad(challenge, request_nonce);
    let plaintext = decrypt(&keys.ack, nonce, ciphertext, &aad)?;
    decode_ack_body(&plaintext)
}

fn frame(payload: Vec<u8>) -> Result<Vec<u8>, ProtocolError> {
    validate_length(payload.len())?;
    let mut output = Vec::with_capacity(FRAME_HEADER_BYTES + payload.len());
    output.extend_from_slice(&FRAME_MAGIC);
    append_length(&mut output, payload.len())?;
    output.extend_from_slice(&payload);
    Ok(output)
}

pub fn encode_request_frame(request: &WireRequest) -> Result<Vec<u8>, ProtocolError> {
    frame(encode_wire_request(request)?)
}

pub fn encode_hello_frame(hello: &ServerHello) -> Result<Vec<u8>, ProtocolError> {
    let payload = encode_server_hello(hello);
    validate_ack_length(payload.len(), MAX_ACK_BYTES)?;
    frame(payload)
}

pub fn encode_ack_frame(ack: &WireAck) -> Result<Vec<u8>, ProtocolError> {
    let payload = encode_wire_ack(ack)?;
    validate_ack_length(payload.len(), wire_ack_limit(ack))?;
    frame(payload)
}

pub fn decode_request_payload(payload: &[u8]) -> Result<WireRequest, ProtocolError> {
    decode_wire_request(payload)
}

pub fn decode_hello_payload(payload: &[u8]) -> Result<ServerHello, ProtocolError> {
    decode_server_hello(payload)
}

pub fn decode_ack_payload(payload: &[u8], limit: usize) -> Result<WireAck, ProtocolError> {
    decode_wire_ack(payload, limit)
}

/// The largest ack the given request may legitimately be answered with.
pub fn ack_limit(request: &PlainRequest) -> usize {
    match request {
        PlainRequest::Get { .. } => MAX_DATA_ACK_BYTES,
        _ => MAX_ACK_BYTES,
    }
}

pub fn validate_ack_length(length: usize, limit: usize) -> Result<(), ProtocolError> {
    if length == 0 || length > limit {
        Err(ProtocolError::InvalidLength(length))
    } else {
        Ok(())
    }
}

pub fn parse_header(header: &[u8; FRAME_HEADER_BYTES]) -> Result<usize, ProtocolError> {
    if header[..FRAME_MAGIC.len()] != FRAME_MAGIC {
        return Err(ProtocolError::InvalidMagic);
    }
    let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;
    validate_length(length)?;
    Ok(length)
}

pub fn validate_length(length: usize) -> Result<(), ProtocolError> {
    if length == 0 || length > MAX_FRAME_BYTES {
        Err(ProtocolError::InvalidLength(length))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split_frame(frame: &[u8]) -> (&[u8; FRAME_HEADER_BYTES], &[u8]) {
        let (header, payload) = frame.split_at(FRAME_HEADER_BYTES);
        (header.try_into().unwrap(), payload)
    }

    #[test]
    fn plaintext_request_round_trip_preserves_unicode_and_delimiters() {
        let request = WireRequest::Plain(PlainRequest::Set {
            text: "第一行\ncontrol:\u{1}:✅".to_owned(),
        });
        let encoded = encode_request_frame(&request).unwrap();
        let (header, payload) = split_frame(&encoded);

        assert_eq!(parse_header(header).unwrap(), payload.len());
        assert_eq!(decode_request_payload(payload).unwrap(), request);
        assert_eq!(payload[0], TAG_REQUEST_PLAIN);
        assert_eq!(payload[1], TAG_SET);
    }

    #[test]
    fn every_request_variant_round_trips() {
        for request in [
            PlainRequest::Ping,
            PlainRequest::Set {
                text: String::new(),
            },
            PlainRequest::Legacy {
                text: "legacy".to_owned(),
            },
            PlainRequest::Get {
                selection: Selection::Clipboard,
            },
            PlainRequest::Get {
                selection: Selection::Primary,
            },
        ] {
            let wire = WireRequest::Plain(request);
            let frame = encode_request_frame(&wire).unwrap();
            let (_, payload) = split_frame(&frame);
            assert_eq!(decode_request_payload(payload).unwrap(), wire);
        }
    }

    #[test]
    fn authenticated_request_hides_secrets_and_rejects_wrong_key_or_tampering() {
        let token = "token-that-must-never-be-on-the-wire";
        let text = "clipboard text that must be encrypted";
        let keys = derive_auth_keys(token);
        let request = PlainRequest::Set {
            text: text.to_owned(),
        };
        let challenge = [5_u8; CHALLENGE_BYTES];
        let fixed_nonce = [7_u8; NONCE_BYTES];
        let (wire, binding) =
            seal_request_with_nonce(&keys, &challenge, &request, fixed_nonce).unwrap();
        let frame = encode_request_frame(&wire).unwrap();
        let (_, payload) = split_frame(&frame);
        assert_eq!(decode_request_payload(payload).unwrap(), wire);

        assert!(
            !frame
                .windows(token.len())
                .any(|window| window == token.as_bytes())
        );
        assert!(
            !frame
                .windows(text.len())
                .any(|window| window == text.as_bytes())
        );

        let WireRequest::Authenticated {
            nonce,
            mut ciphertext,
        } = wire
        else {
            panic!("expected authenticated request");
        };
        assert_eq!(binding, nonce);
        assert_eq!(
            open_request(&keys, &challenge, &nonce, &ciphertext).unwrap(),
            request
        );

        let wrong_keys = derive_auth_keys("wrong token");
        assert_eq!(
            open_request(&wrong_keys, &challenge, &nonce, &ciphertext),
            Err(ProtocolError::AuthenticationFailed)
        );
        assert_eq!(
            open_request(&keys, &[6_u8; CHALLENGE_BYTES], &nonce, &ciphertext),
            Err(ProtocolError::AuthenticationFailed)
        );
        ciphertext[0] ^= 0x80;
        assert_eq!(
            open_request(&keys, &challenge, &nonce, &ciphertext),
            Err(ProtocolError::AuthenticationFailed)
        );
    }

    #[test]
    fn authenticated_ack_is_tamper_proof_and_bound_to_request() {
        let keys = derive_auth_keys("secret");
        let challenge = [2_u8; CHALLENGE_BYTES];
        let request_nonce = [3_u8; NONCE_BYTES];
        let ack = Ack::status(true, Some("clipboard_set_ok".to_owned()));
        let mut response =
            seal_ack_with_nonce(&keys, &challenge, request_nonce, &ack, [9_u8; NONCE_BYTES])
                .unwrap();
        let encoded = encode_ack_frame(&response).unwrap();
        let (_, payload) = split_frame(&encoded);
        assert_eq!(
            decode_ack_payload(payload, MAX_ACK_BYTES).unwrap(),
            response
        );
        assert_eq!(
            open_ack(&keys, &challenge, &request_nonce, &response, MAX_ACK_BYTES).unwrap(),
            ack
        );
        assert_eq!(
            open_ack(
                &keys,
                &challenge,
                &[4_u8; NONCE_BYTES],
                &response,
                MAX_ACK_BYTES
            ),
            Err(ProtocolError::ResponseBinding)
        );
        assert_eq!(
            open_ack(
                &keys,
                &[8_u8; CHALLENGE_BYTES],
                &request_nonce,
                &response,
                MAX_ACK_BYTES
            ),
            Err(ProtocolError::AuthenticationFailed)
        );

        let WireAck::Authenticated { ciphertext, .. } = &mut response else {
            panic!("expected authenticated ack");
        };
        ciphertext[0] ^= 1;
        assert_eq!(
            open_ack(&keys, &challenge, &request_nonce, &response, MAX_ACK_BYTES),
            Err(ProtocolError::AuthenticationFailed)
        );
    }

    #[test]
    fn server_hello_round_trip_is_bounded_and_tagged() {
        let hello = ServerHello {
            challenge: [11_u8; CHALLENGE_BYTES],
        };
        let encoded = encode_hello_frame(&hello).unwrap();
        let (header, payload) = split_frame(&encoded);
        assert_eq!(parse_header(header).unwrap(), payload.len());
        assert_eq!(decode_hello_payload(payload).unwrap(), hello);
        assert_eq!(payload[0], TAG_SERVER_HELLO);
        assert_eq!(payload.len(), 1 + CHALLENGE_BYTES);
        assert!(payload.len() <= MAX_ACK_BYTES);
    }

    #[test]
    fn ack_round_trip_is_strict() {
        for ack in [
            Ack::status(true, None),
            Ack::status(false, Some("request_rejected".to_owned())),
            Ack::data(String::new(), None),
            Ack::data(
                "pasted\n第二行".to_owned(),
                Some("clipboard_get_ok".to_owned()),
            ),
        ] {
            let limit = ack_body_limit(&ack);
            let wire = WireAck::Plain(ack);
            let encoded = encode_ack_frame(&wire).unwrap();
            let (header, payload) = split_frame(&encoded);

            assert_eq!(parse_header(header).unwrap(), payload.len());
            assert_eq!(decode_ack_payload(payload, limit).unwrap(), wire);

            let mut trailing = payload.to_vec();
            trailing.push(0);
            assert_eq!(
                decode_ack_payload(&trailing, limit),
                Err(ProtocolError::TrailingBytes)
            );
        }
    }

    #[test]
    fn handwritten_wire_layout_is_stable() {
        let ping = encode_request_frame(&WireRequest::Plain(PlainRequest::Ping)).unwrap();
        let (_, ping_payload) = split_frame(&ping);
        assert_eq!(ping_payload, [TAG_REQUEST_PLAIN, TAG_PING]);

        let set = encode_request_frame(&WireRequest::Plain(PlainRequest::Set {
            text: "A".to_owned(),
        }))
        .unwrap();
        let (_, set_payload) = split_frame(&set);
        assert_eq!(set_payload, [TAG_REQUEST_PLAIN, TAG_SET, 0, 0, 0, 1, b'A']);

        let ack =
            encode_ack_frame(&WireAck::Plain(Ack::status(false, Some("x".to_owned())))).unwrap();
        let (_, ack_payload) = split_frame(&ack);
        assert_eq!(
            ack_payload,
            [TAG_ACK_PLAIN, TAG_ACK_BODY, 0, TAG_SOME, 0, 0, 0, 1, b'x']
        );

        // Get is two bytes on the wire and the selection is one of them, so a
        // paste cannot silently address the wrong selection.
        for (selection, tag) in [
            (Selection::Clipboard, SELECTION_CLIPBOARD),
            (Selection::Primary, SELECTION_PRIMARY),
        ] {
            let get =
                encode_request_frame(&WireRequest::Plain(PlainRequest::Get { selection })).unwrap();
            let (_, get_payload) = split_frame(&get);
            assert_eq!(get_payload, [TAG_REQUEST_PLAIN, TAG_GET, tag]);
        }

        // A data ack appends the clipboard after the status fields, so a
        // decoder that stopped at the detail would see trailing bytes.
        let data = encode_ack_frame(&WireAck::Plain(Ack::data("hi".to_owned(), None))).unwrap();
        let (_, data_payload) = split_frame(&data);
        assert_eq!(
            data_payload,
            [
                TAG_ACK_PLAIN,
                TAG_ACK_DATA_BODY,
                1,
                TAG_NONE,
                0,
                0,
                0,
                2,
                b'h',
                b'i'
            ]
        );
    }

    #[test]
    fn unknown_tags_and_noncanonical_values_are_rejected() {
        assert_eq!(
            decode_request_payload(&[0xff]),
            Err(ProtocolError::UnknownTag(0xff))
        );
        assert_eq!(
            decode_request_payload(&[TAG_REQUEST_PLAIN, 0xfe]),
            Err(ProtocolError::UnknownTag(0xfe))
        );
        assert_eq!(
            decode_hello_payload(&[0xfd]),
            Err(ProtocolError::UnknownTag(0xfd))
        );
        assert_eq!(
            decode_ack_payload(&[0xfc], MAX_ACK_BYTES),
            Err(ProtocolError::UnknownTag(0xfc))
        );
        assert_eq!(
            decode_ack_payload(&[TAG_ACK_PLAIN, TAG_ACK_BODY, 2, TAG_NONE], MAX_ACK_BYTES),
            Err(ProtocolError::InvalidBoolean(2))
        );
        assert_eq!(
            decode_ack_payload(&[TAG_ACK_PLAIN, TAG_ACK_BODY, 1, 2], MAX_ACK_BYTES),
            Err(ProtocolError::UnknownTag(2))
        );
        assert_eq!(
            decode_request_payload(&[TAG_REQUEST_PLAIN, TAG_PING, 0]),
            Err(ProtocolError::TrailingBytes)
        );
    }

    #[test]
    fn truncated_payloads_and_declared_lengths_are_rejected() {
        let request = WireRequest::Authenticated {
            nonce: [1_u8; NONCE_BYTES],
            ciphertext: vec![2_u8; MIN_REQUEST_CIPHERTEXT_BYTES],
        };
        let encoded = encode_request_frame(&request).unwrap();
        let (_, payload) = split_frame(&encoded);
        for length in 1..payload.len() {
            assert!(decode_request_payload(&payload[..length]).is_err());
        }

        let mut bad_length = vec![TAG_REQUEST_AUTHENTICATED];
        bad_length.extend_from_slice(&[0_u8; NONCE_BYTES]);
        bad_length.extend_from_slice(&(MIN_REQUEST_CIPHERTEXT_BYTES as u32).to_be_bytes());
        bad_length.extend_from_slice(&[0_u8; 1]);
        assert_eq!(
            decode_request_payload(&bad_length),
            Err(ProtocolError::UnexpectedEof)
        );

        let truncated_hello = vec![TAG_SERVER_HELLO; CHALLENGE_BYTES];
        assert_eq!(
            decode_hello_payload(&truncated_hello),
            Err(ProtocolError::UnexpectedEof)
        );

        let ack = encode_ack_frame(&WireAck::Plain(Ack::status(
            false,
            Some("detail".to_owned()),
        )))
        .unwrap();
        let (_, ack_payload) = split_frame(&ack);
        for length in 1..ack_payload.len() {
            assert!(decode_ack_payload(&ack_payload[..length], MAX_ACK_BYTES).is_err());
        }
    }

    #[test]
    fn invalid_utf8_and_oversized_fields_are_rejected_before_allocation() {
        let invalid_utf8 = [TAG_REQUEST_PLAIN, TAG_SET, 0, 0, 0, 1, 0xff];
        assert_eq!(
            decode_request_payload(&invalid_utf8),
            Err(ProtocolError::InvalidUtf8)
        );
        let invalid_ack_utf8 = [TAG_ACK_PLAIN, TAG_ACK_BODY, 1, TAG_SOME, 0, 0, 0, 1, 0xff];
        assert_eq!(
            decode_ack_payload(&invalid_ack_utf8, MAX_ACK_BYTES),
            Err(ProtocolError::InvalidUtf8)
        );

        let oversized_declared = [TAG_REQUEST_PLAIN, TAG_SET, 0xff, 0xff, 0xff, 0xff];
        assert_eq!(
            decode_request_payload(&oversized_declared),
            Err(ProtocolError::InvalidLength(u32::MAX as usize))
        );

        let oversized = WireRequest::Plain(PlainRequest::Set {
            text: "x".repeat(MAX_FRAME_BYTES),
        });
        assert!(matches!(
            encode_request_frame(&oversized),
            Err(ProtocolError::InvalidLength(_))
        ));
    }

    // A Get reply carries a clipboard, so it needs a frame-sized bound; a ping
    // or a set must not gain one, because that bound is how much a client is
    // willing to allocate for something claiming to be the daemon.
    #[test]
    fn only_a_data_ack_may_exceed_the_status_ack_bound() {
        let big = "x".repeat(MAX_ACK_BYTES * 2);
        let data = WireAck::Plain(Ack::data(big.clone(), None));
        let frame = encode_ack_frame(&data).unwrap();
        let (_, payload) = split_frame(&frame);
        assert!(payload.len() > MAX_ACK_BYTES);
        assert_eq!(
            decode_ack_payload(payload, MAX_DATA_ACK_BYTES).unwrap(),
            data
        );
        // The same bytes, offered to a client that only asked for a status ack.
        assert_eq!(
            decode_ack_payload(payload, MAX_ACK_BYTES),
            Err(ProtocolError::InvalidLength(payload.len()))
        );

        assert_eq!(ack_limit(&PlainRequest::Ping), MAX_ACK_BYTES);
        assert_eq!(
            ack_limit(&PlainRequest::Set {
                text: String::new()
            }),
            MAX_ACK_BYTES
        );
        assert_eq!(
            ack_limit(&PlainRequest::Get {
                selection: Selection::Primary
            }),
            MAX_DATA_ACK_BYTES
        );

        // A status ack cannot be inflated past its own bound, however much the
        // reader would have been willing to accept.
        let oversized_status = WireAck::Plain(Ack::status(true, Some(big)));
        assert!(matches!(
            encode_ack_frame(&oversized_status),
            Err(ProtocolError::InvalidLength(_))
        ));
    }

    #[test]
    fn a_sealed_data_ack_round_trips_but_not_into_a_status_sized_reader() {
        let keys = derive_auth_keys("secret");
        let challenge = [12_u8; CHALLENGE_BYTES];
        let request_nonce = [13_u8; NONCE_BYTES];
        let ack = Ack::data("第一行\n".repeat(1000), Some("clipboard_get_ok".to_owned()));
        let sealed = seal_ack(&keys, &challenge, request_nonce, &ack).unwrap();
        let frame = encode_ack_frame(&sealed).unwrap();
        let (_, payload) = split_frame(&frame);
        assert!(payload.len() > MAX_ACK_BYTES);
        let decoded = decode_ack_payload(payload, MAX_DATA_ACK_BYTES).unwrap();
        assert_eq!(
            open_ack(
                &keys,
                &challenge,
                &request_nonce,
                &decoded,
                MAX_DATA_ACK_BYTES
            )
            .unwrap(),
            ack
        );
        let WireAck::Authenticated { ciphertext, .. } = &decoded else {
            panic!("expected an authenticated ack");
        };
        assert_eq!(
            open_ack(&keys, &challenge, &request_nonce, &decoded, MAX_ACK_BYTES),
            Err(ProtocolError::InvalidLength(ciphertext.len()))
        );
    }

    #[test]
    fn invalid_headers_are_rejected() {
        let mut empty = [0_u8; FRAME_HEADER_BYTES];
        empty[..4].copy_from_slice(&FRAME_MAGIC);
        assert_eq!(parse_header(&empty), Err(ProtocolError::InvalidLength(0)));

        let mut oversized = [0_u8; FRAME_HEADER_BYTES];
        oversized[..4].copy_from_slice(&FRAME_MAGIC);
        oversized[4..].copy_from_slice(&((MAX_FRAME_BYTES + 1) as u32).to_be_bytes());
        assert_eq!(
            parse_header(&oversized),
            Err(ProtocolError::InvalidLength(MAX_FRAME_BYTES + 1))
        );

        let mut bad_magic = empty;
        bad_magic[..4].copy_from_slice(b"NOPE");
        assert_eq!(parse_header(&bad_magic), Err(ProtocolError::InvalidMagic));
        assert_eq!(
            validate_ack_length(MAX_ACK_BYTES + 1, MAX_ACK_BYTES),
            Err(ProtocolError::InvalidLength(MAX_ACK_BYTES + 1))
        );
    }
}
