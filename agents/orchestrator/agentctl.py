#!/usr/bin/env python3
"""agentctl: run Claude Code or Codex on this repository, with automatic failover between them.

One engine runs at a time against the shared working tree. The orchestrator watches the engine's JSON event
stream (never the content of tool results, which is full of words like "429" in this repository), and sorts every
failure into one of three kinds:

  limit      usage or credit limit, HTTP 429  -> checkpoint, write HANDOFF.md, cool the engine down, start the other
  transient  overloaded, 5xx, network          -> retry the same engine with backoff
  fatal      auth, bad flags, unknown crash    -> checkpoint, write HANDOFF.md, stop (the other engine would fail too)

Commands: start, continue, stop, status, handoff, recover, end. See README_AGENTS.md.
Standard library only (Python 3.9+). Works on Windows (Git Bash or PowerShell), macOS and Linux.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

EXIT_OK = 0
EXIT_FATAL = 1
EXIT_USAGE = 2
EXIT_STOPPED = 3
EXIT_LOCKED = 4
EXIT_BOTH_LIMITED = 75

IS_WINDOWS = os.name == "nt"


# --------------------------------------------------------------------------------------------- small helpers

def now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t: dt.datetime | None) -> str | None:
    return t.isoformat() if t else None


def parse_iso(s: str | None) -> dt.datetime | None:
    return dt.datetime.fromisoformat(s) if s else None


def stamp() -> str:
    return now().strftime("%Y%m%dT%H%M%SZ")


def say(msg: str) -> None:
    print(f"[agentctl {now().strftime('%H:%M:%S')}] {msg}", flush=True)


def git(root: Path, *args: str, env: dict | None = None, check: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, encoding="utf-8",
                       errors="replace", env=env)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".")
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if IS_WINDOWS:
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = k32.GetExitCodeProcess(h, ctypes.byref(code))
        k32.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def kill_tree(proc: subprocess.Popen, grace: float) -> None:
    """Ask the engine to exit, then force the whole process tree down (npm .cmd shims spawn a child node)."""
    if proc.poll() is not None:
        return
    try:
        if IS_WINDOWS:
            proc.send_signal(signal.CTRL_BREAK_EVENT)
        else:
            os.killpg(proc.pid, signal.SIGTERM)
    except Exception:
        pass
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    if IS_WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
    elif proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except Exception:
            pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass


# --------------------------------------------------------------------------------------------- paths and config

class Ctx:
    def __init__(self) -> None:
        root = os.environ.get("AGENTCTL_ROOT")
        if root:
            self.root = Path(root).resolve()
        else:
            here = Path(__file__).resolve().parent
            self.root = Path(git(here, "rev-parse", "--show-toplevel")).resolve()
        cfg_path = Path(os.environ.get("AGENTCTL_CONFIG") or self.root / "agents" / "orchestrator.json")
        self.cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
        self.state = self.root / self.cfg.get("state_dir", ".agent_state")
        self.session_file = self.state / "session.json"
        self.lock_file = self.state / "agent.lock"
        self.stop_file = self.state / "STOP"
        self.progress = self.state / "progress.md"
        self.handoff = self.state / "HANDOFF.md"
        self.runs = self.state / "runs"
        self.handoffs = self.state / "handoffs"
        self.sessions = self.state / "sessions"
        self.patterns = {k: [re.compile(p, re.I) for p in v] for k, v in self.cfg["patterns"].items()}

    def agents(self) -> list[str]:
        return list(self.cfg["order"])

    def other(self, agent: str) -> str:
        return next(a for a in self.agents() if a != agent)


# --------------------------------------------------------------------------------------------- session state

def load_session(ctx: Ctx) -> dict | None:
    if not ctx.session_file.exists():
        return None
    return json.loads(ctx.session_file.read_text(encoding="utf-8"))


def save_session(ctx: Ctx, s: dict) -> None:
    s["updated_at"] = iso(now())
    if ctx.session_file.exists():
        shutil.copyfile(ctx.session_file, ctx.session_file.with_suffix(".json.bak"))
    atomic_write(ctx.session_file, json.dumps(s, indent=2) + "\n")


def cooldown_until(s: dict, agent: str) -> dt.datetime | None:
    t = parse_iso(s.get("cooldowns", {}).get(agent))
    return t if t and t > now() else None


def available(s: dict, agent: str) -> bool:
    return cooldown_until(s, agent) is None


# --------------------------------------------------------------------------------------------- lock

def acquire_lock(ctx: Ctx, agent: str) -> bool:
    ctx.state.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(ctx.lock_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return False
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({"pid": os.getpid(), "agent": agent, "since": iso(now())}, f)
    return True


def read_lock(ctx: Ctx) -> dict | None:
    try:
        return json.loads(ctx.lock_file.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {"pid": -1} if ctx.lock_file.exists() else None


def update_lock(ctx: Ctx, agent: str, engine_pid: int | None = None) -> None:
    lk = read_lock(ctx) or {}
    lk.update({"pid": os.getpid(), "agent": agent, "engine_pid": engine_pid})
    atomic_write(ctx.lock_file, json.dumps(lk))


def live_run(ctx: Ctx) -> dict | None:
    """The lock, if its orchestrator OR its engine is still alive. An engine whose orchestrator died (terminal
    closed, laptop slept) is still a live run: it keeps editing the tree until someone kills it."""
    lk = read_lock(ctx)
    if not lk:
        return None
    orch = pid_alive(int(lk.get("pid") or -1))
    eng = pid_alive(int(lk.get("engine_pid") or -1))
    if orch or eng:
        return dict(lk, orchestrator_alive=orch, engine_alive=eng)
    return None


def kill_pid_tree(pid: int) -> None:
    if IS_WINDOWS:
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True)
    else:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(pid, sig)
            except Exception:
                pass
            time.sleep(2)


def refuse_if_live(ctx: Ctx) -> int | None:
    lk = live_run(ctx)
    if lk:
        who = "the orchestrator" if lk["orchestrator_alive"] else "an orphaned engine (its orchestrator is gone)"
        say(f"a run is active: {lk.get('agent')} via {who}; `stop` it"
            + ("" if lk["orchestrator_alive"] else ", or `recover --kill`"))
        return EXIT_LOCKED
    if ctx.lock_file.exists():
        say("a stale lock is left from a run that died; run `recover` first")
        return EXIT_LOCKED
    return None


def release_lock(ctx: Ctx) -> None:
    lk = read_lock(ctx)
    if lk and lk.get("pid") == os.getpid():
        ctx.lock_file.unlink(missing_ok=True)


# --------------------------------------------------------------------------------------------- progress ledger

PROGRESS_TEMPLATE = """# Progress

