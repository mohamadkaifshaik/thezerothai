# AGENTS.md

Instructions for coding agents (Codex and others) working in this repo. Read this first, then
`docs/adr/0033-architecture-reset.md`.

## Direction
The project is moving from a free-tier-first design to the architecture in ADR-0033: Postgres (Cloud SQL) as the
system of record for relational modules, a shared Redis cache, a hybrid fan-out timeline and Postgres search.
Where ADR-0033 conflicts with an older ADR or with the cost rules in `CLAUDE.md`, ADR-0033 wins. Everything else in
`CLAUDE.md` still applies.

## Rules that still hold
1. **Protos stay backwards compatible.** Never reuse or renumber fields; `buf breaking` must pass.
2. **Every query has a limit** (default 20, max 50) and pagination uses opaque cursors, never offsets.
3. **Every mutating RPC keeps its `idempotency_key`.**
4. **User-facing changes ship behind a server flag** (`FEATURE_<NAME>`). Register new flags and their ceilings
   (`scripts/promotion/`).
5. **Right to delete:** every new table or collection is covered by the account eraser and export.
6. **No N+1.** Batch reads; document worst-case reads/writes per RPC in the code comment.
7. **No storage types in a module's public interface** (`api.go`). Transactions go through
   `backend/pkg/platform/store`.
8. **Modules call each other only through their Go interfaces.**
9. **Reuse first:** search `docs/code-map.md` (backend) and `docs/ui-catalog.md` (Flutter) before writing a helper;
   add new shared helpers to them.
10. **Terraform** for every cloud resource; fixed-cost resources carry `# cost-approved: ADR-0033`.

## Never
- Touch prod: no `dzeroth-prod` credentials, no `terraform apply` in prod, no `v*` tags, no `promote-prod`.
- Push to `main`, force-push, or rewrite history. Merge `origin/main` into your branch instead.
- Edit gate files without saying so in the PR: `.github/workflows/*`, `.github/CODEOWNERS`,
  `scripts/promotion/flag-ceiling.json`, `firebase/firestore.indexes.json`, `firebase/field-overrides.ack`,
  `scripts/mint-app-token.sh`.
- Commit secrets, `.tfvars` with real values, or generated credentials.
- Use bare `git stash` in a shared checkout.

## Workflow
- One task per branch: `refactor/<phase>-<slug>` (e.g. `refactor/1-graph-seam`), in its own git worktree under
  `.claude/worktrees/`.
- Small reviewable PRs: one module per PR for seam and migration work.
- No behaviour change unless the task says so; behaviour changes go behind a flag.
- Done means all of:
  - `make ci` passes (lint, vet, unit tests, `buf breaking`, flutter analyze/test).
  - `make test-int` passes (emulators; plus Postgres/Redis containers once they exist).
  - Go coverage on `backend/internal/` stays at or above 70%.
  - The ticket's plan file (`docs/plans/refactor.md`) has its status updated.
- Finish by printing: files changed, what was tested and how, anything skipped or still failing, and open questions.

## Commands
```
make proto        # buf lint + breaking + generate (Go + Dart)
make ci           # full local CI
make emulators    # Firebase emulators
make test-int     # integration tests against emulators
```

## Layout
- `backend/cmd/api`: the monolith entrypoint. `backend/internal/<module>`: one module each, `api.go` is its public
  interface, `repo_*.go` its storage. `backend/pkg/platform`: shared infrastructure.
- `proto/`: Connect-RPC contracts. `app/lib/features/<feature>`: Flutter features (data/domain/presentation).
- `infra/terraform/{envs,modules}`: infrastructure. `docs/adr/`: decisions. `docs/plans/`: plans and ticket status.
