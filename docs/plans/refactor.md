# Refactor plan (ADR-0033)

Decision: `docs/adr/0033-architecture-reset.md`. Agents: read `AGENTS.md`. One ticket per PR, branch
`refactor/<phase>-<slug>`. Status values: Todo, In progress, In review, Done, Blocked.

Cost line: phase 1 adds no cost. Phases 2–3 add the fixed floor in ADR-0033 "Cost impact" (dev first, prod only
after the founder approves the prod plan). Phase 6 adds the LB/CDN/Armor line.

## Phase 1 — storage-neutral seams (no new infra, no behaviour change)

| Ticket | Scope | Acceptance | Status |
|---|---|---|---|
| RF-1 | `pkg/platform/store` unit-of-work abstraction (Firestore implementation only) | Interface with `RunInTx(ctx, func(Tx) error)`; Firestore impl; unit tests; listed in `docs/code-map.md` | Todo |
| RF-2 | `graph`: remove `*firestore.Transaction` from `api.go`, use RF-1; contract test suite for `graph.Repo` | No storage types in `api.go`; callers in posts/messaging/etc. updated; contract suite runs against the Firestore repo on emulators; `make ci` + `make test-int` green | Todo |
| RF-3 | `identity`: same as RF-2 (`ProfileInTx`) | as RF-2 | Todo |
| RF-4 | `messaging`: same as RF-2 | as RF-2 | Todo |
| RF-5 | Remaining modules: contract test suites for every `Repo` (posts, engagement, communities, lists, notifications, media, moderation, search) | One suite per module, Firestore repo passes | Todo |
| RF-6 | Lint guard: a test or `go vet`-style check that fails if any `backend/internal/*/api.go` imports a storage client | Fails on a planted import; runs in `make ci` | Todo |

## Phase 2 — Postgres system of record (cut-over, no dual-write)

Prod has almost zero users (founder, 2026-11-02), so each module moves in one cut-over instead of dual-write +
backfill + read ramp (ADR-0033 D2). If real users arrive first, the remaining modules switch back to dual-write.

Module order: graph → posts → engagement → communities → lists → messaging. Modules depend on each other only through
interfaces, so a mixed state (some on Postgres, some on Firestore) is supported between cut-overs.

**Cut-over runbook (every module):** turn on degraded (read-only) mode → Firestore export to GCS → run
`migrate-<module>` → run its `--verify` → set `<MODULE>_STORE=postgres` and deploy → smoke with the test accounts →
turn off degraded mode. Rollback within 7 days: set `<MODULE>_STORE=firestore` (writes made since cut-over are lost
for that module; acceptable at this user count, said in the window notice). Written once as
`docs/runbooks/store-cutover.md` in RF-13.

| Ticket | Scope | Acceptance | Status |
|---|---|---|---|
| RF-10 | Terraform: Cloud SQL Postgres + Direct VPC egress for Cloud Run, **dev only**; DB user via IAM auth | `terraform plan` for dev attached to the PR; `# cost-approved: ADR-0033` on fixed-cost lines; founder applies | Todo |
| RF-11 | Backend platform: `pkg/platform/pg` (pgx pool, config, health check), Postgres `store.Tx`, migration tool and `backend/migrations/`, Postgres container in `make test-int` and CI | Migrations run up/down in CI; `/health` reports DB; listed in `docs/code-map.md` | Todo |
| RF-12 | `graph` Postgres repo (edges table: follows, blocks, mutes, requests) passing the RF-2 contract suite | Contract suite green on Postgres; no follow cap on this path; eraser and export cover the new tables | Todo |
| RF-13 | `graph` switch + migration: `GRAPH_STORE=firestore\|postgres` config (default firestore); `cmd/migrate-graph` (one-shot, idempotent, resumable, `--dry-run`, `--verify` comparing counts and a sample); `docs/runbooks/store-cutover.md` | Migration of emulator fixture data verifies with 0 diffs; whole test suite passes with the switch in either position | Todo |
| RF-14 | `graph` cut-over in dev, then prod in an announced window (founder runs prod) | Runbook followed; smoke green; result noted in this table | Todo |
| RF-15 | Remove the Firestore `graph` path 7 days after the prod cut-over | Firestore repo, its indexes and the switch removed; contract suite runs on Postgres only | Todo |
| RF-16..RF-35 | Repeat RF-12..RF-15 for posts, engagement, communities, lists, messaging (four tickets per module, same acceptance) | as above | Todo |

## Phase 3 — shared cache

| Ticket | Scope | Acceptance | Status |
|---|---|---|---|
| RF-40 | Terraform: Memorystore (dev), reachable over Direct VPC egress | dev plan in PR; cost marker | Todo |
| RF-41 | Redis implementations of `pkg/platform/cache`, `ratelimit`, `idempotency`; selected by config; in-process stays for local/tests | Same tests pass on both implementations; Redis container in `make test-int` | Todo |

## Phase 4 — hybrid timeline

| Ticket | Scope | Acceptance | Status |
|---|---|---|---|
| RF-50 | Fan-out worker: on post create, Pub/Sub push writes post IDs to followers' Redis inboxes for authors below the threshold | Idempotent per post; capped inbox length; deletes/blocks remove entries | Todo |
| RF-51 | Read path merges inbox + large-author pull, behind `FEATURE_TIMELINE_FANOUT`; pull path remains fallback | Same results as pull path on fixture data; p95 baseline vs new recorded with `make loadtest SCENARIO=timeline_read` | Todo |

## Phase 5 — search

| Ticket | Scope | Acceptance | Status |
|---|---|---|---|
| RF-60 | Posts full-text (`tsvector` + GIN), handles/names `pg_trgm`, behind the search interfaces | `testdata/search_query_grammar.json` passes; flag `FEATURE_SEARCH_PG` | Todo |

## Phase 6 — infra hardening

| Ticket | Scope | Acceptance | Status |
|---|---|---|---|
| RF-70 | LB + Cloud CDN + Cloud Armor for media | dev plan; cost marker | Todo |
| RF-71 | Staging project and its Terraform env | plan only; founder applies | Todo |
| RF-72 | Prod rollout of phases 2–3 infra | founder approves the prod plan (ADR-0019) | Todo |

## Phase 7 — service splits (only on measurement)
Candidates: media processing, notification fan-out. Each needs a measured reason recorded in a new ADR.