Goal: {goal}

## Tasks
- [ ] Plan the goal into small tasks here (replace this line)

## Blockers

## Next
- Read the goal and plan it.

## Log
"""


def sections(md: str) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    cur = None
    for line in md.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1).strip().lower()
            out[cur] = []
        elif cur:
            out[cur].append(line)
    return out


def ledger(ctx: Ctx) -> dict:
    md = ctx.progress.read_text(encoding="utf-8") if ctx.progress.exists() else ""
    sec = sections(md)
    done, todo = [], []
    for line in sec.get("tasks", []):
        m = re.match(r"^\s*[-*]\s+\[( |x|X)\]\s+(.*)$", line)
        if m:
            (done if m.group(1).lower() == "x" else todo).append(m.group(2).strip())
    clean = lambda ls: [l for l in (x.rstrip() for x in ls) if l.strip()]
    return {"done": done, "todo": todo, "blockers": clean(sec.get("blockers", [])),
            "next": clean(sec.get("next", [])), "log": clean(sec.get("log", [])),
            "goal_done": bool(re.search(r"^\s*status:\s*done\s*$", md, re.I | re.M))}


# --------------------------------------------------------------------------------------------- git checkpoint

def checkpoint(ctx: Ctx, s: dict, label: str) -> str | None:
    """Snapshot the working tree (tracked + untracked, plus the ledger) into refs/agent-checkpoints/<ts>.

    Uses a copy of the index, so the user's index, working tree and branch are untouched."""
    try:
        real_index = Path(git(ctx.root, "rev-parse", "--git-path", "index"))
        if not real_index.is_absolute():
            real_index = ctx.root / real_index
        with tempfile.TemporaryDirectory() as td:
            tmp_index = Path(td) / "index"
            if real_index.exists():
                shutil.copyfile(real_index, tmp_index)
            env = dict(os.environ, GIT_INDEX_FILE=str(tmp_index))
            git(ctx.root, "add", "-A", env=env)
            extras = [p for p in (ctx.progress, ctx.handoff, ctx.session_file) if p.exists()]
            if extras:
                git(ctx.root, "add", "-f", "--", *[str(p.relative_to(ctx.root)) for p in extras], env=env)
            tree = git(ctx.root, "write-tree", env=env)
        head = git(ctx.root, "rev-parse", "HEAD")
        commit = git(ctx.root, "commit-tree", tree, "-p", head, "-m", f"agentctl checkpoint: {label}")
        ref = f"refs/agent-checkpoints/{s['session_id'][:8]}/{stamp()}-{label}"
        git(ctx.root, "update-ref", ref, commit)
        s.setdefault("checkpoints", []).append({"ref": ref, "commit": commit, "label": label, "at": iso(now())})
        return ref
    except Exception as e:  # a checkpoint must never take the run down with it
        say(f"warning: checkpoint failed: {e}")
        return None


# --------------------------------------------------------------------------------------------- event parsing

class Outcome:
    def __init__(self, kind: str, detail: str = "", reset_at: dt.datetime | None = None) -> None:
        self.kind = kind          # completed | limit | transient | fatal | stopped
        self.detail = detail
        self.reset_at = reset_at

    def __repr__(self) -> str:
        return f"Outcome({self.kind}, {self.detail[:80]!r})"


def classify_text(ctx: Ctx, text: str) -> str | None:
    for kind in ("limit", "transient", "fatal"):
        if any(p.search(text) for p in ctx.patterns[kind]):
            return kind
    return None


def parse_reset(text: str) -> dt.datetime | None:
    m = re.search(r"\|(\d{10})\b", text)                       # "Claude AI usage limit reached|1793721600"
    if m:
        return dt.datetime.fromtimestamp(int(m.group(1)), dt.timezone.utc)
    m = re.search(r"(?:try again|resets?) in (?:about )?(\d+)\s*(second|sec|minute|min|hour|hr)s?", text, re.I)
    if m:
        n, unit = int(m.group(1)), m.group(2).lower()
        mult = 1 if unit.startswith("s") else 60 if unit.startswith("m") else 3600
        return now() + dt.timedelta(seconds=n * mult)
    return None


