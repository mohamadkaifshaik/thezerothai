# Claude Code team setup — free-tier edition

Same 10-agent team, re-targeted from a 50M-DAU design (GKE, Spanner, Redis, global LB, 3 envs) to a
**GCP Always Free + Firebase** architecture that costs $0 idle and grows pay-per-use. See `docs/adr/0001-free-tier-first-architecture.md`.

## Install

Copy everything in this folder into the root of your repo:

```
unzip dzeroth-lean.zip -d your-repo/   # CLAUDE.md, .claude/, docs/, .gitignore
cd your-repo && claude
```

Check it's loaded: `/agents` shows the 10 team members, `/` shows the commands.
Hooks need `jq` (`brew install jq` / `apt install jq`). Local dev needs the Firebase CLI (`npm i -g firebase-tools`) and Java 11+ for the emulators.

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
ship-feature, mvp-roadmap, adr

## Guardrails

- `cost-guard` hook blocks Terraform for GKE, Spanner, Redis, Cloud SQL, VMs, load balancers, Cloud Armor, NAT, KMS keys,
  Cloud Deploy, Vertex search and Cloud Run `min_instance_count > 0` — unless the line says `# cost-approved: ADR-NNNN`.
- `gcloud` create commands for those services are denied; deploys, traffic changes, `terraform apply`, `firebase deploy` ask first.
- `terraform destroy`, force-push, project deletion and unlinking billing are blocked.
- Claude can't edit generated code or secret files. Go/Dart/TF/proto files are auto-formatted after each edit.

## One-time manual steps (not automatable for free)

1. Create a billing account (needed even for free tier) and **set a budget alert** — Terraform does this after the first apply.
2. Create two projects (`dzeroth-dev`, `dzeroth-prod`) and add Firebase to each.
3. Decide the Firestore region (default `asia-south1`; it can never be changed).
4. Apple Developer Program and Google Play Console fees are outside GCP and not covered by any free tier.

## Suggested first session

1. `/bootstrap`
2. `/ship user profiles and follow graph`
3. `/ship create text post with up to 4 images`
4. `/ship home timeline`
5. `/cost-check 300`
