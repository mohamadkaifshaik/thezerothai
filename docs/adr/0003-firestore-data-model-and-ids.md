# 0003. Firestore data model, ID scheme, counters and idempotency
Status: Accepted
Date: 2026-09-26
Deciders: architect, founder

## Context
Stage 0: Firestore Native `(default)` database, free quota **50k reads / 20k writes / 20k deletes per day, 1 GiB**.
Reads are the binding limit (ADR-0001). Every RPC must have a bounded worst-case read count (rule 6), every mutation an
idempotency story (rule 4), IDs must be time-ordered 64-bit values (rule 1), and every collection needs a delete path
(rule 10). Only the Go API touches Firestore (rules are deny-all), so the model is optimised for server-side access
patterns and caches, not client listeners.

## Options
### A. Denormalized document model tuned for pull timelines (chosen)
One `graph/{uid}` doc holds the whole social context; author snapshot copied into each post; counters on parent docs;
deterministic natural-key doc IDs where possible; Snowflake IDs for posts/media.
- Pros: home timeline = 1 graph read + ceil(F/30) queries + new posts, no author hydration (no N+1); likes/follows are
  idempotent for free; counts are 0-read.
- Cons: author snapshot staleness after profile edits (refresh job costs writes); `graph` doc caps following at
  5,000 (1 MiB doc limit); monotonically increasing post IDs would hotspot above ~500 writes/s (Stage 2 problem).
- Cost: idle $0; typical ~188 reads, ~33 writes, ~8 deletes per DAU/day (cost model v0) → reads hit 80% of quota at
  ~213 DAU and 100% at ~266 DAU; overage at 300 DAU ≈ $0.11/month.

### B. Normalized model (posts store authorId only; follows only as edge docs)
- Pros: no staleness, no snapshot-refresh job.
- Cons: every timeline page adds ≤ 20 author reads (cached, but cache hit rate is low at small scale), and computing
  "who do I follow" needs a follows query of F docs instead of 1 read. Roughly 2–3× reads per DAU → free tier ends
  at ~100 DAU.
- Cost: at 300 DAU ≈ 150k reads/day → ~100k/day overage ≈ $1.2/month; at 3k DAU ≈ $15–20/month vs ~$6 for A.

### C. Firestore auto-IDs + separate idempotency docs for everything
- Pros: no hotspot risk ever; uniform idempotency code.
- Cons: violates rule 1 (no time order for cursors/tie-breaks and future SQL migration); +1 write and +1 TTL delete on
  every mutation, including the high-volume like path.
- Cost: ≈ +5 writes and +5 deletes per DAU/day (~+15% writes).

## Cost impact
- Fixed monthly cost added: **$0**.
- Free-tier quota consumed at 300 DAU (cost model v0): ~56k reads/day (113% of quota), ~9.9k writes/day (50%),
  ~2.3k deletes/day (12%, mostly notification TTL); storage < 50 MiB in year one (≈ 1.5 KiB per post incl. index entries → 1 GiB ≈ 600k posts).
- Trigger: Firestore > 1.5M reads/day or bill > $30/month (free-tier-budget §6) → Stage 2 ADR.

## Decision
Adopt option A with the following binding details.

**IDs.** Posts and media use a 64-bit Snowflake: 41 bits milliseconds since `2026-01-01T00:00:00Z` | 10 bits node
(random at instance start) | 12 bits per-ms sequence. Rendered as a **19-digit zero-padded decimal string** so
lexicographic order equals time order (doc IDs, cursors, Dart/JS never see int64). Writes use `Create()`; an
`AlreadyExists` on the entity doc is a node collision → regenerate and retry once (probability negligible with ≤ 3
instances). User IDs are Firebase UIDs. Edge docs use natural keys.

**Idempotency (rule 4).** Two mechanisms, cheapest first:
1. *Natural key* — `users/{uid}`, `handles/{h}`, `follows/{a}_{b}`, `followRequests/{a}_{b}`, `likes/{postId}_{uid}`,
   `reposts/{postId}_{uid}`, `exports/{hash(uid,key)}`: `Create()` → `AlreadyExists` = replay, return current state.
   Unfollow/unblock/mute/unmute/update/finalize are state-setting and naturally idempotent.