class RunWatch:
    """Reads one engine's JSONL stdout. Only error-typed events can trigger a failover."""

    def __init__(self, ctx: Ctx, parser: str) -> None:
        self.ctx, self.parser = ctx, parser
        self.session_id: str | None = None
        self.error: Outcome | None = None   # set when an error event is seen
        self.success = False
        self.messages: list[str] = []
        self.lock = threading.Lock()

    def feed(self, line: str) -> None:
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            return
        if not isinstance(ev, dict):
            return
        with self.lock:
            (self._claude if self.parser == "claude" else self._codex)(ev)

    def _set_error(self, text: str, reset: dt.datetime | None = None) -> None:
        kind = classify_text(self.ctx, text) or "fatal"
        if self.error is None or kind == "limit":
            self.error = Outcome(kind, text.strip()[:2000], reset or parse_reset(text))

    def _claude(self, ev: dict) -> None:
        t = ev.get("type")
        if t == "system" and ev.get("subtype") == "init" and ev.get("session_id"):
            self.session_id = ev["session_id"]
        elif t == "rate_limit_event":
            info = ev.get("rate_limit_info") or {}
            if str(info.get("status", "")).lower() == "rejected":
                reset = info.get("resetsAt")
                self.error = Outcome("limit", f"rate limit rejected ({info.get('rateLimitType', 'unknown')})",
                                     dt.datetime.fromtimestamp(int(reset), dt.timezone.utc) if reset else None)
        elif t == "assistant":
            for part in (ev.get("message") or {}).get("content") or []:
                if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                    self.messages.append(part["text"])
        elif t == "result":
            if ev.get("session_id"):
                self.session_id = ev["session_id"]
            if ev.get("is_error") or str(ev.get("subtype", "")).startswith("error"):
                self._set_error(f"{ev.get('subtype', '')}: {ev.get('result', '')}")
            else:
                self.success = True

    def _codex(self, ev: dict) -> None:
        t = ev.get("type")
        if t == "thread.started" and ev.get("thread_id"):
            self.session_id = ev["thread_id"]
        elif t == "item.completed":
            item = ev.get("item") or {}
            if item.get("type") == "agent_message" and item.get("text"):
                self.messages.append(item["text"])
        elif t == "error":
            self._set_error(str(ev.get("message") or ev))
        elif t == "turn.failed":
            err = ev.get("error") or {}
            self._set_error(str(err.get("message") if isinstance(err, dict) else err))
        elif t == "turn.completed":
            self.success = True


# --------------------------------------------------------------------------------------------- one engine run

def build_prompt(ctx: Ctx, s: dict, agent: str, mode: str, extra: str | None) -> str:
    """mode: fresh (first run), handoff (taking over), resume (same engine, native session)."""
    if mode == "resume":
        parts = ["Continue the session goal from where you stopped. Re-read .agent_state/progress.md first and "
                 "keep it updated."]
    else:
        inst = (ctx.root / ctx.cfg["agents"][agent]["instructions"]).read_text(encoding="utf-8")
        proto = (ctx.root / ctx.cfg["shared_protocol"]).read_text(encoding="utf-8")
        parts = [inst, proto, "---", f"Session goal: {s['goal']}", f"Branch: {s.get('branch')}"]
        if mode == "handoff" and ctx.handoff.exists():
            parts += ["You are taking over this session from the other engine. The handoff below is your starting "
                      "context: verify the state it describes, then continue from its Next steps.",
                      ctx.handoff.read_text(encoding="utf-8")]
        else:
            parts += ["Start the goal: plan it in .agent_state/progress.md, then work through the tasks."]
    if extra:
        parts += ["Operator note: " + extra]
    return "\n\n".join(parts) + "\n"


