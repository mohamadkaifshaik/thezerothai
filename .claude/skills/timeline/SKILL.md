---
name: timeline
description: Home, profile and thread timelines on Firestore within free-tier read quotas — pull-on-read, incremental refresh, instance + client caching, filtering and the path to fan-out later. Use for any timeline, feed or refresh work.
---

# Timelines (Stage 0: pull-on-read)

Why pull: push fan-out costs 1 Firestore write per follower per post (the 20k writes/day quota disappears fast).
Pull costs reads, and reads are made cheap by incremental refresh + caching.

## Home timeline — `GetHomeTimeline(since_cursor | before_cursor, page_size default 20, max 50 — CLAUDE.md rule 5)`
1. Load `graph/{uid}` (instance cache 60 s) → `following` (+ self), `blocked`, `muted`.
2. Chunk followees into groups of 30. For each chunk (run concurrently, `errgroup` limit 4):
   - **Refresh** (client sent `since`): `posts where authorId in chunk and createdAt > since order by createdAt desc limit 50`.
   - **Older page** (`before`): `... createdAt < before ... limit <limit>`.
   - **Cold start** (no cursor): `limit <limit>` per chunk.
   Before querying, consult the **author-recent cache** (`authorId → last 20 posts`, TTL 60 s): for authors fully covered by cache, skip Firestore.
3. K-way merge by `(createdAt, postId)` desc, drop blocked/muted authors and `visibility` violations, cut to `limit`.
4. Hydrate "liked by me" from `userLikes/{uid}` (1 read, cached 60 s). Author data is already denormalized in each post.
5. Return posts + `next_since` + `next_before` (opaque base64 cursors) + `has_more`.

Cost: typical refresh ≈ 1 + ceil(F/30) + (new posts) reads; a user following 90 accounts with 5 new posts ≈ 9 reads.

## Client (Flutter) responsibilities
- Persist the timeline locally (drift on mobile, IndexedDB on web); show cached posts instantly.
- Pull-to-refresh / app resume → call with `since = newest cached`. Never refetch the whole feed.
- Auto-refresh no more often than every 60 s while foregrounded; no background polling. New-post pill instead of auto-insert.
- Infinite scroll with `before`; prefetch at 70%.
- Drop cached posts that return NOT_FOUND on detail open (deleted).

## Profile timeline
`posts where authorId == X order by createdAt desc limit 20` (+cursor). Cache first page per author 60 s in instance.

## Threads
Post detail = post doc + `posts where conversationId == root order by createdAt asc limit 30`.

## Instance cache
- `hashicorp/golang-lru/v2/expirable`, sized by entries (e.g., 20k posts, 5k authors, 5k graphs) within 512 MiB.
- On any write handled by this instance, update/evict the affected entries immediately.
- Other instances converge by TTL (≤ 60 s staleness is acceptable for social feeds; own posts are always shown because the client inserts them optimistically).
- Metrics in logs: `cache_hit`, `firestore_reads` per RPC — used by sre-performance to validate the budget.

## Celebrity / hot accounts
Accounts with many followers are read by many users → the author-recent cache makes them *cheaper*, not more expensive.
No special handling at Stage 0.

## Path to Stage 2 (ADR required)
When reads > ~1.5M/day: materialize per-user timelines in Memorystore (push for authors < 10k followers, pull merge for
larger), keeping Firestore as source of truth. The RPC contract and cursor format stay the same, so clients don't change.

## Rules
- Ranking ("For You") is a separate module that consumes the same candidates; the chronological feed never depends on it.
- Every change to this path updates the cost row in `docs/reviews/cost-model.md`.
- Targets (Stage 0): refresh p95 < 400 ms warm; cold page < 1.5 s including cold start.