2. *Idempotency doc* — only for creates whose ID must be a Snowflake (CreatePost, CreateUpload):
   `idempotency/{sha256(uid|rpc|key)}` = {uid, rpc, requestHash, result (ids), expireAt = now+24 h (TTL)} created in
   the **same atomic batch** as the entity. `AlreadyExists` → read it (+1 read); same `requestHash` → return stored
   result; different → `INVALID_ARGUMENT` + `ERROR_REASON_IDEMPOTENCY_KEY_REUSED`.
   Cost: +1 write, +1 TTL delete per post/upload (~2 ops/DAU/day). Pub/Sub push handlers reuse the same pattern
   keyed by message ID where the handler's own writes are not naturally idempotent.

**Counters (rule 3).** `FieldValue.Increment` on the parent (users: followers/following/posts; posts:
like/repost/reply/quote). No sharding until a doc sustains > 1 write/s (measured → ADR). Daily per-user quotas live in
one doc `quotas/{uid}` = {day: "YYYY-MM-DD" (IST), posts, follows, uploads, exports}; the mutating RPC reads it (1 read),
rejects if over, and writes it in the same batch (set day + increment, or reset when day changed). Likes use in-memory
limits only (high volume, low harm) to save a write per like.

**Collections** (owner module in brackets; only the owner builds paths; others go through its Go interface):

| Path | Key fields | Notes |
|---|---|---|
| `users/{uid}` [identity] | handle, handleLower, displayName, bio, avatarUrl, avatarThumbUrl, isPrivate, verified, followersCount, followingCount, postsCount, notificationsSeenAt, status, handleChangedAt, snapshotVersion, createdAt, updatedAt | instance cache 60 s |
| `users/{uid}/private/*` [identity] | reserved for PII (none at Stage 0; email stays in Firebase Auth) | |
| `handles/{handleLower}` [identity] | uid, createdAt | uniqueness by transactional `Create` |
| `exports/{exportId}` [identity] | uid, status, objectPath, createdAt, expireAt (TTL 7 d) | |
| `graph/{uid}` [graph] | following[] (≤ 5,000), blocked[] (≤ 2,000), muted[] (≤ 2,000), requested[] (≤ 500), updatedAt | 1 read = whole context; arrays exempt from indexing |
| `follows/{followerId}_{followeeId}` [graph] | followerId, followeeId, createdAt | list pages only |
| `followRequests/{followerId}_{followeeId}` [graph] | followerId, followeeId, createdAt | private accounts |
| `posts/{postId}` [posts] | authorId, author{userId,handle,displayName,avatarUrl,verified}, kind, isReply, text, media[], replyToId, replyToHandle, conversationId, quoteOfId, repostOfId, embedded{}, hashtags[], mentions[], mentionIds[], likeCount, repostCount, replyCount, quoteCount, visibility, snapshotVersion, createdAt | `isReply` exists only to filter home/profile queries |
| `likes/{postId}_{uid}`, `reposts/{postId}_{uid}` [engagement, later ADR] | postId, uid, createdAt | |
| `userLikes/{uid}` [engagement] | recent[] (last 1,000 liked post ids), recentReposts[] (last 500) | 1 read hydrates viewer flags for a whole page |
| `users/{uid}/notifications/{id}` [notifications] | type, actor{}, postId, createdAt, expireAt (TTL 90 d) | |
| `media/{mediaId}` [media] | ownerId, purpose, status, uploadPath, publicPath, thumbPath, contentType, bytes, w, h, blurhash, createdAt, expireAt (TTL 2 d, removed when READY) | |
| `idempotency/{hash}` [platform] | uid, rpc, requestHash, result, expireAt (TTL 24 h) | |
| `quotas/{uid}` [platform] | day, posts, follows, uploads, exports | |
| `reports/{id}` [moderation] | reporterId, targetType, targetId, reason, status, createdAt | |
| `admin/config`, `admin/vision-{yyyymm}` [admin/media] | feature flags; SafeSearch monthly counter | cached 60 s–5 min |

Deviations from the `firestore-data-model` skill, decided here: per-day quota counters moved from `users` into
`quotas/{uid}` (keeps `users` owned by identity and rarely written); `admin/visionUsage/{yyyymm}` → `admin/vision-{yyyymm}`
(the former is not a valid document path); `followRequests`, `exports`, `idempotency`, `isReply`, `kind`,
`userLikes.recentReposts` added; `users.unreadNotifs` replaced by `notificationsSeenAt` + a `count()` aggregation
(`createdAt > seenAt`, ≤ 1 read) in GetMe, which removes one counter write per notification; reposts are post docs (`kind=REPOST`) so pull timelines include them with no extra query.
The skill will be updated to match.