def run_engine(ctx: Ctx, s: dict, agent: str, mode: str, extra: str | None, stop_evt: threading.Event) -> Outcome:
    acfg = ctx.cfg["agents"][agent]
    session_id = s.get("agent_sessions", {}).get(agent)
    tmpl = acfg["resume_command"] if mode == "resume" and session_id else acfg["command"]
    if mode == "resume" and not session_id:
        mode = "handoff" if ctx.handoff.exists() else "fresh"
    cmd = [str(session_id) if a == "{session_id}" else a for a in tmpl]
    exe = shutil.which(cmd[0])
    if not exe:
        return Outcome("fatal", f"{cmd[0]} is not on PATH")
    cmd[0] = exe
    prompt = build_prompt(ctx, s, agent, mode, extra)

    run_dir = ctx.runs / f"{stamp()}-{agent}"
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "prompt.md").write_text(prompt, encoding="utf-8")
    run = {"agent": agent, "mode": mode, "started_at": iso(now()), "dir": str(run_dir.relative_to(ctx.root))}
    s.setdefault("runs", []).append(run)
    s["active_agent"], s["status"] = agent, "running"
    save_session(ctx, s)
    update_lock(ctx, agent)
    say(f"starting {agent} ({mode}); transcript: {run['dir']}")

    flags = subprocess.CREATE_NEW_PROCESS_GROUP if IS_WINDOWS else 0
    env = dict(os.environ, **{k: str(v) for k, v in (acfg.get("env") or {}).items()})
    proc = subprocess.Popen(cmd, cwd=ctx.root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace",
                            creationflags=flags, start_new_session=not IS_WINDOWS)
    update_lock(ctx, agent, proc.pid)
    watch = RunWatch(ctx, acfg["parser"])
    err_tail: list[str] = []

    def pump_out() -> None:
        with open(run_dir / "transcript.jsonl", "w", encoding="utf-8") as out:
            for line in proc.stdout:
                out.write(line)
                out.flush()
                watch.feed(line)

    def pump_err() -> None:
        with open(run_dir / "stderr.log", "w", encoding="utf-8") as out:
            for line in proc.stderr:
                out.write(line)
                out.flush()
                err_tail.append(line)
                del err_tail[:-50]

    threads = [threading.Thread(target=f, daemon=True) for f in (pump_out, pump_err)]
    for t in threads:
        t.start()
    try:
        proc.stdin.write(prompt)
        proc.stdin.close()
    except (BrokenPipeError, OSError):
        pass

    outcome: Outcome | None = None
    while proc.poll() is None:
        if stop_evt.is_set() or ctx.stop_file.exists():
            say("stop requested: stopping the engine")
            outcome = Outcome("stopped", "stopped by the operator")
            break
        if watch.error and watch.error.kind == "limit":
            say(f"{agent} hit a limit mid-run: {watch.error.detail[:120]}")
            break
        time.sleep(ctx.cfg.get("poll_seconds", 0.5))
    kill_tree(proc, ctx.cfg.get("grace_seconds", 15))
    update_lock(ctx, agent, None)
    for t in threads:
        t.join(timeout=10)

    if watch.session_id:
        s.setdefault("agent_sessions", {})[agent] = watch.session_id
    if outcome is None:
        if watch.error:
            outcome = watch.error
        elif proc.returncode == 0 and watch.success:
            outcome = Outcome("completed", "run finished")
        else:
            text = "".join(err_tail)
            kind = classify_text(ctx, text) if text else None
            if proc.returncode == 0 and not kind:
                outcome = Outcome("completed", "run finished (no result event)")
            else:
                outcome = Outcome(kind or "fatal", (text.strip() or f"exit code {proc.returncode}")[-2000:],
                                  parse_reset(text))
    run.update({"ended_at": iso(now()), "exit_code": proc.returncode, "outcome": outcome.kind,
                "detail": outcome.detail[:500], "session_id": watch.session_id})
    (run_dir / "last_messages.md").write_text(
        "\n\n---\n\n".join(watch.messages[-ctx.cfg.get("transcript_tail_messages", 3):]), encoding="utf-8")
    save_session(ctx, s)
    say(f"{agent} run ended: {outcome.kind} ({outcome.detail[:120]})")
    return outcome


# --------------------------------------------------------------------------------------------- handoff

def compile_handoff(ctx: Ctx, s: dict, reason: str, from_agent: str | None, to_agent: str | None,
                    detail: str = "", checkpoint_ref: str | None = None) -> Path:
    lg = ledger(ctx)
    start = s.get("start_commit")
    try:
        name_status = git(ctx.root, "diff", "--name-status", start) if start else ""
        stat = git(ctx.root, "diff", "--stat", start) if start else ""
        untracked = git(ctx.root, "ls-files", "--others", "--exclude-standard")
        head = git(ctx.root, "rev-parse", "--short", "HEAD")
        branch = git(ctx.root, "rev-parse", "--abbrev-ref", "HEAD")
    except RuntimeError as e:
        name_status, stat, untracked, head, branch = f"(git failed: {e})", "", "", "?", "?"
    last_msgs = ""
    runs = [r for r in s.get("runs", []) if r.get("agent") == from_agent]
    if runs:
        p = ctx.root / runs[-1]["dir"] / "last_messages.md"
        if p.exists():
            last_msgs = p.read_text(encoding="utf-8").strip()
    bullet = lambda xs, empty: "\n".join(f"- {x}" for x in xs) if xs else f"- {empty}"
    nxt = lg["next"] or ([f"- {lg['todo'][0]}"] if lg["todo"] else ["- Re-read the goal and decide the next task."])
    blockers = list(lg["blockers"])
    if reason in ("limit", "fatal") and detail:
        blockers.append(f"- Engine {from_agent} stopped with a {reason}: {detail[:300]}")
    cool = {a: iso(cooldown_until(s, a)) for a in ctx.agents() if cooldown_until(s, a)}
    md = f"""# HANDOFF

| | |
|---|---|
| Session | `{s['session_id']}` |
| Goal | {s['goal']} |
| Reason | {reason} |
| From engine | {from_agent or '-'} |
| To engine | {to_agent or 'none (see How to continue)'} |
| Written at | {iso(now())} |
| Branch / HEAD | `{branch}` / `{head}` (session started at `{(start or '?')[:8]}`) |
| Checkpoint | `{checkpoint_ref or '-'}` |
| Cooldowns | {', '.join(f'{a} until {t}' for a, t in cool.items()) or 'none'} |

## Completed tasks
{bullet(lg['done'], 'none recorded')}

## Open tasks
{bullet(lg['todo'], 'none recorded')}

## Modified files (since the session start, including untracked)
```
{name_status or '(no tracked changes)'}
{chr(10).join('??\t' + u for u in untracked.splitlines()) if untracked else ''}
```
```
{stat}
```

## Blockers
{chr(10).join(blockers) if blockers else '- none recorded'}

## Next steps
{chr(10).join(nxt)}

## Last messages from {from_agent or 'the engine'}
{last_msgs or '(none captured)'}

## How to continue
- `python agents/orchestrator/agentctl.py continue` picks the first engine that is not cooling down.
- `python agents/orchestrator/agentctl.py recover` if both engines are limited or the state looks wrong.
"""
    atomic_write(ctx.handoff, md)
    ctx.handoffs.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ctx.handoff, ctx.handoffs / f"{stamp()}-{from_agent or 'none'}-{reason}.md")
    s["last_handoff"] = {"at": iso(now()), "reason": reason, "from": from_agent, "to": to_agent}
    return ctx.handoff


