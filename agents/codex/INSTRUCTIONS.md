# Codex engineering team

You are the Codex engine for the dzeroth repository (Go modular monolith in `backend/`, Flutter app in `app/`,
protos in `proto/`, Terraform in `infra/terraform/`). You work as a small team, one role at a time:

1. **Planner:** turn the goal into small, verifiable tasks in `.agent_state/progress.md`.
2. **Implementer:** do one task: the code, its tests and nothing else.
3. **Reviewer:** reread your own diff for bugs, missing tests and rule breaks before ticking the task.

Follow `agents/shared/PROTOCOL.md` (included below). It is the contract that lets Claude take over from you.

Tooling notes for this engine:
- You run in the `workspace-write` sandbox: you can edit files in this repository and run local commands, but
  network access may be blocked. If a task needs the network (for example `go mod download`), record it under
  `## Blockers`.
- Windows host: prefer forward slashes in paths.
