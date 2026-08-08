# Security policy

SimpleClipboard handles clipboard contents, local process execution, terminal
control sequences, and optional network transport. Treat its configuration and
logs as sensitive.

## Supported versions

| Version | Security updates |
| --- | --- |
| 0.2.x | Supported after the 0.2.0 release |
| 0.1.x | Unsupported |

Version 0.2 hardens the shipped TCP protocol and corrects the stale Unix-socket
description in the 0.1 documentation. Client libraries and daemons from
different release lines must not be mixed.

## Reporting a vulnerability

Please use a
[private GitHub Security Advisory](https://github.com/beamiter/simpleclipboard/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Include:

- the affected SimpleClipboard revision or release;
- Vim, operating system, display server, terminal, and tmux versions;
- whether the daemon was local, tunneled, or reachable over a network;
- the smallest reproducible configuration and steps;
- expected and observed behavior;
- any suggested mitigation.

Remove real clipboard contents, pre-shared tokens, hostnames, usernames, and keys
before submitting a report. A maintainer should acknowledge a complete report
within seven days and coordinate disclosure after a fix is available.

## Security model

### Local daemon

The Vim-managed daemon binds to `127.0.0.1` by default. Loopback reduces network
exposure but is not a per-user authorization boundary: other local users or
sandboxed processes may be able to reach a loopback TCP port.

Use `g:simpleclipboard_token` on shared machines. A daemon configured to bind
a non-loopback address refuses to start without a token.

`:SimpleCopyStop` stops only a daemon job started by the current Vim instance.
It does not trust a PID file or kill a process merely because it owns the
configured port.

### Tokens and transport

The token is a pre-shared key. It is not transmitted. SimpleClipboard derives
independent request and acknowledgement keys with domain-separated SHA-256 and
uses AES-256-GCM to authenticate and encrypt both directions. Each connection
starts with a fresh daemon challenge; the request is bound to that challenge,
and the acknowledgement is also bound to the request nonce. A fake endpoint
without the token cannot read clipboard text or forge a successful response,
and captured ciphertext cannot be transferred to another connection.

With no token, loopback SCB1 payloads are plaintext. The daemon refuses a
non-loopback listener without a token, and Vim refuses remote, container, or
explicit custom daemon routing without one.

Reading the clipboard is not the mirror image of writing it. Writing to a
tokenless loopback daemon is a nuisance; reading from one would let every
account that can reach loopback poll for whatever the user last copied — a
password, a recovery code, an access token. The daemon therefore answers a
`get` request only when that request is authenticated, and otherwise refuses it
with `get_requires_authentication`. Set `g:simpleclipboard_token` to read the
clipboard through the daemon; without one, a paste falls back to the local
`pbpaste`/`wl-paste`/`xclip`/`xsel` commands, which are already subject to the
display server's own access control.

The pre-shared key reaches `simpleclipboard-client` through the environment and
the clipboard payload through its standard input. Neither is ever a command-line
argument, because `/proc/<pid>/cmdline` is world-readable on Linux.

- Keep the daemon on loopback whenever possible.
- Use SSH port forwarding, a VPN, or another trusted encrypted transport
  across machine boundaries as defense in depth.
- Keep OpenSSH reverse-forward listeners on the remote loopback interface.
- Do not expose the daemon port directly to a LAN, container bridge, or the
  internet.
- Use a long random token for tunnels and shared hosts. The SHA-256 derivation
  is not password stretching; a weak human-chosen value is vulnerable to
  offline guessing by someone who records ciphertext.
- Store tokens in a permissions-restricted local configuration or environment
  file, not a public vimrc repository or shell history.

An explicit `g:simpleclipboard_address` changes routing only and requires a
token. It does not hide connection metadata or guarantee availability.

### Custom commands

`g:simpleclipboard_copy_command` accepts `list<string>` argv and is executed
without a shell. Keep the executable path and arguments under your control.
Avoid wrappers that reintroduce shell evaluation of clipboard text. The
process must not detach or daemonize: it should exit only after its clipboard
write is complete so serialized copy ordering remains meaningful.

### OSC52

OSC52 sends clipboard data to the controlling terminal. The terminal,
multiplexer, and any intermediate SSH client decide whether to accept it.

- Disable OSC52 with `g:simpleclipboard_disable_osc52 = 1` when terminal
  clipboard writes are not appropriate.
- The default 75,000-byte limit reduces accidental oversized terminal
  sequences.
- Oversized content is rejected by default. Enable
  `g:simpleclipboard_osc52_truncate` only when a partial clipboard is
  acceptable.
- Treat terminal recordings and debug traces as potentially sensitive.

### Clipboard and logs

Clipboard text may contain passwords, API keys, source code, personal data, or
escape/control characters. SimpleClipboard diagnostics should not need the
clipboard payload or raw token. Before sharing logs, still review and redact
addresses, paths, usernames, environment details, and copied data.

## Out of scope

The following are not security boundaries provided by SimpleClipboard:

- confidentiality of the operating system clipboard after a successful copy;
- isolation from a fully compromised Vim process or user account;
- confidentiality of tokenless loopback transport or connection metadata;
- terminal enforcement of OSC52 policy;
- security of user-supplied executables or SSH/VPN configuration.