# --------------------------------------------------------------------------------------------- orchestration loop

def pick_agent(ctx: Ctx, s: dict, preferred: str | None) -> str | None:
    order = ([preferred] if preferred else []) + [a for a in ctx.agents() if a != preferred]
    return next((a for a in order if available(s, a)), None)


def orchestrate(ctx: Ctx, s: dict, agent: str, mode: str, extra: str | None, cycles: int) -> int:
    stop_evt = threading.Event()
    old = signal.signal(signal.SIGINT, lambda *_: stop_evt.set())
    if not acquire_lock(ctx, agent):
        signal.signal(signal.SIGINT, old)
        say("another run holds .agent_state/agent.lock; use `status`, or `recover` if no run is alive")
        return EXIT_LOCKED
    ctx.stop_file.unlink(missing_ok=True)
    transient_left = ctx.cfg.get("transient_retries", 2)
    backoff = list(ctx.cfg.get("transient_backoff_seconds", [30, 120]))
    try:
        while True:
            out = run_engine(ctx, s, agent, mode, extra, stop_evt)
            extra = None
            if out.kind == "completed":
                cycles -= 1
                if ledger(ctx)["goal_done"] or cycles <= 0:
                    s["status"] = "idle"
                    ref = checkpoint(ctx, s, "run-completed")
                    compile_handoff(ctx, s, "run completed", agent, None, checkpoint_ref=ref)
                    save_session(ctx, s)
                    say("run completed. `continue` to keep going, `end` when the goal is done"
                        + (" (the ledger says Status: done)" if ledger(ctx)["goal_done"] else ""))
                    return EXIT_OK
                mode = "resume"
                continue
            if out.kind == "stopped":
                s["status"] = "stopped"
                ref = checkpoint(ctx, s, "stopped")
                compile_handoff(ctx, s, "stopped by the operator", agent, None, checkpoint_ref=ref)
                save_session(ctx, s)
                say("stopped. Work is checkpointed; `continue` resumes it")
                return EXIT_STOPPED
            if out.kind == "transient" and transient_left > 0:
                wait = backoff[min(len(backoff) - 1, ctx.cfg.get("transient_retries", 2) - transient_left)]
                transient_left -= 1
                say(f"transient error; retrying {agent} in {wait}s")
                if stop_evt.wait(wait) or ctx.stop_file.exists():
                    s["status"] = "stopped"
                    compile_handoff(ctx, s, "stopped by the operator", agent, None,
                                    checkpoint_ref=checkpoint(ctx, s, "stopped"))
                    save_session(ctx, s)
                    return EXIT_STOPPED
                mode = "resume"
                continue
            if out.kind in ("limit", "transient"):
                until = out.reset_at or now() + dt.timedelta(minutes=ctx.cfg.get("default_cooldown_minutes", 60))
                s.setdefault("cooldowns", {})[agent] = iso(until)
                s["failovers"] = s.get("failovers", 0) + 1
                nxt = pick_agent(ctx, s, ctx.other(agent))
                if s["failovers"] > ctx.cfg.get("max_failovers", 4):
                    nxt = None
                ref = checkpoint(ctx, s, f"{out.kind}-{agent}")
                compile_handoff(ctx, s, out.kind, agent, nxt, out.detail, ref)
                if nxt is None:
                    s["status"] = "both_limited"
                    save_session(ctx, s)
                    soonest = min((cooldown_until(s, a) for a in ctx.agents() if cooldown_until(s, a)),
                                  default=None)
                    say("no engine is available (both limited, or the failover cap is reached). "
                        f"Earliest reset: {iso(soonest) or 'unknown'}. Run `recover --wait` or `recover`.")
                    return EXIT_BOTH_LIMITED
                say(f"failing over: {agent} -> {nxt} (cooldown for {agent} until {iso(until)})")
                save_session(ctx, s)
                agent, mode, transient_left = nxt, "handoff", ctx.cfg.get("transient_retries", 2)
                continue
            # fatal
            s["status"] = "failed"
            ref = checkpoint(ctx, s, f"fatal-{agent}")
            compile_handoff(ctx, s, "fatal", agent, None, out.detail, ref)
            save_session(ctx, s)
            say(f"{agent} failed with an error that would also stop the other engine: {out.detail[:200]}")
            return EXIT_FATAL
    finally:
        ctx.stop_file.unlink(missing_ok=True)
        release_lock(ctx)
        signal.signal(signal.SIGINT, old)


# --------------------------------------------------------------------------------------------- commands

