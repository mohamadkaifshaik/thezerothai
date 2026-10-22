---
name: mvp-roadmap
description: The phased product roadmap for the X-like platform, from a $0 free-tier launch to funded scale. Use when planning what to build next or bootstrapping the project.
---

# Roadmap

Status (2026-10-23): **Phase 0 done**. **Phase 1 backends are built and merged** (identity, graph, posts, timeline, engagement, media, notifications, moderation, account lifecycle), each behind a server flag; releases up to v0.4.1. **UI waves W0 and W1 (X colour system, shell, core surfaces) are merged** behind `ui_shell` (dev allowlist). **The canonical roadmap is `docs/plans/roadmap.md`** (waves W0-W8 + W1.5, status per feature, founder decisions; Spaces is out of scope); live ticket status is in `docs/plans/*.md`. The phase list below is the original outline: where it conflicts with the roadmap, the roadmap wins. Update this note when a wave moves.

## Phase 0 — Foundation — $0  ✅ done
- Monorepo skeleton: `backend/` Go module, `buf`, Flutter app shell, `firebase/` config, Makefile, emulator scripts.
- Terraform: dev + prod projects, Firestore, Cloud Run `api`, media buckets, Pub/Sub, Artifact Registry (cleanup), IAM + WIF, **budget alerts**, dashboard, uptime check, Firebase apps + Hosting.
- CI (PR checks on emulators) + CD to dev; tagged-revision release to prod.
- `identity` module; Firebase Auth sign-up/sign-in (email, Google, Apple) on all 3 platforms; App Check.

## Phase 1 — Core MVP — $0 at < ~300 DAU  🚧 in progress
- Profiles (handle, bio, avatar), follow/unfollow, block/mute.
- Create post (text ≤ 280, mentions, hashtags, links), delete post, reply threads.
- Images (≤ 4) via client compression + signed uploads + SafeSearch within quota.
- Home timeline (pull + incremental refresh + caches), profile timeline, post detail with replies.
- Likes, reposts. Quote posts: backend exists; quote UI is **in scope, wave W2** (2026-10-18 deferral reversed 2026-10-22).
- Notifications (in-app + FCM push; **Android push only for now, iOS/APNs push paused until the Apple launch**).
- Report + block flows, account deletion + export (store requirements).
- Cost model doc with real numbers after first 100 users.

## Later: Apple launch (paused, founder decision 2026-10-18)
No macOS/Xcode access now. Deferred until a Mac is available: iOS build and TestFlight/App Store release, the APNs authentication key (.p8) uploaded to the dev and prod Firebase projects (Cloud Messaging), Push Notifications capability on the App ID, and on-device iOS verification (notifications plan T12). The repo already carries the client side (`Runner.entitlements`, `UIBackgroundModes`). Sign in with Apple stays in scope for that launch.

## Phase 2 — Growth — pay-per-use, a few $/month
- Handle/hashtag search (Firestore prefix + array-contains), trending hashtags from a daily Scheduler job. **Reversed 2026-10-22: search, Explore, trends from our own hashtag counters and hashtag UI are in the MVP (waves W4 and W2).**
- Bookmarks, pinned posts, edit window.
- Link previews (SSRF-safe fetcher, cached in Firestore).
- Short video ADR (client-compressed MP4 ≤ 30 s) if users ask for it.
- Simple "For You" v1: recent posts from 2nd-degree follows + engagement score, computed in-request with cache.

## Phase 3 — Scale & trust (when metrics trigger it — see `free-tier-budget` §6)
- ADRs for: Memorystore timeline cache, Cloud SQL/Postgres FTS search, min-instances, second region, CDN + Cloud Armor.
- Abuse: moderator console, spam heuristics, shadow-limits.
- DMs: **v1 is in the MVP (wave W7)**, server-mediated pull + push, no E2E; E2E encryption is a later ADR.
- Analytics: batch export of Firestore to BigQuery (free query tier) — no streaming inserts.
- Later: Spanner/GKE only with funding and measured need.

Each bullet becomes a plan via the `planner` agent, with a cost line.
