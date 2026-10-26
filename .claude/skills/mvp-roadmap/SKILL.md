---
name: mvp-roadmap
description: The phased product roadmap for the X-like platform, from a free-tier launch (about INR 434/month at 300 DAU) to funded scale, and how each phase maps to the stage-ladder rungs. Use when planning what to build next or bootstrapping the project.
---

# Roadmap

Status (2026-10-26): **Phase 0 done**. **Phase 1 backends are built and merged** (identity, graph, posts, timeline, engagement, media, notifications, moderation, account lifecycle), each behind a server flag; releases up to v0.4.0 (`docs/releases/`). **UI waves W0 and W1 (X colour system, shell, core surfaces) are merged** behind `ui_shell` (dev allowlist). **Credit mode (ADR-0022) is active until 2026-12-24**; it pays for a warm prod instance and a higher Vision cap, lifts no roadmap gate, and nothing built in the window may depend on it after 2026-12-22. **The canonical roadmap is `docs/plans/roadmap.md`** (waves W0-W8 + W1.5, status per feature, founder decisions; Spaces is out of scope); live ticket status is in `docs/plans/*.md` and the founder's task list is `docs/pending.md`. The phase list below is the original outline: where it conflicts with the roadmap, the roadmap wins. Update this note when a wave moves.

## Cost honesty
Stage 0 is designed around the free tier but is not $0 at real traffic (`CLAUDE.md`, ADR-0022, `docs/reviews/cost-model.md`):
about INR 434 / 1,626 / 3,396 per month at 300 / 1,000 / 3,000 DAU. Egress to India is never free, Vision is paid past
1,000 units a month, Firestore reads pass the free quota at about 215 DAU. What the roadmap forbids is a **fixed** fee.

## How phases map to the stage ladder
Every hot concern has a Stage 0 implementation, a seam to protect and a Stage 2/3 target with a measured trigger
(`stage-ladder` skill). Phases 0–2 stay on the Stage 0 rung of every row and only build the seams. Phase 3 is where
rungs move, one ADR per row, when its trigger fires. A planner never schedules a rung move by date; only by the number.

| Ladder row | Phases 0–2 build | Phase 3 moves to (ADR, trigger) |
|---|---|---|
| Home timeline | pull-on-read, `since` cursor, caches; merge behind the `timeline` interface | hybrid fan-out in Memorystore when reads > ~1.5M/day |
| Real-time | FCM nudge + pull; all events through `Events`/`Emitter` on Pub/Sub | owner-only Firestore listeners (rules ADR), then SSE on an instance-billed service |
| Counters | `FieldValue.Increment` through one helper, `ABORTED` metric | batched or sharded counters when a doc sustains contention |
| Cache | per-instance LRU + client cache behind an interface | Memorystore when hit rate or instance count says so |
| Rate limits, DDoS | per-instance limits, quotas, max-instances cap, degraded mode | shared limiter, Cloud Armor, CDN |

## Phase 0 — Foundation  ✅ done
- Monorepo skeleton: `backend/` Go module, `buf`, Flutter app shell, `firebase/` config, Makefile, emulator scripts.
- Terraform: dev + prod projects, Firestore, Cloud Run `api`, media buckets, Pub/Sub, Artifact Registry (cleanup), IAM + WIF, **budget alerts**, dashboard, uptime check, Firebase apps + Hosting.
- CI (PR checks on emulators) + CD to dev; tagged `candidate` revision release to prod, traffic moved by `promote-prod.yml` (ADR-0019).
- `identity` module; Firebase Auth sign-up/sign-in (email, Google, Apple) on all 3 platforms; App Check (web App Check needs its own ADR).

## Phase 1 — Core MVP — free tier at < ~300 DAU, per use past it  🚧 in progress
- Profiles (handle, bio, avatar), follow/unfollow, block/mute.
- Create post (text ≤ 280, mentions, hashtags, links), delete post, reply threads, scheduled posts (ADR-0021).
- Images (≤ 4) via client compression + signed uploads + SafeSearch within the Vision cap.
- Home timeline (pull + incremental refresh + caches; **chronological Following only**, founder 2026-10-22), profile timeline, post detail with replies.
- Likes, reposts. Quote posts: backend exists; quote UI is **in scope, wave W2** (2026-10-18 deferral reversed 2026-10-22).
- Notifications (in-app + FCM push; **Android push only for now, iOS/APNs push paused until the Apple launch**).
- Report + block flows, account deletion + export (store requirements).
- Cost model doc with real numbers after first 100 users.

## Later: Apple launch (paused, founder decision 2026-10-18)
No macOS/Xcode access now. Deferred until a Mac is available: iOS build and TestFlight/App Store release, the APNs authentication key (.p8) uploaded to the dev and prod Firebase projects (Cloud Messaging), Push Notifications capability on the App ID, and on-device iOS verification (notifications plan T12). The repo already carries the client side (`Runner.entitlements`, `UIBackgroundModes`). Sign in with Apple stays in scope for that launch.

## Phase 2 — Growth — pay-per-use, still no fixed cost
- Handle/hashtag search (Firestore prefix + array-contains), trending hashtags from a daily Scheduler job. **Reversed 2026-10-22: search, Explore, trends from our own hashtag counters and hashtag UI are in the MVP (waves W4 and W2).** Every search read is also a scraping vector: quota and rate limit per `security-checklist`.
- Bookmarks, pinned posts, edit window.
- Link previews (SSRF-safe fetcher, cached in Firestore).
- Short video ADR (client-compressed MP4 ≤ 30 s) if users ask for it.
- A ranked "For You" tab is a separate surface and needs its own ADR; Home stays chronological Following (founder 2026-10-22). If approved: recent posts from 2nd-degree follows + engagement score, computed in-request with cache.
- DMs v1 (wave W7): server-mediated pull + FCM push, no realtime connection, no E2E; E2E encryption is a later ADR.

## Phase 3 — Scale & trust (when a stage-ladder trigger fires, see `free-tier-budget` §6)
- One ADR per ladder row as its trigger fires: Memorystore timeline cache and hybrid fan-out, owner-only Firestore listeners then SSE, batched or sharded counters, Cloud SQL/Postgres FTS search, min-instances outside credit mode, second region, CDN + Cloud Armor.
- Abuse: moderator console, spam heuristics, shadow-limits.
- Analytics: batch export of Firestore to BigQuery (free query tier), no streaming inserts.
- Later: Spanner/GKE only with funding and measured need.

Each bullet becomes a plan via the `planner` agent, with a cost line, a flag and a `Seam:` line per ticket.