**Author snapshot refresh.** On displayName/avatar/handle change, identity bumps `users.snapshotVersion` and publishes
`profile-snapshot-refresh`; the handler rewrites `author` on the author's **newest 100 posts** (older posts keep the old
snapshot; acceptable at Stage 0) in batches, skipping docs whose `snapshotVersion` is already current (replay-safe).
Snapshot-affecting edits limited to 5/day. Visibility changes (private ↔ public) rewrite **all** of the author's posts
(privacy-critical; 1 toggle/day).

**Indexes.** Composite indexes in `firebase/firestore.indexes.json`: posts (authorId, isReply, createdAt↓) for home and
profile "Posts" tab; posts (authorId, createdAt↓) for "Replies" tab; posts (conversationId, createdAt↑) for threads;
posts (hashtags CONTAINS, createdAt↓) for Phase 2 hashtag pages; follows by followee/follower + createdAt↓;
followRequests by followee + createdAt↓. Indexing disabled on large or unqueried fields (post text/author/media/
embedded/mentions, user bio/displayName/avatars, all `graph` arrays, `userLikes` arrays).
TTL policies on `expireAt` for collection groups `idempotency`, `media`, `notifications`, `exports` are owned by
**Terraform** (`infra/terraform/modules/firestore`, `google_firestore_field` with `ttl_config` and an empty
`index_config` to exempt the TTL field from indexing). No field is declared in both places: `firestore.indexes.json`
never mentions `expireAt`, Terraform never declares indexes. TTL deletes are billed as deletes (tiny).

**Queries.** Every query has `Limit ≤ 50`; cursors encode `(createdAt, docId)` + bounds, base64, opaque, HMAC-signed so
clients cannot craft unbounded scans. `in` ≤ 30 values, chunked. Known IDs fetched with `GetAll` after the cache.

**Deletes & privacy (rule 10).** `post-delete` and `account-delete` Pub/Sub jobs traverse owned collections with
`Limit(500)` pages, delete in batches, checkpoint progress in the job's doc so redelivery resumes; media objects deleted
in GCS; Firebase Auth user deleted last. Export writes a JSON object to a private bucket path, 7-day lifecycle.

## Consequences
- Positive: timeline and profile reads have no N+1; likes/follows cost 0 idempotency overhead; the model maps cleanly
  to Postgres tables at Stage 2 (Snowflake PKs, edge tables, counters).
- Negative: snapshot staleness on old posts; following capped at 5,000; privacy toggles cost O(posts) writes;
  Snowflake doc IDs will need a hotspot review before sustained > 500 posts/s.
- Follow-up: update `firestore-data-model` skill table; sre-performance validates per-RPC `fs_reads`/`fs_writes` log
  fields against `docs/reviews/cost-model.md` after the first 100 users.
- Revisit when: reads > 1.5M/day, any doc > 1 write/s sustained, or an account approaches 5,000 following at scale.

## Handoff
- backend-developer: `pkg/platform/snowflake` (layout above, zero-padded strings), `pkg/platform/idempotency`
  (hash, batch-create, replay), `pkg/platform/quota` (`quotas/{uid}`), `pkg/platform/cursor` (HMAC-signed opaque
  tokens, key from Secret Manager read once at startup), `pkg/platform/store.Batch`. Log `fs_reads`/`fs_writes` per RPC.
- frontend-developer: treat all IDs as opaque strings; generate one UUID idempotency key per user intent and reuse it
  on retries until success or a non-retryable error.
- production-deployer: deploy `firebase/firestore.indexes.json` (composite indexes + index exemptions) and rules with
  `firebase deploy --only firestore` in CI. Terraform `ttl_fields` must be exactly: `idempotency.expireAt`,
  `media.expireAt`, `notifications.expireAt`, `exports.expireAt` (the current draft uses `mediaUploads` and
  `idempotencyKeys`, which do not exist in this model, and lacks `exports`); add `index_config {}` to those fields.
- tester: emulator tests for replay of every mutating RPC (same key twice → same result, writes counted once), key
  reuse with a different body, quota rollover at IST midnight, account-delete resumption after a crash mid-batch.

## Note 2026-09-28: see ADR-0008
Cross-reference only; no decision above changes. ADR-0008 (social graph slice) adds to the model: `graph/{uid}.blockedBy[]`
(≤ 10,000, never serialized or exported) and `graph/{uid}.blockedByOverflow` (bool); `quotas/{uid}.blocks` (Block + Mute).
It defers private accounts, so `followRequests/*` and `graph.requested[]` get no writes until the `private-accounts`
plan. It also fixes the graph counter invariants and the resumable graph purge (`graph.Eraser`) used by the
`account-delete` job.