def cmd_start(ctx: Ctx, a: argparse.Namespace) -> int:
    if (rc := refuse_if_live(ctx)) is not None:
        return rc
    s = load_session(ctx)
    if s and s.get("status") not in ("ended", None) and not a.force_new:
        say(f"session {s['session_id'][:8]} is still open ({s['status']}). Use `continue`, or `end` it first "
            "(or pass --force-new to discard it).")
        return EXIT_USAGE
    agent = a.agent or ctx.cfg["primary"]
    if agent not in ctx.agents():
        say(f"unknown engine {agent}")
        return EXIT_USAGE
    s = {"session_id": str(uuid.uuid4()), "goal": a.goal, "status": "starting", "started_at": iso(now()),
         "branch": git(ctx.root, "rev-parse", "--abbrev-ref", "HEAD"),
         "start_commit": git(ctx.root, "rev-parse", "HEAD"), "agent_sessions": {}, "cooldowns": {},
         "failovers": 0, "runs": [], "checkpoints": []}
    ctx.state.mkdir(parents=True, exist_ok=True)
    for p in (ctx.handoff,):
        p.unlink(missing_ok=True)
    atomic_write(ctx.progress, PROGRESS_TEMPLATE.format(goal=a.goal))
    save_session(ctx, s)
    say(f"session {s['session_id'][:8]} started on branch {s['branch']}")
    return orchestrate(ctx, s, agent, "fresh", a.message, a.cycles)


def cmd_continue(ctx: Ctx, a: argparse.Namespace) -> int:
    if (rc := refuse_if_live(ctx)) is not None:
        return rc
    s = load_session(ctx)
    if not s or s.get("status") == "ended":
        say("no open session: use `start --goal ...`")
        return EXIT_USAGE
    last = (s.get("runs") or [{}])[-1]
    preferred = a.agent or s.get("active_agent") or ctx.cfg["primary"]
    agent = a.agent if a.agent and available(s, a.agent) else pick_agent(ctx, s, preferred)
    if agent is None:
        say("both engines are cooling down: " + ", ".join(f"{x} until {iso(cooldown_until(s, x))}"
                                                           for x in ctx.agents()) + ". Use `recover --wait`.")
        return EXIT_BOTH_LIMITED
    if a.agent and agent != a.agent:
        say(f"{a.agent} is cooling down until {iso(cooldown_until(s, a.agent))}; using {agent}")
    same = agent == last.get("agent") and last.get("outcome") in ("stopped", "completed", "transient")
    mode = "resume" if same and s.get("agent_sessions", {}).get(agent) else "handoff"
    if mode == "handoff" and not ctx.handoff.exists():
        compile_handoff(ctx, s, "continue", last.get("agent"), agent)
    s["failovers"] = 0
    return orchestrate(ctx, s, agent, mode, a.message, a.cycles)


def stop_orphan(ctx: Ctx, lk: dict) -> int:
    """The orchestrator died but its engine runs on: kill the engine tree, then checkpoint and hand off."""
    say(f"the orchestrator (pid {lk.get('pid')}) is gone; killing its orphaned {lk.get('agent')} engine "
        f"(pid {lk.get('engine_pid')})")
    kill_pid_tree(int(lk["engine_pid"]))
    ctx.lock_file.unlink(missing_ok=True)
    ctx.stop_file.unlink(missing_ok=True)
    s = load_session(ctx)
    if s:
        s["status"] = "stopped"
        ref = checkpoint(ctx, s, "orphan-stopped")
        compile_handoff(ctx, s, "stopped (orphaned engine killed)", lk.get("agent"), None, checkpoint_ref=ref)
        save_session(ctx, s)
    say("stopped; `continue` resumes from the handoff")
    return EXIT_OK


def cmd_stop(ctx: Ctx, a: argparse.Namespace) -> int:
    lk = live_run(ctx)
    if not lk:
        say("no run is active" + (" (the lock is stale: run `recover`)" if ctx.lock_file.exists() else ""))
        return EXIT_OK
    if not lk["orchestrator_alive"]:
        return stop_orphan(ctx, lk)
    ctx.stop_file.write_text(iso(now()) or "", encoding="utf-8")
    say(f"stop requested for {lk.get('agent')} (orchestrator pid {lk['pid']})")
    if a.no_wait:
        return EXIT_OK
    deadline = time.time() + a.timeout
    while time.time() < deadline:
        if not ctx.lock_file.exists():
            s = load_session(ctx) or {}
            say(f"stopped cleanly; status={s.get('status')}; handoff at {ctx.handoff.relative_to(ctx.root)}")
            return EXIT_OK
        time.sleep(0.5)
    say("the run did not stop in time; run `recover` (it will clear the lock once the process is gone)")
    return EXIT_FATAL


def cmd_status(ctx: Ctx, a: argparse.Namespace) -> int:
    s = load_session(ctx)
    lk = read_lock(ctx)
    if a.json:
        print(json.dumps({"session": s, "lock": lk, "ledger": ledger(ctx)}, indent=2))
        return EXIT_OK
    if not s:
        say("no session yet: `start --goal ...`")
        return EXIT_OK
    lg = ledger(ctx)
    live = live_run(ctx)
    alive = bool(live)
    if live and not live["orchestrator_alive"]:
        print("WARNING   the orchestrator is gone but its engine is still running: `stop` or `recover --kill`")
    print(f"session   {s['session_id']}  ({s['status']})\ngoal      {s['goal']}\nbranch    {s.get('branch')}"
          f"\nactive    {s.get('active_agent')}  running={alive}{'  STALE LOCK' if lk and not alive else ''}")
    for ag in ctx.agents():
        cu = cooldown_until(s, ag)
        print(f"{ag:<9} session={s.get('agent_sessions', {}).get(ag) or '-'}  "
              f"{'cooling down until ' + iso(cu) if cu else 'available'}")
    print(f"tasks     {len(lg['done'])} done, {len(lg['todo'])} open; blockers {len(lg['blockers'])}"
          f"{'; ledger says Status: done' if lg['goal_done'] else ''}")
    print(f"runs      {len(s.get('runs', []))}; failovers {s.get('failovers', 0)}; "
          f"checkpoints {len(s.get('checkpoints', []))}")
    return EXIT_OK


