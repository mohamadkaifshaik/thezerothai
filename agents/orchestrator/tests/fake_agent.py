#!/usr/bin/env python3
"""A stand-in for the `claude` and `codex` CLIs, used by the agentctl tests.

Usage: fake_agent.py <claude|codex> [cli args...]. The behaviour of each call comes from the JSON plan in
$FAKE_PLAN, e.g. {"claude": ["limit", "ok"], "codex": ["ok"]}: the n-th call of an engine runs the n-th entry.
Every call records its argv and prompt under $FAKE_LOG.
Behaviours: ok, tool429, limit, transient, fatal, hang.
"""
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

engine = sys.argv[1]
argv = sys.argv[2:]
log = Path(os.environ["FAKE_LOG"])
log.mkdir(parents=True, exist_ok=True)
counter = log / f"{engine}.count"
n = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(n + 1))
plan = json.loads(Path(os.environ["FAKE_PLAN"]).read_text())[engine]
behaviour = plan[n] if n < len(plan) else "ok"
prompt = sys.stdin.read()
(log / f"{engine}-{n}.json").write_text(json.dumps({"argv": argv, "behaviour": behaviour, "prompt": prompt}))

sid = argv[argv.index("--resume") + 1] if "--resume" in argv else str(uuid.uuid4())
if engine == "codex" and "resume" in argv:
    sid = argv[-2]


def emit(ev):
    print(json.dumps(ev), flush=True)


def start():
    if engine == "claude":
        emit({"type": "system", "subtype": "init", "session_id": sid})
    else:
        emit({"type": "thread.started", "thread_id": sid})
        emit({"type": "turn.started"})


def say(text):
    if engine == "claude":
        emit({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}, "session_id": sid})
    else:
        emit({"type": "item.completed", "item": {"id": "i", "type": "agent_message", "text": text}})


def finish_ok():
    if engine == "claude":
        emit({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": sid})
    else:
        emit({"type": "turn.completed", "usage": {}})
    sys.exit(0)


def do_work():
    root = Path.cwd()
    (root / f"work-{engine}-{n}.txt").write_text("work\n")
    prog = root / ".agent_state" / "progress.md"
    if prog.exists():
        text = prog.read_text()
        text = re.sub(r"(## Tasks\n)", rf"\1- [x] task done by {engine} #{n}\n", text, count=1)
        text = re.sub(r"(## Next\n)", rf"\1- next step written by {engine}\n", text, count=1)
        prog.write_text(text)


start()
if behaviour == "ok":
    do_work()
    say(f"{engine} finished its work")
    finish_ok()
elif behaviour == "tool429":
    # A tool result that merely CONTAINS limit words (e.g. reading ratelimit code) must not trigger a failover.
    if engine == "claude":
        emit({"type": "user", "message": {"content": [{"type": "tool_result",
              "content": "HTTP 429 Too Many Requests; rate limit exceeded; usage limit; credit balance is too low"}]}})
    else:
        emit({"type": "item.completed", "item": {"type": "command_execution",
              "aggregated_output": "429 Too Many Requests rate limit usage limit", "exit_code": 0}})
    say("I read a file about rate limits")
    do_work()
    finish_ok()
elif behaviour == "limit":
    do_work()
    reset = int(time.time()) + 3600
    if engine == "claude":
        emit({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": reset,
                                                              "rateLimitType": "five_hour"}})
        emit({"type": "result", "subtype": "success", "is_error": True,
              "result": f"Claude AI usage limit reached|{reset}", "session_id": sid})
    else:
        emit({"type": "error", "message": "429 Too Many Requests: You've hit your usage limit. Try again in 30 minutes."})
        emit({"type": "turn.failed", "error": {"message": "usage limit"}})
    sys.exit(1)
elif behaviour == "transient":
    if engine == "claude":
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
              "result": "API Error: 529 overloaded_error", "session_id": sid})
    else:
        emit({"type": "error", "message": "stream disconnected before completion: 503 Service Unavailable"})
    sys.exit(1)
elif behaviour == "fatal":
    print("Error: Invalid API key. Please run /login", file=sys.stderr, flush=True)
    sys.exit(1)
elif behaviour == "hang":
    (log / f"{engine}-{n}.pid").write_text(str(os.getpid()))
    say("working on something long")
    time.sleep(600)
    sys.exit(0)
