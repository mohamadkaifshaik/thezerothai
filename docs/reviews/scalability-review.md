# Scalability review: path from Stage 0 to an X-scale platform
Date: 2026-10-05 · Reviewer: Claude (design review, no production data) · Status: proposal for founder/architect triage

Scope: files and designs that will need to change, or new requirements to add, to grow from Stage 0 (≤ 300 DAU, $0) to
Stage 3 (200k+ DAU), while keeping Stage 0 free. Nothing here should be built before its trigger fires
(`free-tier-budget` §6); the point is to **design the seams now** and write the ADRs when measured numbers arrive.

## 1. What already scales well (keep)
- Module boundaries as Go interfaces (`posts.Reader`, `identity.Directory`, `graph` api.go), so a module can become its own service.
- Time-ordered 64-bit Snowflake IDs; opaque HMAC cursors; every query has a `Limit`; idempotency keys on mutations.
- Per-RPC read budgets asserted in tests (`budgettest`), a read-budget interceptor, server feature flags, degraded mode.
- Media bypasses the API (signed GCS URLs). Protos with `buf breaking`.

## 2. Hard scaling limits in the current design

| # | Limit | Where | Why it breaks | Fix (stage) |
|---|---|---|---|---|
| 1 | Pull-on-read home timeline costs `2 + C + 2p` reads (**269 at F = 5,000**) per refresh | ADR-0004, `internal/timeline`, plan T13 | Reads grow with followees × refreshes; accounts that follow thousands, or 100k DAU × 8 refreshes, blow the Firestore budget | Stage 2: materialised timelines (Redis/Memorystore, or a `timelines/{uid}` write fan-out) for normal users, pull for high-follower authors (hybrid). Keep the `GetHomeTimeline` contract unchanged (ADR-0004 already says so). **Pre-work now:** define `timeline.Source` interface so the implementation can swap. |
| 2 | Rate limits, read budgets, caches and mark LRUs are **per instance, in memory** | `pkg/platform/ratelimit`, `budget`, `cache`; ADR-0010 residual risks R1/R2 | At max-instances 3 the limits are ×3; at 50+ instances they are effectively unenforced, and instance cycling resets counters (≈ 623k reads/day worst case) | Stage 1: keep. Stage 2: shared counter store (Memorystore or a Firestore-backed sharded counter) behind the existing `ratelimit`/`DailyCap` interfaces; Cloud Armor at the edge. |
| 3 | Counters via `FieldValue.Increment` on the parent doc (≤ 1 write/s) | CLAUDE.md rule 3, `postsCount`, future like counts | A viral post gets far more than 1 like/s; Firestore contention and write errors | Sharded counters (N sub-docs, summed on read, cached) for `likes/reposts/replies` **before** engagement ships; define it in the engagement ADR, not retrofitted. |
| 4 | Firestore hot-spot risk: time-ordered doc IDs/indexes on `createdAt` | `posts` indexes, Snowflake IDs | Sequential keys and monotonically increasing index entries cap at ~500 writes/s per collection | Fine at Stage 0-1. Before Stage 2 load-test write-heavy paths; consider key-prefix hashing for `notifications`/`likes` collections. |
| 5 | Search is Firestore prefix + `array-contains` only | `search` module (not built), indexes | No tokenisation, ranking, typo tolerance, no phrase search; hashtags index is one array field | Stage 2 ADR: Postgres FTS (Cloud SQL) or Typesense/Elastic; index via Pub/Sub from `posts` events (`PostEvents` hook already exists). |
| 6 | Async work = Pub/Sub push to `api` `/internal/*` on the same Cloud Run service | `pubsubpush`, `/internal` is a placeholder | Background jobs (fan-out, notifications, snapshot refresh, purge) compete with user traffic; CPU only during requests | Split a `worker` Cloud Run service (same image, different entrypoint/flags) once notifications/fan-out ship; separate max-instances and concurrency. |
| 7 | Single region (`asia-south1`), single Firestore | ADR-0007 | Latency for non-India users, no regional failure tolerance | Stage 3: multi-region Firestore or Spanner ADR; CDN for media and read APIs. |
| 8 | Cloud Scheduler free tier = 3 jobs per billing account | `modules/scheduler` | Trending, snapshot refresh, cleanup, exports will exceed 3 | One dispatcher job fan-out through Pub/Sub; or move to Cloud Tasks. |
| 9 | Author snapshot denormalised into posts; refresh job planned (≤ 100 posts) | ADR-0003, P2 | Renames/avatars on accounts with millions of posts cannot be rewritten | Version the snapshot, resolve names at read time from a cached `users` batch for old posts, rewrite lazily. |
| 10 | Text-only moderation = SafeSearch + report-driven | ADR-0005 | No text toxicity/spam/CSAM-hash pipeline, no moderator tooling | Stage 1-2: spam heuristics, shadow limits, moderator console, hash-matching ADR (legal requirement at scale). |