def cmd_handoff(ctx: Ctx, a: argparse.Namespace) -> int:
    s = load_session(ctx)
    if not s:
        say("no session")
        return EXIT_USAGE
    ref = checkpoint(ctx, s, "manual")
    p = compile_handoff(ctx, s, "manual", s.get("active_agent"), None, checkpoint_ref=ref)
    save_session(ctx, s)
    say(f"wrote {p.relative_to(ctx.root)}")
    return EXIT_OK


def cmd_recover(ctx: Ctx, a: argparse.Namespace) -> int:
    fixes = 0
    ctx.state.mkdir(parents=True, exist_ok=True)
    # 1. session.json readable?
    try:
        s = load_session(ctx)
    except json.JSONDecodeError:
        bak = ctx.session_file.with_suffix(".json.bak")
        if bak.exists():
            shutil.copyfile(bak, ctx.session_file)
            s = load_session(ctx)
            say("session.json was corrupt: restored the last backup")
            fixes += 1
        else:
            say("session.json is corrupt and there is no backup; `start --force-new` to begin again")
            return EXIT_FATAL
    # 2. lock and stop file
    live = live_run(ctx)
    if live and live["orchestrator_alive"]:
        say(f"a run is alive (orchestrator pid {live['pid']}); `stop` it first")
        return EXIT_LOCKED
    if live:
        if not a.kill:
            say(f"the orchestrator is gone but its {live.get('agent')} engine (pid {live.get('engine_pid')}) is "
                "still editing files; `recover --kill` (or `stop`) ends it first")
            return EXIT_LOCKED
        kill_pid_tree(int(live["engine_pid"]))
        say(f"killed the orphaned engine (pid {live['engine_pid']})")
        fixes += 1
    lk = read_lock(ctx)
    if lk:
        ctx.lock_file.unlink(missing_ok=True)
        say("removed a stale lock")
        fixes += 1
    if ctx.stop_file.exists():
        ctx.stop_file.unlink()
        say("removed a leftover STOP file")
        fixes += 1
    if not s:
        say("no session to recover")
        return EXIT_OK
    # 3. state vs git
    if s.get("status") in ("running", "starting"):
        s["status"] = "stopped"
        say("the session said running but nothing is: marked it stopped")
        fixes += 1
    branch = git(ctx.root, "rev-parse", "--abbrev-ref", "HEAD")
    if branch != s.get("branch"):
        say(f"branch changed: session started on {s.get('branch')}, now on {branch}"
            + (" (accepted)" if a.accept_branch else " (pass --accept-branch to keep working here)"))
        if a.accept_branch:
            s["branch"] = branch
            fixes += 1
    start = s.get("start_commit")
    if start and subprocess.run(["git", "merge-base", "--is-ancestor", start, "HEAD"], cwd=ctx.root).returncode:
        say(f"warning: HEAD no longer contains the session start commit {start[:8]} (history was rewritten?)")
    if not ctx.progress.exists():
        atomic_write(ctx.progress, PROGRESS_TEMPLATE.format(goal=s["goal"]))
        say("progress.md was missing: recreated it from the template")
        fixes += 1
    # 4. restore files from a checkpoint
    if a.restore:
        ref = a.restore if a.restore.startswith("refs/") else next(
            (c["ref"] for c in s.get("checkpoints", []) if a.restore in (c["ref"], c["commit"][:len(a.restore)])),
            a.restore)
        git(ctx.root, "restore", f"--source={ref}", "--worktree", "--", ".")
        say(f"restored tracked files in the working tree from {ref} (files created later are kept)")
        fixes += 1
    # 5. cooldowns
    if a.clear_cooldowns:
        s["cooldowns"] = {}
        say("cleared all cooldowns")
        fixes += 1
    save_session(ctx, s)
    cools = {ag: cooldown_until(s, ag) for ag in ctx.agents()}
    if all(cools.values()):
        soonest = min(cools.values())
        say("both engines are cooling down: " + ", ".join(f"{k} until {iso(v)}" for k, v in cools.items()))
        if not a.wait:
            say("`recover --wait` sleeps until the earliest reset and continues; or work by hand from "
                f"{ctx.handoff.relative_to(ctx.root)}")
            return EXIT_BOTH_LIMITED
        secs = max(0, (soonest - now()).total_seconds()) + 30
        say(f"waiting {int(secs)}s for the earliest reset (Ctrl+C to cancel)")
        time.sleep(secs)
    say(f"recover finished: {fixes} fix(es); status={s['status']}")
    if a.wait or a.then_continue:
        return cmd_continue(ctx, argparse.Namespace(agent=None, message=None, cycles=a.cycles))
    return EXIT_OK


