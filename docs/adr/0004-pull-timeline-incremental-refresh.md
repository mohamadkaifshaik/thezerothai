# 0004. Pull-on-read timeline with incremental refresh and two-level cache
Status: Accepted
Date: 2026-09-26
Deciders: architect, founder

## Context
Stage 0 home timeline must be p95 < 400 ms warm, < 1.5 s cold, and fit the Firestore free quota (50k reads/day,
20k writes/day) at up to ~300 DAU. The home timeline is the single largest read consumer (~58% of reads in the cost
model). Rule 2 forbids write fan-out at Stage 0. Contract: `dzeroth.timeline.v1.TimelineService`.

## Options
### A. Pull-on-read + `since` refresh + bounded chunk merge + instance/client cache (chosen)
- Read path: `graph/{uid}` (cached) → followees+self chunked by 30 → one query per chunk → k-way merge.
- Pros: zero writes per post regardless of follower count; refresh cost ≈ new posts only; celebrity accounts get
  *cheaper* via the author-recent cache; contract survives the Stage 2 move to a materialized cache.
- Cons: read cost grows with following count (≥ 1 read per chunk even when empty); latency grows with chunks
  (≤ 4 concurrent queries).
- Cost: typical refresh ~8 reads, older page ~23 reads; ~109 home-timeline reads/DAU/day → see cost model.

### B. Push fan-out on write (materialized `timelines/{uid}/items`)
- Pros: 1 query per page, O(1) read cost.
- Cons: 1 write per follower per post — a user with 300 followers posting 3×/day = 900 writes; at 300 DAU the 20k
  writes/day quota is gone by mid-morning; deletes/blocks need fan-out cleanup.
- Cost: at 300 DAU ≈ 300 posts × ~60 followers = 18k writes/day (90% of quota) for timelines alone; at 3k DAU ≈
  $5–10/month more than A, and it grows with graph density, not usage.

### C. Pull without incremental refresh (re-read first page every open)
- Pros: simplest client.
- Cons: every open costs C + 20 reads; ~2× A's reads → free tier ends at ~120 DAU.

## Cost impact
- Fixed monthly cost added: **$0**.
- Free-tier quota: home ≈ 109 reads/DAU/day (8 refreshes × ~3 overhead + ~60 new followee posts read once + 1 older
  page × ~23 + occasional cold opens), 0 writes. At 300 DAU ≈ 33k reads/day = 66% of the daily read quota.
  Profile timelines ≈ 22 reads/DAU/day.
- Worst case per call: `2 + C + 2 × page_size` where `C = ceil((following + 1)/30)`; at the 5,000-following cap and
  page 50 → 269 reads. Guarded by 6 calls/min/uid rate limit and the per-call page cap.
- Trigger: Firestore > 1.5M reads/day or timeline p95 > 800 ms warm → Stage 2 ADR (Memorystore push/pull hybrid).

## Decision
Option A, precisely:
1. **Cursors.** Opaque, HMAC-signed tokens encoding `(createdAt, postId)` plus bounds. `since_token` = newest item
   returned; `page_token` = oldest item returned; `gap_page_token` = (upper bound = oldest item of this refresh,
   lower bound = previous since). All three RPC fields are defined in `timeline.v1`.
2. **Chunk queries.** `posts where authorId in chunk(30) and isReply == false and createdAt {> since | < before}
   order by createdAt desc limit k` with `k = max(1, ceil(2 × page_size / C))`, at most 4 in flight (`errgroup`).
3. **Exact-prefix merge.** Merge all chunk results by `(createdAt, postId)` desc. Let `B` = the newest "last item" among
   chunks that returned exactly `k` docs (those chunks may have more). Return only items ≥ `B` (never empty: the chunk
   that defines `B` contributes k items). This makes the per-call read bound `C + 2 × page_size` without losing
   ordering correctness; short pages are fine because the client follows `next_page_token`.
   On refresh, if any chunk filled `k`, the result does not reach `since` → return `gap_page_token`.
4. **Filtering.** Drop authors in `blocked`/`muted`, and posts with `visibility = FOLLOWERS` whose author the caller
   does not follow (possible only for the caller's own stale graph). Over-read is accepted; page may be short.
5. **Viewer flags.** `userLikes/{uid}` (1 read, cached 60 s) sets `liked_by_viewer`/`reposted_by_viewer`.
6. **Instance cache** (`hashicorp/golang-lru/v2/expirable`, budget ~150 MiB of the 512 MiB): graph docs (5k, 60 s),
   users (5k, 60 s), posts (20k, 60 s), author-recent (last 20 posts per author, 5k authors, 60 s), profile first
   pages (2k, 60 s), userLikes (5k, 60 s). An author whose newest cached post is older than `since` and whose entry is
   fresher than 60 s is answered from cache (0 reads). Writes on this instance update/evict entries immediately;
   other instances converge by TTL (≤ 60 s staleness accepted).
7. **Client cache** (drift on mobile, IndexedDB on web): persist items + `since_token`; show cache instantly;
   refresh on pull/resume, auto-refresh at most every 60 s while foregrounded, never in background; new-post pill;
   infinite scroll with `page_token`, prefetch at 70%; render gap rows; drop posts that return NOT_FOUND.
8. **Profile timeline** uses the same token contract with `authorId == X` (+ `isReply == false` for the Posts tab).
9. **Worst-case controls.** Following cap 5,000; 6 home calls/min/uid; page_size ≤ 50; per-RPC deadline 10 s;
   `DEGRADED_MODE=readonly` does not block reads, but a future `DEGRADED_MODE=lite` may force page_size 10.

## Consequences
- Positive: posting is O(1) writes; refresh cost scales with new content, not history; no stateful infra.
- Negative: users following thousands of accounts pay (and wait for) ~C queries per call — at C = 167 about
  42 sequential rounds of 4 queries ≈ 1–2 s; acceptable for a rare power-user at Stage 0.
- Follow-up: log `timeline_chunks`, `cache_hit`, `fs_reads` per call; sre-performance tracks p95 and reads/call.
- Revisit when: reads > 1.5M/day, p95 > 800 ms warm, or > 5% of DAU follow > 1,000 accounts.

## Handoff
- backend-developer: implement steps 1–9 in `internal/timeline` against `posts.Reader` and `graph.Reader` interfaces;
  never query `posts` directly from timeline. Unit-test the exact-prefix merge with adversarial chunk distributions.
- frontend-developer: implement the token contract in `timeline.proto` header comment exactly (gap rows, since
  persistence, 60 s auto-refresh cap).
- production-deployer: nothing new; indexes ship with `firestore.indexes.json`.
- tester: emulator tests asserting read counts: refresh with 0 new posts == C reads (+0 when graph cached); page of 20
  with F = 60 ≤ C + 40; gap token never re-reads items older than the previous since.
