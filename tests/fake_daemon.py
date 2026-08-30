#!/usr/bin/env python3
"""Controllable JSON-lines daemon used by the simplecore supervisor tests.

Reads one JSON object per line from stdin and answers on stdout.  Behaviour is
driven by the request `type` so a single binary can act out every scenario the
supervisor has to survive.

Requests
  {"type":"ping","id":N}          -> pong carrying protocol_version/capabilities
  {"type":"echo","id":N,"v":X}    -> {"type":"echo_result","id":N,"v":X}
  {"type":"slow","id":N,"ms":M}   -> same, after M milliseconds, ON A THREAD:
                                     the reply order differs from the request
                                     order, which is what tells routing by id
                                     apart from routing by arrival
  {"type":"silent","id":N}        -> no reply at all (exercises timeouts)
  {"type":"emit","n":K}           -> K unsolicited {"type":"tick","seq":i}
  {"type":"stderr","v":X,"n":K}   -> K lines (default 1) of X on stderr
  {"type":"crash","code":C}       -> exit immediately with status C
  {"type":"garbage"}              -> a line that is not valid JSON

Environment
  FAKE_PROTOCOL     protocol_version to report (default 3)
  FAKE_CAPS         comma-separated capability names (default "alpha,beta")
  FAKE_PROTO_KEY    field name carrying the version (default protocol_version)
  FAKE_CAPS_KEY     field name carrying the capabilities (default capabilities)
  FAKE_CRASH_AFTER  exit with FAKE_CRASH_CODE this many ms after start
  FAKE_CRASH_CODE   exit status for the timed crash (default 9)
  FAKE_NO_PONG      if set, never answer a ping (exercises handshake timeout)
  FAKE_BAD_PONG     "id", "type", "protocol", "capabilities", or "burst"
  FAKE_IGNORE_TERM  if set, ignore SIGTERM (exercises the SIGKILL escalation)
"""

import json
import os
import signal
import sys
import threading
import time


# `slow` answers on its own thread, so two writers can reach stdout at once.
# A half-written JSON line would be indistinguishable from the `garbage` case.
_out = threading.Lock()


def emit(obj):
    line = json.dumps(obj) + "\n"
    with _out:
        sys.stdout.write(line)
        sys.stdout.flush()


def main():
    protocol = int(os.environ.get("FAKE_PROTOCOL", "3"))
    caps_env = os.environ.get("FAKE_CAPS", "alpha,beta")
    caps = {c: True for c in caps_env.split(",") if c}
    proto_key = os.environ.get("FAKE_PROTO_KEY", "protocol_version")
    caps_key = os.environ.get("FAKE_CAPS_KEY", "capabilities")

    if os.environ.get("FAKE_IGNORE_TERM"):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)

    crash_after = os.environ.get("FAKE_CRASH_AFTER")
    if crash_after:
        code = int(os.environ.get("FAKE_CRASH_CODE", "9"))

        def bomb():
            time.sleep(int(crash_after) / 1000.0)
            os._exit(code)

        threading.Thread(target=bomb, daemon=True).start()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            emit({"type": "error", "message": "bad json"})
            continue

        kind = req.get("type", "")
        rid = req.get("id", 0)

        if kind == "ping":
            if os.environ.get("FAKE_NO_PONG"):
                continue
            bad_pong = os.environ.get("FAKE_BAD_PONG", "")
            if bad_pong == "burst":
                emit({
                    "type": "pong",
                    "id": rid,
                    proto_key: "three",
                    caps_key: caps,
                })
                emit({
                    "type": "pong",
                    "id": rid,
                    proto_key: 9,
                    caps_key: {"late": True},
                })
                continue
            emit({
                "type": 0 if bad_pong == "type" else "pong",
                "id": str(rid) if bad_pong == "id" else rid,
                proto_key: "three" if bad_pong == "protocol" else protocol,
                caps_key: [] if bad_pong == "capabilities" else caps,
            })
        elif kind == "echo":
            emit({"type": "echo_result", "id": rid, "v": req.get("v")})
        elif kind == "slow":
            # On a thread on purpose.  Answering in the main loop would make
            # every reply arrive in request order, and a supervisor that
            # ignored the id and answered the newest in-flight request would
            # be indistinguishable from one that routed correctly.
            def answer_later(rid=rid, req=req):
                time.sleep(req.get("ms", 100) / 1000.0)
                emit({"type": "echo_result", "id": rid, "v": req.get("v")})

            threading.Thread(target=answer_later, daemon=True).start()
        elif kind == "silent":
            pass
        elif kind == "emit":
            for i in range(req.get("n", 1)):
                emit({"type": "tick", "seq": i})
        elif kind == "stderr":
            text = req.get("v", "stderr line")
            for _ in range(req.get("n", 1)):
                sys.stderr.write(text + "\n")
            sys.stderr.flush()
        elif kind == "garbage":
            sys.stdout.write("this is not json\n")
            sys.stdout.flush()
        elif kind == "crash":
            os._exit(req.get("code", 1))
        else:
            emit({"type": "error", "id": rid, "message": "unknown type " + kind})


if __name__ == "__main__":
    main()
