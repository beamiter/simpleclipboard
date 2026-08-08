//! One daemon request per process, so Vim can make it with `job_start()`.
//!
//! The `libcall` entry points in the library are synchronous by construction:
//! Vim calls into the shared object on its own UI thread and gets the answer
//! back as a return value, which means a daemon that is slow to answer — or a
//! clipboard that is waiting on a display server that will never reply — freezes
//! the editor for the whole request deadline, on every yank.  A separate
//! executable moves exactly the same request onto a child process that Vim
//! watches asynchronously, and it is also the only way to carry a Get reply
//! back, since `libcallnr()` can return nothing but a number.
//!
//! Everything about the request itself — framing, AEAD sealing, the challenge
//! and the response binding — is the library's `send_request`, verbatim, so the
//! two transports cannot drift apart.
//!
//! The token is read from the environment and the clipboard payload from stdin.
//! Neither is ever an argument: `/proc/*/cmdline` is world-readable, so an
//! argv-carried token or clipboard would be visible to every process on the
//! machine for as long as this one runs.

use simpleclipboard::protocol::{PlainRequest, Selection};
use simpleclipboard::{ClientError, ClientRequest, ack_result, send_request};
use std::env;
use std::io::{Read, Write};
use std::process::ExitCode;

// The same vocabulary the FFI returns, so the Vim side reads one set of
// outcomes whichever transport carried the request.
const EXIT_OK: u8 = 0;
const EXIT_FAILED: u8 = 1;
const EXIT_OUTCOME_UNKNOWN: u8 = 2;
const EXIT_USAGE: u8 = 64;

const TOKEN_VARIABLE: &str = "SIMPLECLIPBOARD_TOKEN";

struct Options {
    address: String,
    action: String,
    selection: Selection,
}

fn usage() -> String {
    format!(
        "simpleclipboard-client {}\n\n\
         Usage: simpleclipboard-client --address HOST:PORT --action ping|set|get\n\
         \x20                          [--selection clipboard|primary]\n\n\
         The text of a `set` is read from standard input; the text of a `get` is\n\
         written to standard output.  The pre-shared key is read from\n\
         {TOKEN_VARIABLE}; it is deliberately not a command-line argument.\n\n\
         Exit status: {EXIT_OK} success, {EXIT_FAILED} failure,\n\
         {EXIT_OUTCOME_UNKNOWN} the clipboard write started but its outcome is\n\
         unknown, {EXIT_USAGE} usage error.",
        env!("CARGO_PKG_VERSION")
    )
}

fn parse_options() -> Result<Option<Options>, String> {
    let mut address = None;
    let mut action = None;
    let mut selection = Selection::Clipboard;
    let mut arguments = env::args().skip(1);

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--help" | "-h" => {
                println!("{}", usage());
                return Ok(None);
            }
            "--version" | "-V" => {
                println!("simpleclipboard-client {}", env!("CARGO_PKG_VERSION"));
                return Ok(None);
            }
            "--address" => address = Some(next_value(&mut arguments, "--address")?),
            "--action" => action = Some(next_value(&mut arguments, "--action")?),
            "--selection" => {
                let value = next_value(&mut arguments, "--selection")?;
                selection = Selection::parse(&value)
                    .ok_or_else(|| format!("unknown selection: {value}"))?;
            }
            other => return Err(format!("unknown option: {other}")),
        }
    }

    let address = address.ok_or_else(|| "--address is required".to_owned())?;
    let action = action.ok_or_else(|| "--action is required".to_owned())?;
    if address.is_empty() {
        return Err("--address must not be empty".to_owned());
    }
    Ok(Some(Options {
        address,
        action,
        selection,
    }))
}

fn next_value(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, String> {
    arguments
        .next()
        .ok_or_else(|| format!("{option} needs a value"))
}

fn read_stdin() -> Result<String, String> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .read_to_end(&mut bytes)
        .map_err(|error| format!("could not read the clipboard text: {error}"))?;
    String::from_utf8(bytes).map_err(|_| "the clipboard text is not valid UTF-8".to_owned())
}

fn build_request(options: &Options) -> Result<PlainRequest, String> {
    match options.action.as_str() {
        "ping" => Ok(PlainRequest::Ping),
        "get" => Ok(PlainRequest::Get {
            selection: options.selection,
        }),
        "set" => Ok(PlainRequest::Set {
            text: read_stdin()?,
        }),
        other => Err(format!("unknown action: {other}")),
    }
}

fn run() -> Result<u8, String> {
    let Some(options) = parse_options()? else {
        return Ok(EXIT_OK);
    };
    let request = build_request(&options)?;
    let token = env::var(TOKEN_VARIABLE).unwrap_or_default();
    let client = ClientRequest::new(request, &token);
    drop(token);

    match send_request(&options.address, &client) {
        Ok(ack) => {
            if let Some(text) = ack.text.as_deref()
                && ack.ok
            {
                // Written verbatim, without a trailing newline of our own: the
                // clipboard's own bytes are the whole answer, and a newline
                // invented here would be pasted into the user's buffer.
                let mut stdout = std::io::stdout().lock();
                stdout
                    .write_all(text.as_bytes())
                    .and_then(|()| stdout.flush())
                    .map_err(|error| format!("could not write the clipboard text: {error}"))?;
            }
            if !ack.ok {
                eprintln!(
                    "simpleclipboard-client: daemon refused the request: {}",
                    ack.detail.as_deref().unwrap_or("no detail")
                );
            }
            Ok(match ack_result(&ack) {
                1 => EXIT_OK,
                2 => EXIT_OUTCOME_UNKNOWN,
                _ => EXIT_FAILED,
            })
        }
        Err(ClientError::OutcomeUnknown) => {
            eprintln!("simpleclipboard-client: clipboard outcome is unknown");
            Ok(EXIT_OUTCOME_UNKNOWN)
        }
        Err(error) => {
            eprintln!("simpleclipboard-client: {error}");
            Ok(EXIT_FAILED)
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code),
        // A usage error is the caller's mistake rather than the daemon's, and
        // it is kept distinct so that a plugin which starts passing the wrong
        // arguments does not look like an unreachable clipboard.
        Err(message) => {
            eprintln!("simpleclipboard-client: {message}");
            eprintln!("{}", usage());
            ExitCode::from(EXIT_USAGE)
        }
    }
}