## 3. Product requirements missing for an X-like platform (add to the roadmap)
Add these to `mvp-roadmap` Phase 2/3 so planners see them; none is needed at Stage 0.
- **Feed quality:** ranking ("For You") with an engagement-score ADR; muted words; lists; topics; "who to follow" (2nd-degree graph).
- **Content types:** replies/threads (P3), quotes, polls, long posts, edit window, drafts/scheduled posts, bookmarks, pinned posts, GIF/video (client-compressed first; Transcoder later), link previews with an SSRF-safe fetcher.
- **Real-time:** live new-post nudges (FCM today; Server-Sent Events/WebSocket gateway or Firebase RTDB for presence at Stage 2); typing/DM presence.
- **DMs:** separate ADR (E2EE decision, storage, abuse reporting).
- **Trust & safety:** report flows, appeals, moderator console, spam/bot detection, rate-limited new accounts, verified accounts, DSA/DPDP/GDPR data-subject tooling, legal takedown audit log.
- **Notifications:** batching/digest, per-type preferences, quiet hours, FCM topic fan-out for big accounts.
- **Growth/analytics:** privacy-preserving product analytics (BigQuery batch export, no streaming), A/B flags (percent flags exist; add experiment assignment logging), SEO (public profile/post pages with server-side rendering or prerender; the Flutter web app is not crawlable).
- **Developer/ops:** public API + API keys + OAuth for third parties (Stage 3), admin audit trail, data-retention jobs.

## 4. Files and areas to improve (with concrete changes)

| File / area | Improvement |
|---|---|
| `CLAUDE.md` (Growth stages) | Add measurable **exit criteria per stage** (DAU, reads/day, p95, $) and a "design seams to keep open" list (timeline source, counter store, rate-limit store, search index, worker service) referencing this review. Add SLOs (availability, p95 per RPC class) and an error-budget policy. |
| `docs/adr/0004-pull-timeline-incremental-refresh.md` | Specify the hybrid fan-out trigger (e.g. author followers > N) and the migration/backfill plan; cap `F` considered by home refresh (today only limited by the read budget). |
| `docs/adr/0006-auth-app-check-and-abuse-controls.md`, ADR-0010 D5 | Record the shared-limiter design (interface + Memorystore/Firestore implementation) so R1/R2 have a planned closure instead of acceptance only. |
| `backend/pkg/platform/{ratelimit,budget,cache}` | Put the counter store behind an interface (`Store`), keep the in-memory implementation as default; add metrics for hit/miss/evict so the Stage 2 trigger is observable. |
| `backend/internal/timeline` | Introduce the `Source` interface and keep `merge/gap/token` logic pure (T11 already plans this) so a materialised source drops in. |
| `proto/**` | Reserve field ranges and `oneof`/extension points for ranking signals and `impression_id` on timeline items; add `Idempotency-Key` header convention; pin API versioning policy (`v1` lifetime, deprecation windows). |
| `firebase/firestore.indexes.json` | Keep an index inventory with owner RPC per index (indexes cost write amplification and storage); add a CI check that fails on unused/undeclared indexes. |
| `infra/terraform` | Add `worker` service module, per-service max-instances/concurrency variables, alert policies for hot docs/contention, optional Cloud CDN/Armor modules gated behind `cost-approved` ADRs; a `stage` variable that selects caps. |
| `.github/workflows` | Add a scheduled **emulator load test** (k6) job with regression thresholds on reads/RPC and p95; add `terraform plan` cost-guard check (fixed-cost resource types fail the PR); add SBOM and container scan for the `ko` image. |
| `loadtest/` | Scenarios for timeline refresh at F=300/5,000, viral post (hot doc), thundering herd after a push notification, cold-start storm; document pass/fail thresholds. |
| `docs/reviews/cost-model.md` | Add a Stage 1/2/3 projection sheet (cost per 1k DAU vs architecture), and a "cost per active user" KPI tracked weekly. |
| `docs/runbooks/` | Add: hot-document contention, Firestore quota exhaustion (referenced by the SRE agent but missing: `firestore-quota.md`, `deploy-rollback.md`), Pub/Sub backlog/DLQ drain, mass-abuse/bot wave, incident comms template. |
| `.claude/agents` | Add a `data-engineer` (analytics/export/ranking offline jobs) and `trust-safety` role when Phase 2-3 starts; give `sre-performance` an explicit stage-trigger review each week. |
| `.claude/skills` | Add `scale-up` (how to execute an ADR-gated stage move: triggers, migration, rollback), `counters` (sharded counter pattern), `search` and `notifications` skills before those modules start. |
| `.claude/commands` | Add `/adr <topic>` and `/status` (summarise plan ticket status from `docs/plans/*`) to reduce manual tracking. |

## 5. Suggested ADR backlog (write when the trigger fires; design seams first)
1. Sharded counters for engagement (**write before the engagement slice**).
2. Worker service split and Pub/Sub topology.
3. Shared rate-limit/read-budget store.
4. Timeline materialisation (hybrid fan-out) and backfill.
5. Search backend choice.
6. Moderation pipeline v2 (text, hashes, tooling).
7. Multi-region / CDN / edge (Stage 3).
8. DM architecture and E2EE.
9. Ranking ("For You") and experimentation framework.
10. Public API and developer platform.

## 6. Recommended order
1. Finish the current slice (T6b → T8/T9 → T11–T13, plus Flutter T16–T18) so there is real traffic to measure.
2. Write the **sharded-counter ADR** and the `timeline.Source` / counter-store / limiter interfaces (cheap, prevents rewrites).
3. Add the load-test scenarios and CI thresholds; start weekly actuals vs model.
4. Only then act on scale-up triggers with measured numbers, one ADR at a time.
