# 0033. Architecture reset: relational core, shared cache, hybrid timeline
Status: Proposed
Date: 2026-11-02
Deciders: architect (proposal); founder (acceptance is the merge of this ADR's PR, and it adds fixed monthly cost, so
the founder's approval must be recorded here on acceptance)

## Context
On 2026-11-02 the founder asked to stop treating the free tier as the main design constraint and to refactor for
clean architecture and scale. The cost-first rules (ADR-0001 and the ADRs built on it) produced working software
(13 backend modules, about 53k lines of Go; 18 Flutter features, about 82k lines of Dart), but also three
structural limits that come from the free tier, not from the product:

1. **Firestore is the only datastore for a mostly relational domain.** The social graph is one document per user
   (`graph/{uid}` with `following`, `blocked`, `muted` and `blockedBy` arrays), capped at `maxFollowing = 5_000`
   (`backend/internal/graph/repo_firestore.go:38`) to stay under the 1 MiB document limit. Every follow rewrites that
   document and every request reads all of it (cached 60 s per instance). Communities, lists and messaging have the
   same relational shape.
2. **The home timeline is pulled on every read, with per-instance caches** (ADR-0004): one Firestore query per 30
   followees (the `in` limit), 4 in flight (`backend/internal/timeline/service.go:23`). Latency grows with followee
   count and every new or cold instance starts with an empty cache.
3. **Search is handle prefix and hashtag `array-contains` only** (ADR-0028): no full text, no ranking. And the module
   seams leak: `*firestore.Transaction` appears in the public interfaces of `graph`, `identity` and `messaging`, and
   73 non-test files under `backend/internal` import the Firestore client, so "swap the database without touching
   callers" (`CLAUDE.md`, Modules) does not hold today.

What is **not** a cost artefact and stays: Go modular monolith with Connect-RPC (ADR-0002), Flutter + BLoC,
Cloud Run, Pub/Sub push, server feature flags, Snowflake IDs, opaque cursors, query limits, idempotency keys,
backwards-compatible protos, the right-to-delete path, the prod release gate (ADR-0019). Splitting into
microservices is not a goal in itself; a module leaves the monolith only on a measured need (D7).

## Options
### A. Keep Firestore-only, fix seams and indexes
Pros: no fixed cost, smallest change. Cons: the graph cap, timeline cost and search limits stay. Cost: about the
current INR 434 / 1,626 / 3,396 per month at 300 / 1,000 / 3,000 DAU (`docs/reviews/cost-model.md`).

### B. Relational core + shared cache + hybrid timeline (chosen)
Cloud SQL for PostgreSQL as the system of record for relational modules, Memorystore (Redis/Valkey) as the shared
cache, fan-out-on-write timeline with read-time merge for large authors, Postgres full-text search.
Pros: removes all three limits, standard and well-understood stack. Cons: fixed monthly cost, VPC networking,
migrations and per-module cut-overs. Cost: see below.

### C. Spanner / GKE / dedicated search engine now
Pros: highest ceiling. Cons: large fixed cost and operational load with no measured need. Rejected; kept as the
Stage 3 target.

## Cost impact
Estimates, list prices, `asia-south1`, before traffic. **Verify with the GCP pricing calculator before acceptance**
and record the verified numbers here.
- Cloud SQL Postgres, dev: shared-core or smallest dedicated, no HA: roughly USD 10 to 30 / month.
- Cloud SQL Postgres, prod: 1 to 2 vCPU dedicated, HA, backups: roughly USD 100 to 200 / month.
- Memorystore, 1 GB basic per environment: roughly USD 35 to 45 / month each.
- External HTTPS load balancer + Cloud CDN + Cloud Armor for media (D6, phase 6 only): roughly USD 25 to 40 / month
  plus egress.
- Direct VPC egress from Cloud Run: no connector fee (avoid `google_vpc_access_connector`).
- Fixed floor once phases 2 to 3 land in both environments: roughly **USD 200 to 330 / month**, rising with phase 6.
  This bills after the ADR-0022 credit expires on 2026-12-26.
- Firestore reads/writes fall as modules move off it.
- Terraform lines for these resources carry `# cost-approved: ADR-0033` (the `cost-guard` hook accepts it).
- New guardrail: the founder sets `monthly_budget_inr` per environment in the budget module; alerts at 50/90/100%.

## Stage ladder
This ADR moves the project from Stage 0 to the Stage 2 architecture ahead of the DAU trigger, by founder decision
rather than by measurement. Seams that keep it swappable: every module's `Repo` interface (no storage types in public
signatures, D1), the `pkg/platform/cache` interface, the timeline `Source` interface. Stage 3 target unchanged
(Spanner, GKE, multi-region) and still needs a measured trigger.

