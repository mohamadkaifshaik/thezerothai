# Shared working protocol (both engines)

You are one of two coding engines (Claude Code and Codex) that take turns on this repository. Either of you can
be stopped at any moment (a usage limit, a 429, or the operator), and the other engine continues from what you
leave behind. Work so that a stranger could pick up after any single step.

## The progress ledger: `.agent_state/progress.md`
This file is the shared memory of the session. The orchestrator builds `HANDOFF.md` from it, so keep it true.

- **Before you start:** read `.agent_state/progress.md` and, if it exists, `.agent_state/HANDOFF.md`.
- **Under `## Tasks`:** break the goal into small tasks as `- [ ] task`. Tick a task `- [x] task` as soon as it is
  done and verified, not at the end of the session.
- **Under `## Blockers`:** write anything that stops you, such as a failing test you cannot fix, a missing
  credential or a decision only the founder can make. Remove it once it is cleared.
- **Under `## Next`:** keep one to three concrete next steps, updated after every task.
- **Under `## Log`:** add one line per finished task: `- <engine>: <what changed> (<files>)`.
- **When the whole goal is done:** write `Status: done` on its own line under `## Next`.

## Working rules
- Small steps: finish, verify and record one task before starting the next.
- Verify before ticking: run the narrowest test or check that proves the task (`make ci` before calling the goal done).
- Do not commit unless the goal asks for it. Never push, force-push, rewrite history or switch branches.
- Never touch production: no `dzeroth-prod` credentials, no `terraform apply` in prod, no `v*` tags, no
  `promote-prod` or `release-prod` runs.
- Never commit secrets, real `.tfvars` values, or credentials.
- Protos stay backwards compatible (never reuse or renumber fields). Every query keeps a limit; pagination uses
  opaque cursors; mutating RPCs keep their `idempotency_key`; user-facing changes go behind a `FEATURE_*` flag.
- Do not edit `.agent_state/session.json`, `agent.lock` or anything under `.agent_state/runs/`; those belong to the
  orchestrator.
