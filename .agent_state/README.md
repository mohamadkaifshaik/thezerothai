# .agent_state

Shared session memory for the Claude and Codex engines, written by `agents/orchestrator/agentctl.py`. Everything
here except this README is git-ignored: it is local runtime state, and the code itself is protected by checkpoint
refs (`refs/agent-checkpoints/...`), which include `progress.md` and `HANDOFF.md`.

| Path | Written by | What it is |
|---|---|---|
| `session.json` (+ `.bak`) | orchestrator | goal, status, active engine, native session ids, cooldowns, runs, checkpoints |
| `progress.md` | the engines | the ledger: Tasks, Blockers, Next, Log (see `agents/shared/PROTOCOL.md`) |
| `HANDOFF.md` | orchestrator | the latest handoff, built from git and the ledger |
| `handoffs/` | orchestrator | every handoff of the session |
| `runs/<time>-<engine>/` | orchestrator | prompt, JSONL transcript, stderr and last messages of each run |
| `agent.lock` | orchestrator | the live run (pid, engine); `recover` clears it when stale |
| `STOP` | `agentctl stop` | asks the live run to stop gracefully |
| `sessions/<time>-<id>/` | `agentctl end` | the archive of an ended session, with `SUMMARY.md` |