def cmd_end(ctx: Ctx, a: argparse.Namespace) -> int:
    s = load_session(ctx)
    if not s or s.get("status") == "ended":
        say("no open session")
        return EXIT_USAGE
    if live_run(ctx):
        say("a run is still active: `stop` it first")
        return EXIT_LOCKED
    lg = ledger(ctx)
    if lg["todo"] and not a.force:
        say(f"{len(lg['todo'])} task(s) are still open in progress.md; finish them or pass --force")
        return EXIT_USAGE
    ref = checkpoint(ctx, s, "end")
    compile_handoff(ctx, s, "session ended", s.get("active_agent"), None, checkpoint_ref=ref)
    start, started = s.get("start_commit"), parse_iso(s.get("started_at"))
    stat = git(ctx.root, "diff", "--stat", start) if start else ""
    runs = s.get("runs", [])
    rows = "\n".join(f"| {r.get('started_at')} | {r['agent']} | {r.get('mode')} | {r.get('outcome', '?')} | "
                     f"{(r.get('detail') or '').replace('|', '/')[:80]} |" for r in runs)
    per = {ag: sum(1 for r in runs if r["agent"] == ag) for ag in ctx.agents()}
    summary = f"""# Session summary

- **Session:** `{s['session_id']}`
- **Goal:** {s['goal']}
- **Branch:** `{s.get('branch')}` (started at `{(start or '?')[:8]}`, ended at `{git(ctx.root, 'rev-parse', '--short', 'HEAD')}`)
- **Duration:** {started and str(now() - started)} ({s.get('started_at')} to {iso(now())})
- **Runs:** {len(runs)} ({', '.join(f'{k} {v}' for k, v in per.items())}); handoffs {len(list(ctx.handoffs.glob('*.md'))) if ctx.handoffs.exists() else 0}
- **Final checkpoint:** `{ref}`

## Completed tasks
{chr(10).join('- ' + x for x in lg['done']) or '- none'}

## Still open
{chr(10).join('- ' + x for x in lg['todo']) or '- none'}

## Blockers left
{chr(10).join(lg['blockers']) or '- none'}

## Files changed in the session
```
{stat or '(no tracked changes)'}
```

## Runs
| Started | Engine | Mode | Outcome | Detail |
|---|---|---|---|---|
{rows}

## Log
{chr(10).join(lg['log']) or '- none'}
"""
    arch = ctx.sessions / f"{stamp()}-{s['session_id'][:8]}"
    arch.mkdir(parents=True, exist_ok=True)
    (arch / "SUMMARY.md").write_text(summary, encoding="utf-8")
    for p in (ctx.progress, ctx.handoff):
        if p.exists():
            shutil.move(str(p), arch / p.name)
    for d in (ctx.handoffs, ctx.runs):
        if d.exists():
            shutil.move(str(d), arch / d.name)
    s["status"], s["ended_at"] = "ended", iso(now())
    save_session(ctx, s)
    shutil.copyfile(ctx.session_file, arch / "session.json")
    if a.prune_checkpoints:
        for c in s.get("checkpoints", []):
            git(ctx.root, "update-ref", "-d", c["ref"], check=False)
        say("deleted this session's checkpoint refs")
    print(summary)
    say(f"session ended; summary at {(arch / 'SUMMARY.md').relative_to(ctx.root)}")
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="agentctl", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("start", help="start a new session with the primary engine")
    st.add_argument("--goal", required=True)
    st.add_argument("--agent", choices=None)
    st.add_argument("--message", help="extra note for the first prompt")
    st.add_argument("--cycles", type=int, default=1, help="engine runs to chain while the goal is not done")
    st.add_argument("--force-new", action="store_true", help="discard an open session")
    co = sub.add_parser("continue", help="continue the open session (resume or hand off)")
    co.add_argument("--agent")
    co.add_argument("--message")
    co.add_argument("--cycles", type=int, default=1)
    sp = sub.add_parser("stop", help="stop the active run gracefully (checkpoint + handoff)")
    sp.add_argument("--no-wait", action="store_true")
    sp.add_argument("--timeout", type=float, default=120)
    ss = sub.add_parser("status", help="show the session, engines and ledger")
    ss.add_argument("--json", action="store_true")
    sub.add_parser("handoff", help="checkpoint and write HANDOFF.md now")
    rc = sub.add_parser("recover", help="repair state, clear stale locks, wait out limits")
    rc.add_argument("--wait", action="store_true", help="sleep until the earliest reset, then continue")
    rc.add_argument("--then-continue", action="store_true", help="continue right after repairing")
    rc.add_argument("--clear-cooldowns", action="store_true")
    rc.add_argument("--kill", action="store_true", help="kill an engine whose orchestrator died")
    rc.add_argument("--accept-branch", action="store_true")
    rc.add_argument("--restore", metavar="CHECKPOINT", help="restore tracked files from a checkpoint ref/commit")
    rc.add_argument("--cycles", type=int, default=1)
    en = sub.add_parser("end", help="end the session and write the summary")
    en.add_argument("--force", action="store_true", help="end even with open tasks")
    en.add_argument("--prune-checkpoints", action="store_true")
    a = p.parse_args(argv)
    ctx = Ctx()
    return {"start": cmd_start, "continue": cmd_continue, "stop": cmd_stop, "status": cmd_status,
            "handoff": cmd_handoff, "recover": cmd_recover, "end": cmd_end}[a.cmd](ctx, a)


if __name__ == "__main__":
    sys.exit(main())
