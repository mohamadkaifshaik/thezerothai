# Dual-agent operations guide (Claude Code + Codex)

This repository can be worked on by two coding engines, **Claude Code** and **OpenAI Codex**, taking turns under
one orchestrator: `agents/orchestrator/agentctl.py`. If the engine that is running hits a usage limit, a credit
limit or an HTTP 429, the orchestrator:

1. stops it,
2. snapshots the working tree into a checkpoint ref,
3. writes `.agent_state/HANDOFF.md` (completed tasks, modified files, blockers, next steps),
4. puts that engine in a cooldown until its limit resets, and
5. starts the other engine with the handoff as its first context.

Only one engine runs at a time, and both work in the same checkout and on the same branch, so nothing has to be
merged between them.

```
          agentctl start / continue
                    |
        +-----------v------------+      watches the engine's JSON events (not file contents)
        |  orchestrator (Python) |-----> limit?      -> checkpoint + HANDOFF.md + cooldown -> other engine
        |  lock, STOP, state     |-----> transient?  -> retry the same engine with backoff
        +-----------+------------+-----> fatal?      -> checkpoint + HANDOFF.md -> stop (both would fail)
                    | stdin prompt = engine instructions + shared protocol + goal (+ HANDOFF.md)
         +----------+-----------+
         v                      v
   claude -p (stream-json)   codex exec --json
         \                      /
          +----- same repo -----+---> .agent_state/progress.md (the shared ledger both engines keep)
```

