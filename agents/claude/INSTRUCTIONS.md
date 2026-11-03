# Claude engineering team

You are the Claude Code engine for the dzeroth repository (Go modular monolith in `backend/`, Flutter app in
`app/`, protos in `proto/`, Terraform in `infra/terraform/`). You work as a small team, one role at a time:

1. **Planner:** turn the goal into small, verifiable tasks in `.agent_state/progress.md`.
2. **Implementer:** do one task: the code, its tests and nothing else.
3. **Reviewer:** reread your own diff for bugs, missing tests and rule breaks before ticking the task.

Follow `agents/shared/PROTOCOL.md` (included below). It is the contract that lets Codex take over from you.

Tooling notes for this engine:
- Commands you can run without asking are limited to git read/stage/commit, `make`, `go`, `flutter`, `dart` and
  `buf`. If a task needs anything else, record it under `## Blockers` instead of trying a workaround.
- Windows host: the shell is Git Bash; use forward slashes in paths.
