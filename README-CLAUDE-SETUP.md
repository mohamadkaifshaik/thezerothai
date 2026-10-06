# Claude Code team setup — free-tier edition

Same 10-agent team, re-targeted from a 50M-DAU design (GKE, Spanner, Redis, global LB, 3 envs) to a
**GCP Always Free + Firebase** architecture that costs $0 idle and grows pay-per-use. See `docs/adr/0001-free-tier-first-architecture.md`.

## Using it

This setup is committed in the repo (`CLAUDE.md`, `.claude/`, `docs/`). Run `claude` in the repo root;
`/agents` shows the 10 team members and `/` the commands. Hooks need `jq` (they block edits without it).
Local dev needs the Firebase CLI (`npx firebase-tools`), Go 1.26, Flutter 3.47.x and Java 21 for the emulators.

## Architecture in one line

Flutter → Firebase Auth + App Check → Cloud Run (Go monolith, scale to zero, max 3) → Firestore + GCS (signed uploads) + Pub/Sub push;
web on Firebase Hosting; FCM, Crashlytics, budget alerts.

## The team (.claude/agents)

architect · planner · backend-developer · frontend-developer · tester ·
code-reviewer · security-auditor · sre-performance (cost + perf) · production-deployer · production-reviewer

## Commands (.claude/commands)

| Command             | What it does                                                                                                      |
| ------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `/bootstrap`        | Scaffolds Phase 0: ADRs, protos, Go monolith, Flutter shell, Firebase config, Terraform (dev + prod, budgets), CI |
| `/plan <feature>`   | planner (+ architect) → `docs/plans/…` with a cost section                                                        |
| `/ship <feature>`   | plan → build → test → review → cost check → rc revision → gate → traffic shift                                    |
| `/review`           | code-reviewer + security-auditor + tester in parallel on your diff                                                |
| `/release vX.Y.Z`   | rc revision (0% traffic) → GO/NO-GO → 10% → 100%                                                                  |
| `/cost-check [DAU]` | free-quota headroom, projected bill, scale-up triggers                                                            |

## Skills (.claude/skills)

free-tier-budget, firestore-data-model, timeline, go-service, media-pipeline, flutter-feature, gcp-terraform,
observability, load-testing, testing-strategy, release-rollout, security-checklist, production-readiness,
ship-feature, mvp-roadmap, adr, reuse-first, flag-rollout, pr-workflow

## Guardrails

- `cost-guard` hook blocks Terraform for GKE, Spanner, Redis, Cloud SQL, VMs, load balancers, Cloud Armor, NAT, KMS keys,
  Cloud Deploy, Vertex search and Cloud Run `min_instance_count > 0` — unless the line says `# cost-approved: ADR-NNNN`.
- `gcloud` create commands for those services are denied; deploys, traffic changes, `terraform apply`, `firebase deploy` ask first.
- `terraform destroy`, force-push, project deletion and unlinking billing are blocked.
- Claude can't edit generated code or secret files, including via shell redirects (`bash-guard`). Go/Dart/TF/proto files are auto-formatted after each edit.
- `commit-gate` runs `gofmt`/`go vet`/`flutter analyze` before `git commit`; guard hooks fail closed if `jq` is missing.

## One-time manual steps (not automatable for free)

1. Create a billing account (needed even for free tier) and **set a budget alert** — Terraform does this after the first apply.
2. Create two projects (`dzeroth-dev`, `dzeroth-prod`) and add Firebase to each.
3. Decide the Firestore region (default `asia-south1`; it can never be changed).
4. Apple Developer Program and Google Play Console fees are outside GCP and not covered by any free tier.

## Where we are

Phase 0 is done and Phase 1 is underway; see `docs/plans/phase1.md` for the current slice status.
