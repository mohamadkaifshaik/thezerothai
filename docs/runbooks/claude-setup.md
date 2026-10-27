# Claude Code team setup: commands, guardrails and one-time steps

The architecture and rules live in `CLAUDE.md`; this runbook holds the parts that are about the tooling around it. It replaces
`README-CLAUDE-SETUP.md` (retired 2026-10-25). Run `claude` in the repo root; `/agents` lists the team and `/` the commands.
Hooks need `jq` (they block edits without it). Local dev needs the Firebase CLI (`npx firebase-tools`), Go 1.26, Flutter 3.47.x and Java 21 for the emulators.
Several agents often run emulator suites on one machine: `make emulators`, `make test-int` and `make dev` give each run a private temp directory (`scripts/with-private-tmp.sh`), and a raw `firebase emulators:*` call must be wrapped the same way; see `docs/runbooks/emulator-collisions.md`.

## Commands (`.claude/commands`)

| Command             | What it does                                                                         |
| ------------------- | ------------------------------------------------------------------------------------ |
| `/plan <feature>`   | planner (+ architect) writes `docs/plans/...` with a cost section                    |
| `/ship <feature>`   | plan, build, test, review, cost check, candidate revision, gate, traffic shift       |
| `/review`           | code-reviewer + security-auditor + tester in parallel on your diff                   |
| `/release vX.Y.Z`   | candidate revision (0% traffic), GO/NO-GO, 10%, 100% (see ADR-0019 for the approvals) |
| `/cost-check [DAU]` | free-quota headroom, projected bill, scale-up triggers                               |
| `/bootstrap`        | one-time Phase 0 scaffold; finished, kept for reference                              |

Skills are in `.claude/skills/` (the directory is the list; do not copy it into docs).

## Guardrails (`.claude/settings.json` and `.claude/hooks`)

- `cost-guard` blocks Terraform for GKE, Spanner, Redis, Cloud SQL, VMs, load balancers, Cloud Armor, NAT, KMS keys, Cloud Deploy,
  Vertex search and `min_instance_count` above 0, unless the line says `# cost-approved: ADR-NNNN`. In credit mode (ADR-0022) the form
  `# cost-approved: ADR-NNNN until:YYYY-MM-DD` is accepted up to and including that date (UTC).
- `gcloud` create commands for those services are denied; deploys, traffic changes, `terraform apply`, `firebase deploy` and `git push` ask first.
- `terraform destroy`, force-push, project deletion and unlinking billing are blocked.
- Generated code and secret files cannot be edited, including via shell redirects (`bash-guard`). Go, Dart, Terraform and proto files are auto-formatted after each edit.
- `commit-gate` runs `gofmt`, `go vet` and `flutter analyze` before `git commit`; guard hooks fail closed if `jq` is missing.
- Repository gates (rulesets, CODEOWNERS, the `prod` environment reviewer) are described in `CLAUDE.md` and ADR-0019.

## One-time manual steps (not automatable for free)

1. Create a billing account (needed even for the free tier) and set a budget alert; Terraform does the rest after the first apply.
2. Create two projects (`dzeroth-dev`, `dzeroth-prod`) and add Firebase to each.
3. Decide the Firestore region (`asia-south1` by default; it can never be changed).
4. Apple Developer Program and Google Play Console fees are outside GCP and not covered by any free tier.

More detail: `docs/runbooks/cloud-bootstrap.md`.
