//! One daemon request per process, for a caller that cannot use the `libcall`
//! entry points.
//!
//! Those entry points are synchronous by construction: Vim calls into the
//! shared object on its own UI thread and gets the answer back as a return
//! value, which means a daemon that is slow to answer — or a clipboard waiting
//! on a display server that will never reply — freezes the editor for the whole
//! request deadline, on every yank.  A separate executable moves exactly the
//! same request onto a child process that an editor can watch asynchronously,
//! and it is also the only way to carry a Get reply back, since `libcallnr()`
//! can return nothing but a number.
//!
//! `install.sh` places the binary in `lib/` and it works from a shell.
//! Note that the plugin does not drive it yet: `autoload/simpleclipboard.vim`
//! still sends every copy through `libcallnr()`, and Get has no Vim-side
//! caller at all.  Nothing here reaches a user until that path is written.
//!
//! Everything about the request itself — framing, AEAD sealing, the challenge
//! and the response binding — is the library's `send_request`, verbatim, so the
//! two transports cannot drift apart.
//!
//! The token is read from the environment and the clipboard payload from stdin.
//! Neither is ever an argument: `/proc/*/cmdline` is world-readable, so an
//! argv-carried token or clipboard would be visible to every process on the
//! machine for as long as this one runs.

use simpleclipboard::protocol::{MAX_SET_TEXT_BYTES, PlainRequest, Selection};
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
         --selection applies to `get` only; SCB1 has no room for a selection in a\n\
         `set`, so every write goes to CLIPBOARD and naming a selection there is a\n\
         usage error rather than a silent write to the wrong place.\n\n\
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
    parse_arguments(env::args().skip(1))
}

fn parse_arguments(mut arguments: impl Iterator<Item = String>) -> Result<Option<Options>, String> {
    let mut address = None;
    let mut action = None;
    let mut selection = None;

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
                selection = Some(
                    Selection::parse(&value)
                        .ok_or_else(|| format!("unknown selection: {value}"))?,
                );
            }
            other => return Err(format!("unknown option: {other}")),
        }
    }

    let address = address.ok_or_else(|| "--address is required".to_owned())?;
    let action = action.ok_or_else(|| "--action is required".to_owned())?;
    if address.is_empty() {
        return Err("--address must not be empty".to_owned());
    }
    // Only Get carries a selection on the wire: PlainRequest::Set is a bare
    // length-prefixed string and the daemon's set path hardcodes CLIPBOARD.
    // Accepting `--action set --selection primary` therefore wrote CLIPBOARD
    // and exited 0, which is the worst possible answer for someone scripting a
    // PRIMARY write - the one outcome they would never check for.  Refuse it
    // instead, and keep the refusal a usage error so it cannot be mistaken for
    // an unreachable daemon.
    if selection.is_some() && action != "get" {
        return Err(format!(
            "--selection applies to --action get; a `{action}` always writes the \
             clipboard selection"
        ));
    }
    Ok(Some(Options {
        address,
        action,
        selection: selection.unwrap_or_default(),
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

fn read_text(mut reader: impl Read) -> Result<String, String> {
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take((MAX_SET_TEXT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("could not read the clipboard text: {error}"))?;
    if bytes.len() > MAX_SET_TEXT_BYTES {
        return Err(format!(
            "clipboard text exceeds the {MAX_SET_TEXT_BYTES}-byte request limit"
        ));
    }
    String::from_utf8(bytes).map_err(|_| "the clipboard text is not valid UTF-8".to_owned())
}

fn read_stdin() -> Result<String, String> {
    read_text(std::io::stdin())
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

#[cfg(test)]
mod tests {
    use super::*;

    const ADDRESS: [&str; 2] = ["--address", "127.0.0.1:12343"];

    fn parse(rest: &[&str]) -> Result<Option<Options>, String> {
        let arguments = ADDRESS
            .iter()
            .chain(rest.iter())
            .map(|argument| (*argument).to_owned());
        parse_arguments(arguments)
    }

    // The selection only reaches the wire for Get: PlainRequest::Set is a bare
    // length-prefixed string, and the daemon's set path hardcodes CLIPBOARD.
    // Parsing --selection for a set therefore used to write the clipboard and
    // exit 0, which is the one answer a caller scripting a PRIMARY write would
    // never think to check.
    #[test]
    fn a_selection_is_refused_where_it_cannot_reach_the_wire() {
        for action in ["set", "ping"] {
            for selection in ["primary", "clipboard"] {
                let arguments = ["--action", action, "--selection", selection];
                let Err(error) = parse(&arguments) else {
                    panic!("--selection was accepted for --action {action}");
                };
                assert!(
                    error.contains("--selection applies to --action get"),
                    "{action}/{selection}: {error}"
                );
            }
        }
    }

    #[test]
    fn a_set_without_a_selection_is_still_accepted() {
        let options = parse(&["--action", "set"])
            .expect("a plain set must parse")
            .expect("a plain set is not --help");
        assert_eq!(options.action, "set");
        assert_eq!(options.selection, Selection::Clipboard);
    }

    #[test]
    fn a_get_carries_its_selection_into_the_request() {
        let options = parse(&["--action", "get", "--selection", "primary"])
            .expect("a get with a selection must parse")
            .expect("a get is not --help");
        assert_eq!(
            build_request(&options),
            Ok(PlainRequest::Get {
                selection: Selection::Primary
            })
        );
    }

    #[test]
    fn stdin_is_bounded_before_the_request_is_materialized() {
        let oversized = std::io::repeat(b'x').take((MAX_SET_TEXT_BYTES + 1) as u64);
        let error = read_text(oversized).unwrap_err();
        assert!(error.contains("request limit"), "{error}");

        let exact = std::io::repeat(b'x').take(MAX_SET_TEXT_BYTES as u64);
        assert_eq!(read_text(exact).unwrap().len(), MAX_SET_TEXT_BYTES);
    }

    #[test]
    fn a_get_defaults_to_the_clipboard_selection() {
        let options = parse(&["--action", "get"])
            .expect("a bare get must parse")
            .expect("a get is not --help");
        assert_eq!(
            build_request(&options),
            Ok(PlainRequest::Get {
                selection: Selection::Clipboard
            })
        );
    }

    // The usage text advertised --selection as a general option, which is how a
    // caller learned to pass it to a set in the first place.
    #[test]
    fn usage_says_the_selection_is_for_get_only() {
        let usage = usage();
        assert!(
            usage.contains("--selection applies to `get` only"),
            "{usage}"
        );
    }
}
