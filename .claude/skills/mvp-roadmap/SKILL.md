---
name: mvp-roadmap
description: The phased product roadmap for the X-like platform, from a $0 free-tier launch to funded scale. Use when planning what to build next or bootstrapping the project.
---

# Roadmap

Status (2026-10): **Phase 0 done** (v0.1.0). **Phase 1 in progress**: profiles, follow/block/mute, read-budget hardening and part of posts/timeline are done; replies, images, likes, notifications, reports and deletion/export are not started. Live ticket status: `docs/plans/phase1.md` and `docs/plans/posts-and-timeline.md`. Update this note when a phase moves.

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
- Likes, reposts, quote posts.
- Notifications (in-app + FCM push).
- Report + block flows, account deletion + export (store requirements).
- Cost model doc with real numbers after first 100 users.

## Phase 2 — Growth — pay-per-use, a few $/month
- Handle/hashtag search (Firestore prefix + array-contains), trending hashtags from a daily Scheduler job.
- Bookmarks, pinned posts, edit window.
- Link previews (SSRF-safe fetcher, cached in Firestore).
- Short video ADR (client-compressed MP4 ≤ 30 s) if users ask for it.
- Simple "For You" v1: recent posts from 2nd-degree follows + engagement score, computed in-request with cache.

## Phase 3 — Scale & trust (when metrics trigger it — see `free-tier-budget` §6)
- ADRs for: Memorystore timeline cache, Cloud SQL/Postgres FTS search, min-instances, second region, CDN + Cloud Armor.
- Abuse: moderator console, spam heuristics, shadow-limits.
- DMs (separate ADR — E2E encryption decision).
- Analytics: batch export of Firestore to BigQuery (free query tier) — no streaming inserts.
- Later: Spanner/GKE only with funding and measured need.

Each bullet becomes a plan via the `planner` agent, with a cost line.
