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
const TAG_SERVER_HELLO: u8 = 0x10;
const TAG_REQUEST_PLAIN: u8 = 0x20;
const TAG_REQUEST_AUTHENTICATED: u8 = 0x21;
const TAG_ACK_PLAIN: u8 = 0x30;
const TAG_ACK_AUTHENTICATED: u8 = 0x31;
const TAG_ACK_BODY: u8 = 0x01;
const TAG_NONE: u8 = 0x00;
const TAG_SOME: u8 = 0x01;

const PLAIN_REQUEST_PREFIX_BYTES: usize = 1;
const STRING_PREFIX_BYTES: usize = LENGTH_BYTES;
const WIRE_PLAIN_PREFIX_BYTES: usize = 1;
const WIRE_REQUEST_AUTH_OVERHEAD: usize = 1 + NONCE_BYTES + LENGTH_BYTES;
const ACK_BODY_MIN_BYTES: usize = 3;
const ACK_BODY_WITH_DETAIL_OVERHEAD: usize = 3 + LENGTH_BYTES;
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlainRequest {
    Ping,
    Set { text: String },
    Legacy { text: String },
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ack {
    pub ok: bool,
    pub detail: Option<String>,
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

fn encode_ack_body(ack: &Ack) -> Result<Vec<u8>, ProtocolError> {
    let detail_bytes = ack.detail.as_deref().map(str::as_bytes);
    let length = match detail_bytes {
        None => ACK_BODY_MIN_BYTES,
        Some(detail) => checked_size(
            &[ACK_BODY_WITH_DETAIL_OVERHEAD, detail.len()],
            MAX_ACK_BYTES - WIRE_PLAIN_PREFIX_BYTES,
        )?,
    };
    let mut output = Vec::with_capacity(length);
    output.push(TAG_ACK_BODY);
    output.push(u8::from(ack.ok));
    match detail_bytes {
        None => output.push(TAG_NONE),
        Some(detail) => {
            output.push(TAG_SOME);
            append_length_prefixed(&mut output, detail)?;
        }
    }
    Ok(output)
}

fn decode_ack_body(payload: &[u8]) -> Result<Ack, ProtocolError> {
    checked_size(&[payload.len()], MAX_ACK_BYTES - WIRE_PLAIN_PREFIX_BYTES)?;
    let mut decoder = Decoder::new(payload);
    let body_tag = decoder.read_u8()?;
    if body_tag != TAG_ACK_BODY {
        return Err(ProtocolError::UnknownTag(body_tag));
    }
    let ok = match decoder.read_u8()? {
        0 => false,
        1 => true,
        value => return Err(ProtocolError::InvalidBoolean(value)),
    };
    let detail = match decoder.read_u8()? {
        TAG_NONE => None,
        TAG_SOME => {
            let maximum = MAX_ACK_BYTES - WIRE_PLAIN_PREFIX_BYTES - ACK_BODY_WITH_DETAIL_OVERHEAD;
            let bytes = decoder.read_length_prefixed(0, maximum)?;
            Some(
                std::str::from_utf8(bytes)
                    .map_err(|_| ProtocolError::InvalidUtf8)?
                    .to_owned(),
            )
        }
        tag => return Err(ProtocolError::UnknownTag(tag)),
    };
    decoder.finish()?;
    Ok(Ack { ok, detail })
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
    validate_ack_length(payload.len())?;
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
    match ack {
        WireAck::Plain(ack) => {
            let body = encode_ack_body(ack)?;
            let length = checked_size(&[WIRE_PLAIN_PREFIX_BYTES, body.len()], MAX_ACK_BYTES)?;
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
            let length = checked_size(&[WIRE_ACK_AUTH_OVERHEAD, ciphertext.len()], MAX_ACK_BYTES)?;
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

fn decode_wire_ack(payload: &[u8]) -> Result<WireAck, ProtocolError> {
    validate_ack_length(payload.len())?;
    let mut decoder = Decoder::new(payload);
    match decoder.read_u8()? {
        TAG_ACK_PLAIN => decode_ack_body(decoder.remaining()).map(WireAck::Plain),
        TAG_ACK_AUTHENTICATED => {
            let request_nonce = decoder.read_array::<NONCE_BYTES>()?;
            let nonce = decoder.read_array::<NONCE_BYTES>()?;
            let maximum = MAX_ACK_BYTES - WIRE_ACK_AUTH_OVERHEAD;
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
            AesNonce::from_slice(nonce),
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
            AesNonce::from_slice(nonce),
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
        MAX_ACK_BYTES,
    )?;
    let aad = ack_aad(challenge, &request_nonce);
    let ciphertext = encrypt(&keys.ack, &nonce, &plaintext, &aad)?;
    Ok(WireAck::Authenticated {
        request_nonce,
        nonce,
        ciphertext,
    })
}

pub fn open_ack(
    keys: &AuthKeys,
    challenge: &Challenge,
    expected_request_nonce: &Nonce,
    response: &WireAck,
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
        || ciphertext.len() > MAX_ACK_BYTES - WIRE_ACK_AUTH_OVERHEAD
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
    validate_ack_length(payload.len())?;
    frame(payload)
}

pub fn encode_ack_frame(ack: &WireAck) -> Result<Vec<u8>, ProtocolError> {
    let payload = encode_wire_ack(ack)?;
    validate_ack_length(payload.len())?;
    frame(payload)
}

pub fn decode_request_payload(payload: &[u8]) -> Result<WireRequest, ProtocolError> {
    decode_wire_request(payload)
}

pub fn decode_hello_payload(payload: &[u8]) -> Result<ServerHello, ProtocolError> {
    decode_server_hello(payload)
}

pub fn decode_ack_payload(payload: &[u8]) -> Result<WireAck, ProtocolError> {
    decode_wire_ack(payload)
}

pub fn validate_ack_length(length: usize) -> Result<(), ProtocolError> {
    if length == 0 || length > MAX_ACK_BYTES {
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
        let ack = Ack {
            ok: true,
            detail: Some("clipboard_set_ok".to_owned()),
        };
        let mut response =
            seal_ack_with_nonce(&keys, &challenge, request_nonce, &ack, [9_u8; NONCE_BYTES])
                .unwrap();
        let encoded = encode_ack_frame(&response).unwrap();
        let (_, payload) = split_frame(&encoded);
        assert_eq!(decode_ack_payload(payload).unwrap(), response);
        assert_eq!(
            open_ack(&keys, &challenge, &request_nonce, &response).unwrap(),
            ack
        );
        assert_eq!(
            open_ack(&keys, &challenge, &[4_u8; NONCE_BYTES], &response),
            Err(ProtocolError::ResponseBinding)
        );
        assert_eq!(
            open_ack(&keys, &[8_u8; CHALLENGE_BYTES], &request_nonce, &response),
            Err(ProtocolError::AuthenticationFailed)
        );

        let WireAck::Authenticated { ciphertext, .. } = &mut response else {
            panic!("expected authenticated ack");
        };
        ciphertext[0] ^= 1;
        assert_eq!(
            open_ack(&keys, &challenge, &request_nonce, &response),
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
            Ack {
                ok: true,
                detail: None,
            },
            Ack {
                ok: false,
                detail: Some("request_rejected".to_owned()),
            },
        ] {
            let wire = WireAck::Plain(ack);
            let encoded = encode_ack_frame(&wire).unwrap();
            let (header, payload) = split_frame(&encoded);

            assert_eq!(parse_header(header).unwrap(), payload.len());
            assert_eq!(decode_ack_payload(payload).unwrap(), wire);

            let mut trailing = payload.to_vec();
            trailing.push(0);
            assert_eq!(
                decode_ack_payload(&trailing),
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

        let ack = encode_ack_frame(&WireAck::Plain(Ack {
            ok: false,
            detail: Some("x".to_owned()),
        }))
        .unwrap();
        let (_, ack_payload) = split_frame(&ack);
        assert_eq!(
            ack_payload,
            [TAG_ACK_PLAIN, TAG_ACK_BODY, 0, TAG_SOME, 0, 0, 0, 1, b'x']
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
            decode_ack_payload(&[0xfc]),
            Err(ProtocolError::UnknownTag(0xfc))
        );
        assert_eq!(
            decode_ack_payload(&[TAG_ACK_PLAIN, TAG_ACK_BODY, 2, TAG_NONE]),
            Err(ProtocolError::InvalidBoolean(2))
        );
        assert_eq!(
            decode_ack_payload(&[TAG_ACK_PLAIN, TAG_ACK_BODY, 1, 2]),
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

        let ack = encode_ack_frame(&WireAck::Plain(Ack {
            ok: false,
            detail: Some("detail".to_owned()),
        }))
        .unwrap();
        let (_, ack_payload) = split_frame(&ack);
        for length in 1..ack_payload.len() {
            assert!(decode_ack_payload(&ack_payload[..length]).is_err());
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
            decode_ack_payload(&invalid_ack_utf8),
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
            validate_ack_length(MAX_ACK_BYTES + 1),
            Err(ProtocolError::InvalidLength(MAX_ACK_BYTES + 1))
        );
    }
}