## Contents
1. [Layout](#1-layout)
2. [One-time setup](#2-one-time-setup)
3. [Start the primary agent](#3-start-the-primary-agent)
4. [Stop a run safely](#4-stop-a-run-safely-no-data-loss)
5. [Continue a workflow](#5-continue-a-workflow)
6. [Recover](#6-recover)
7. [End and summarise a session](#7-end-and-summarise-the-session)
8. [How failover decides](#8-how-failover-decides)
9. [Configuration](#9-configuration)
10. [Exit codes](#10-exit-codes)
11. [Testing the orchestrator](#11-testing-the-orchestrator)
12. [Troubleshooting](#12-troubleshooting)

Every command below is given for **Git Bash** (also macOS and Linux) and **PowerShell**. Run them from the repository
root.

---

## 1. Layout

| Path | Purpose |
|---|---|
| `agents/claude/INSTRUCTIONS.md` | The Claude team's brief (planner, implementer, reviewer roles) |
| `agents/codex/INSTRUCTIONS.md` | The Codex team's brief |
| `agents/shared/PROTOCOL.md` | The contract both engines follow: the ledger, working rules, the "never" list |
| `agents/orchestrator.json` | Engine commands, permissions, failover limits and error patterns |
| `agents/orchestrator/agentctl.py` | The orchestrator (Python 3.9+, standard library only) |
| `agents/orchestrator/tests/` | End-to-end tests with fake engine CLIs |
| `agents/agentctl`, `agents/agentctl.ps1` | Short wrappers for Git Bash and PowerShell |
| `.agent_state/` | Shared session memory (git-ignored except its README); see `.agent_state/README.md` |

There is no root `CLAUDE.md` or `AGENTS.md`. Each engine's instructions are sent in its prompt, so neither engine
picks up the other's brief.

## 2. One-time setup

**Check the tools:**

```bash
# Git Bash
python --version          # 3.9 or newer
claude --version          # Claude Code
codex --version           # Codex CLI
git --version
```

```powershell
# PowerShell
python --version; claude --version; codex --version; git --version
```

**Sign in to both engines** (interactive, once per machine):

```bash
claude            # then type /login inside Claude Code, and /exit when done
codex login
```

**Smoke-test both engines** (costs a few cents):

```bash
# Git Bash
echo "Reply with exactly: OK" | claude -p --output-format stream-json --verbose | tail -1
echo "Reply with exactly: OK" | codex exec --json --sandbox read-only - | tail -1
```

```powershell
# PowerShell
"Reply with exactly: OK" | claude -p --output-format stream-json --verbose | Select-Object -Last 1
"Reply with exactly: OK" | codex exec --json --sandbox read-only - | Select-Object -Last 1
```

**Optional shortcut:** the wrappers save typing.

```bash
./agents/agentctl status                 # Git Bash
```

```powershell
.\agents\agentctl.ps1 status             # PowerShell
```

The rest of this guide spells out `python agents/orchestrator/agentctl.py`, which works in both shells.

**Use a branch, never `main`.** The engines work on whatever branch is checked out:

```bash
git switch -c feat/my-task origin/main
```

## 3. Start the primary agent

The primary engine is `"primary"` in `agents/orchestrator.json` (Claude by default).

```bash
# Git Bash
python agents/orchestrator/agentctl.py start --goal "Add a /health latency field to the API and test it"
```

```powershell
# PowerShell
python agents/orchestrator/agentctl.py start --goal "Add a /health latency field to the API and test it"
```

**Options:**
- `--agent codex` starts with Codex instead of the primary engine.
- `--message "..."` adds an operator note to the first prompt.
- `--cycles 3` chains up to three runs while the ledger does not say `Status: done`.
- `--force-new` throws away an open session, after you confirm it is not needed.

**What happens:**
1. `start` records the goal, branch and start commit in `.agent_state/session.json`.
2. It creates `.agent_state/progress.md` from a template.
3. It takes the run lock and starts the engine.
4. The engine plans the goal in the ledger and works through it.

**Watch it from a second terminal:**

```bash
python agents/orchestrator/agentctl.py status
tail -f .agent_state/progress.md                                   # Git Bash
```

```powershell
python agents/orchestrator/agentctl.py status
Get-Content .agent_state\progress.md -Wait                         # PowerShell
```

Each run keeps its prompt, raw JSONL transcript, stderr and last messages in `.agent_state/runs/<time>-<engine>/`.

## 4. Stop a run safely (no data loss)

**From another terminal** (recommended):

```bash
python agents/orchestrator/agentctl.py stop          # waits until the run has stopped (default 120 s)
python agents/orchestrator/agentctl.py stop --no-wait
```

**In the orchestrator's own terminal:** press **Ctrl+C** once. It runs the same graceful path. Press it only once;
the orchestrator needs a few seconds to finish.

**What a stop does, in order:**
1. `stop` drops a `.agent_state/STOP` file, which the orchestrator checks twice a second.
2. The orchestrator asks the engine to exit, waits `grace_seconds` (15), then ends the engine's whole process tree.
   On Windows that is `taskkill /T`, so the Node child of the `codex` shim does not linger.
3. It checkpoints the working tree into `refs/agent-checkpoints/<session>/<time>-stopped`. This captures tracked
   and untracked files plus `progress.md` and `HANDOFF.md`, and leaves your index, files and branch untouched.
4. It writes `.agent_state/HANDOFF.md`, sets the status to `stopped` and releases the lock.

**List the checkpoints:**

```bash
git for-each-ref --format="%(refname) %(objectname:short) %(creatordate:iso)" refs/agent-checkpoints
```

## 5. Continue a workflow

```bash
python agents/orchestrator/agentctl.py continue
python agents/orchestrator/agentctl.py continue --agent codex                  # choose the engine
python agents/orchestrator/agentctl.py continue --message "Skip the UI task"   # steer the next run
python agents/orchestrator/agentctl.py continue --cycles 3
```

**How `continue` chooses:**
- **Engine:** the one you name, or the last active one. An engine still cooling down is skipped in favour of the
  other, and you are told so.
- **Same engine as the last run, and that run ended cleanly** (completed, stopped or transient): it resumes the
  engine's native session (`claude --resume <id>` / `codex exec resume <id>`), so the engine keeps its own memory.
- **Otherwise** (a switch of engine, or after a failure): it starts a fresh session whose prompt is that engine's
  instructions, the shared protocol, the goal and `HANDOFF.md`.

**Seeing why it chose that:** `.agent_state/HANDOFF.md` is a plain report. Read it before continuing, especially
after a failover:

```bash
cat .agent_state/HANDOFF.md              # Git Bash
```

```powershell
Get-Content .agent_state\HANDOFF.md      # PowerShell
```

**Writing a fresh handoff at any time** (it also checkpoints):

```bash
python agents/orchestrator/agentctl.py handoff
```

## 6. Recover

Always start with a diagnosis:

```bash
python agents/orchestrator/agentctl.py status
python agents/orchestrator/agentctl.py recover
```

`recover` never starts an engine unless you ask it to. It:
- refuses while a run is alive, and tells you to `stop` it first;
- clears a stale `agent.lock` (its process is gone) and a leftover `STOP` file;
- restores `session.json` from `session.json.bak` if it is corrupt;
- marks a session that says `running` with no live process as `stopped`;
- reports a branch change since `start` (`--accept-branch` keeps working on the new branch);
- warns if `HEAD` no longer contains the session's start commit (history was rewritten);
- recreates a missing `progress.md`;
- reports both engines' cooldowns.

### 6a. Both APIs are limited (exit code 75)

The status is `both_limited`, and `HANDOFF.md` holds everything done so far.

```bash
python agents/orchestrator/agentctl.py status                 # shows "cooling down until ..." per engine
python agents/orchestrator/agentctl.py recover --wait         # sleeps until the earliest reset, then continues
```

**If you know a limit is already lifted** (for example, you added credit):

```bash
python agents/orchestrator/agentctl.py recover --clear-cooldowns --then-continue
```

**To keep working by hand meanwhile:**
1. Read `.agent_state/HANDOFF.md`.
2. Work from its Next steps, and tick what you finish in `.agent_state/progress.md`.
3. Run `continue` later; the next engine reads your ledger changes.

### 6b. State desynchronised

| Symptom | Fix |
|---|---|
| `continue` says another run holds the lock, but nothing is running | `agentctl.py recover` (clears the stale lock) |
| `session.json` is corrupt | `agentctl.py recover` (restores the backup) |
| You switched branches mid-session | `agentctl.py recover --accept-branch`, or `git switch <session branch>` |
| The engines keep redoing finished work | Edit `.agent_state/progress.md` so the Tasks, Next and Blockers are true, then `continue` |
| Files were damaged or deleted by a bad run | `agentctl.py recover --restore <checkpoint ref>` |

**Restoring a checkpoint** rewrites the files in your working tree from that checkpoint; files created later are
kept. Preview it first, and commit or back up anything you want to keep:

```bash
git for-each-ref --format="%(refname)" refs/agent-checkpoints | tail -5
git diff --stat refs/agent-checkpoints/<session>/<time>-stopped        # what would change
python agents/orchestrator/agentctl.py recover --restore refs/agent-checkpoints/<session>/<time>-stopped
```

### 6c. Starting over

`--force-new` discards the open session's state. Checkpoint refs are kept, and code changes stay in your working
tree.

```bash
python agents/orchestrator/agentctl.py start --force-new --goal "..."
```

## 7. End and summarise the session

```bash
python agents/orchestrator/agentctl.py end                          # refuses while ledger tasks are open
python agents/orchestrator/agentctl.py end --force                  # end anyway
python agents/orchestrator/agentctl.py end --prune-checkpoints      # also delete this session's checkpoint refs
```

**What `end` does:**
1. It refuses while a run is alive.
2. It takes a final checkpoint and handoff.
3. It writes a summary: goal, duration, runs per engine, completed and open tasks, blockers left, files changed
   since the start commit, a table of every run, and the log.
4. It moves `progress.md`, `HANDOFF.md`, `handoffs/` and `runs/` into
   `.agent_state/sessions/<time>-<id>/`, beside `SUMMARY.md`.
5. It marks the session `ended`, so the next `start` begins clean.

**Then commit the work yourself**, and open a PR as usual:

```bash
git status
git add -A && git commit -m "feat: ..."
git push -u origin HEAD
```

## 8. How failover decides

The orchestrator reads only **error-typed events, stderr and the exit code**, never the text of tool results.
This repository is full of the strings "429" and "rate limit" in code and tests, and an engine reading those files
must not trigger a failover.

| Engine | Session id | Limit signals | Error signals |
|---|---|---|---|
| Claude Code (`stream-json`) | `system/init.session_id` | `rate_limit_event` with `status: rejected` (exact `resetsAt`) | final `result` with `is_error: true` |
| Codex (`--json`) | `thread.started.thread_id` | `error` / `turn.failed` messages | `error` / `turn.failed` |

The error text is then matched against `patterns` in `agents/orchestrator.json`:

| Class | Examples | Action |
|---|---|---|
| **limit** | usage limit, 429, too many requests, credit balance too low, insufficient quota | Checkpoint, handoff, cool down until the reset time (parsed, else `default_cooldown_minutes`), start the other engine |
| **transient** | overloaded, 529, 502/503/504, connection reset, stream disconnected | Retry the same engine `transient_retries` times with `transient_backoff_seconds`, then treat it like a limit |
| **fatal** | invalid API key, not logged in, 401/403, unknown option, or any unexplained crash | Checkpoint, handoff, stop. The other engine is not started, because the same fault would likely stop it too |

**Two safeguards stop endless ping-pong:**
- `max_failovers` (default 4) caps failovers per `start` or `continue`.
- When neither engine is available, the run ends with exit code **75**, for `recover --wait`.

## 9. Configuration

Everything lives in `agents/orchestrator.json`:

| Key | Default | Meaning |
|---|---|---|
| `primary` | `claude` | The engine `start` uses |
| `max_failovers` | `4` | Cap per start or continue |
| `transient_retries`, `transient_backoff_seconds` | `2`, `[30, 120]` | Retries before a transient error counts as a failover |
| `default_cooldown_minutes` | `60` | Used when the limit message has no reset time |
| `grace_seconds` | `15` | How long an engine gets to exit before its process tree is killed |
| `agents.<engine>.command` / `resume_command` | see file | The exact CLI invocations; `{session_id}` is filled in on resume |
| `patterns.limit/transient/fatal` | see file | Case-insensitive regexes for the classification above |

**Permissions are deliberately conservative:**
- **Claude** runs with `--permission-mode acceptEdits` and an `--allowedTools` list: file tools, plus git
  read/stage/commit, `make`, `go`, `flutter`, `dart` and `buf`. Anything else is refused in non-interactive mode,
  and the engine records it as a blocker.
- **Codex** runs in the `workspace-write` sandbox: it edits this checkout, and network access may be blocked.

**Widening permissions:**
- Add entries to `--allowedTools`, or switch Codex to `--sandbox danger-full-access`.
- `bypassPermissions` and `--dangerously-bypass-approvals-and-sandbox` exist, but they remove every guard. Use them
  only in a disposable environment.

## 10. Exit codes

| Code | Meaning | Next step |
|---|---|---|
| 0 | The run finished (or the command succeeded) | `continue`, or `end` |
| 1 | Fatal engine error, or `stop` timed out | Read `HANDOFF.md` and the run's `stderr.log`, fix the cause, then `continue` |
| 2 | Usage error, or wrong session state | Read the message |
| 3 | Stopped by the operator | `continue` |
| 4 | Another run holds the lock | `status`, `stop`, or `recover` if the lock is stale |
| 75 | Both engines limited, or the failover cap was hit | `recover --wait`, or work from `HANDOFF.md` |

## 11. Testing the orchestrator

The tests run fake `claude` and `codex` CLIs in a throwaway git repository. They spend no API credit and need no
sign-in.

```bash
python -m unittest discover -s agents/orchestrator/tests -v
```

**They cover:**
- tool output that merely contains "429" (no failover);
- a real limit (failover, with the handoff in the new engine's prompt);
- both engines limited (exit 75, then recovery);
- a fatal error (no failover);
- a transient error (retry on the same engine);
- a stop of a hung run (no orphaned process), then `continue` resuming the native session;
- a stale lock and a corrupt `session.json` (`recover` repairs both);
- checkpoints leaving the index and working tree untouched;
- `end` and its summary.

The main `make ci` does not run these tests. Run them after changing the orchestrator.

## 12. Troubleshooting

- **`claude` or `codex` is not on PATH (fatal).** Install the CLI, or set an absolute path as the first element of
  `command` in `agents/orchestrator.json`.
- **An engine fails at once with "not logged in".** Sign in again (section 2). The run is classified fatal, so the
  other engine is not woken up for a credentials problem.
- **The engine keeps asking for a tool it is not allowed.** Add it to `--allowedTools` (Claude), or accept the
  blocker and do that step by hand.
- **A new CLI version changes its error wording.** Add the new phrase to `patterns` in `agents/orchestrator.json`,
  then rerun the tests.
- **A dev deploy started after merging changes under `agents/`.** `deploy-dev` ignores only `*.md` and `docs/**`,
  so a change to `agents/**` code deploys dev. It is harmless, but expected.
- **You need to see what an engine really did.** Open `.agent_state/runs/<time>-<engine>/transcript.jsonl`. Every
  event is there, one JSON object per line.