## Decision
- **D1. Storage-neutral seams first.** No storage type (`*firestore.Transaction`, `*sql.Tx`, client handles) in any
  module's public interface. Transactions go through a unit-of-work in `backend/pkg/platform/store`. Each `Repo` gets a
  contract test suite that every implementation must pass.
- **D2. Postgres is the system of record** for graph, posts, engagement, communities, lists and messaging, migrated
  one module at a time by **cut-over**, not dual-write: prod has almost zero users (founder, 2026-11-02), so a short
  announced maintenance window is cheaper than dual-write, backfill and reconciliation. Per module: Postgres repo
  passing the contract suite, a one-shot idempotent migration command with a verify step, a config switch
  (`<MODULE>_STORE=firestore|postgres`, not a percent flag), cut-over in dev, then prod in a window, then removal of
  the Firestore path. If real users arrive before a module is cut over, that module reverts to dual-write by a dated
  note on this ADR. Migrations are versioned SQL files
  in `backend/migrations/` run by one tool (chosen in the first Postgres PR). Firestore may stay for identity profile
  docs, idempotency and notifications until a later decision.
- **D3. Shared cache.** Memorystore behind the existing `pkg/platform/cache`, `ratelimit` and `idempotency`
  interfaces. In-process implementations stay for local runs and tests.
- **D4. Hybrid timeline.** A Pub/Sub worker writes new post IDs into per-user inboxes in Redis for authors below a
  follower threshold; posts by authors above it are merged at read time. Behind `FEATURE_TIMELINE_FANOUT`; the pull
  path stays as the fallback until the flag is retired.
- **D5. Search on Postgres.** Full-text search (`tsvector`) for posts, `pg_trgm` for handles and names, behind the
  existing search interfaces; `testdata/search_query_grammar.json` stays the shared contract.
- **D6. Infra.** Terraform modules for Cloud SQL, Memorystore and Direct VPC egress (dev first). LB + CDN + Cloud
  Armor for media and a staging project in a later phase. Prod applies stay plan-then-founder-OK (ADR-0019).
- **D7. Service splits only on measurement.** First candidates: media processing and notification fan-out workers.
- **D8. Rules that stay** (unchanged from `CLAUDE.md`): backwards-compatible protos, a `Limit` on every query, opaque
  cursors, idempotency keys, flags for user-facing changes, right-to-delete for every table and collection, no N+1,
  structured logs, `/health`, graceful shutdown, no agent access to prod.

## Consequences
- Supersedes, where they conflict: ADR-0001 (free-tier-first), ADR-0003 (Firestore-only model, for migrated modules),
  ADR-0004 (pull-only timeline), ADR-0007 (the "not used at Stage 0" list), ADR-0008 (single graph document),
  ADR-0028 (search scope). ADR-0022 credit mode ends on its own dates. Other ADRs stay in force.
- `CLAUDE.md` gains an "Architecture reset" section pointing here; `AGENTS.md` gives the same rules to Codex.
- Supersession notes dated 2026-11-02 are added at the top of ADR-0001, 0003, 0004, 0007, 0008 and 0028, the cost
  models, the roadmap, the cost-related skills and agent definitions; their Accepted text is otherwise unchanged.
- Risk: data loss at cut-over. Mitigation: Firestore export before each cut-over, a verify step that compares counts
  and a sample of documents, and the store switch kept for 7 days so rollback is a config change.
- Risk: writes during the window. Mitigation: degraded mode (read-only) is on for the window.
- Risk: fixed cost with no revenue. Revisit if the monthly bill exceeds the founder's budget for two months running.

## Handoff
- backend-developer / Codex: phase 1 (D1) per module, then phase 2 (D2) starting with `graph`.
- production-deployer: Terraform for D6 in dev; prod plan only.
- tester: contract test suites per `Repo`; migration `--verify` tests per module.
- sre-performance: verified cost table above; latency baseline before and after D4.
