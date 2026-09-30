---
name: firestore-data-model
description: Firestore collections, document shapes, indexes, query rules and read/write costs for users, graph, posts, engagement, media and notifications. Use when designing data, writing repositories or queries, or changing firestore.indexes.json / rules.
---

# Firestore data model (Native mode, `(default)` database)

Only the Go API touches Firestore (Admin SDK). `firebase/firestore.rules` is **deny-all** for clients:
```
rules_version = '2';
service cloud.firestore { match /databases/{db}/documents { match /{d=**} { allow read, write: if false; } } }
```

## Collections
| Path | Shape (key fields) | Written when | Cost notes |
|---|---|---|---|
| `users/{uid}` | handle, handleLower, displayName, bio, avatarUrl, isPrivate, followersCount, followingCount, postsCount, postsToday, postsDay, unreadNotifs, createdAt | signup, profile edit, counters | cache 60 s in instance |
| `handles/{handleLower}` | uid | signup / rename (transaction `Create` → uniqueness) | 1 read on lookup |
| `graph/{uid}` | following[] (≤ 5,000), blocked[] (≤ 2,000), muted[] (≤ 2,000), requested[] (≤ 500, unused until private accounts), blockedBy[] (≤ 10,000; never serialized/exported), blockedByOverflow (bool), updatedAt | follow/unfollow/block/mute (`ArrayUnion/ArrayRemove`); own-list lazy clean-up (T27: ListBlockedUsers/ListMutedUsers `ArrayRemove` of uids with no users doc, skipped under DEGRADED_MODE=readonly); Block/Unblock also write the target's `blockedBy` (ADR-0008) | **1 read = whole social context** incl. both block directions. ≈ 566 KB at all caps (28-char UIDs) < 1 MiB. Arrays exempt from indexing |
| `follows/{followerId}_{followeeId}` | followerId, followeeId, createdAt | follow | for followers/following list pages only |
| `posts/{postId}` | authorId, author{userId,handle,displayName,avatarUrl,verified}, kind, isReply, text (NFC, ≤ 280 code points), media[], replyToId, replyToHandle, conversationId, quoteOfId, repostOfId, embedded{}, hashtags[] (lower-case, ≤ 10), mentions[{userId,handle}] (≤ 10), likeCount, repostCount, replyCount, quoteCount, visibility, snapshotVersion, createdAt (= Snowflake ms) | create/delete, counter increments | author snapshot denormalized; refreshed lazily by a job when a profile changes (P2). P1 (ADR-0010) writes root posts only: `kind=POST`, `isReply=false`, `conversationId=postId`, `visibility=PUBLIC`; no `mentionIds` until the P6 ADR |
| `likes/{postId}_{uid}` | postId, uid, createdAt | like (`Create`; AlreadyExists = no-op) | |
| `userLikes/{uid}` | recent[] (last 1,000 liked postIds) | like/unlike | 1 read tells the client which timeline posts are liked |
| `reposts/{postId}_{uid}` | same pattern as likes | | |
| `users/{uid}/notifications/{id}` | type, actor snapshot, postId, createdAt, expireAt (TTL 90 d) | like/reply/follow/mention | TTL deletes are billed (cheap) |
| `media/{mediaId}` | ownerId, status (PENDING/READY/REJECTED), objectPath, thumbPath, bytes, contentType, createdAt, expireAt (TTL 2 d while PENDING) | upload init / finalize | |
| `reports/{id}` | reporterId, targetType, targetId, reason, status | report | |
| `quotas/{uid}` | day (IST), posts, follows, blocks (Block + Mute), uploads, exports | quota'd mutations, same batch/txn | 1 read + 1 write per quota'd call (ADR-0003, ADR-0008 D7) |
| `admin/vision-{yyyymm}` / `admin/config` | monthly counters, ops switches | rare | cache 5 min. Feature flags are **env vars**, not this doc (ADR-0008 D6) |

## Operation cost table (keep in sync with code)
| Operation | Reads | Writes |
|---|---|---|
| Sign up | 1 (handle check) | 3 (users, handles, graph) |
| Follow (ADR-0008 A2) | 4 cold / 2 warm (+1 if caller `blockedByOverflow`); planning value 4 (caller graph + quotas fresh in txn; users cache misses after a `Forget`) | 5 (follows doc, graph, 2 user counters, quotas); replay 0 writes, reads 4 cold / 2 warm |
| Unfollow | batch 0 (blind, `Exists` precondition); request logs 1 (caller profile read by the account-status interceptor, cold after a Follow) | 3 + 1 delete; no-op 0 |
| Block (ADR-0008) | 3 (both graphs, quotas) | 5 worst / 3 typical (2 graphs, quotas, + 2 users counters if edges) + ≤ 2 deletes |
| Unblock / Mute / Unmute | 1 / 3 / 1 (Mute: caller graph + target graph existence + quotas, ADR-0008 A1; Mute of a uid with no `graph` doc = NOT_FOUND after 2 reads, 0 writes; Mute replay 3 reads) | 2 / 2 / 1 (0 on no-op or replay) |
| Create post (root, ADR-0010) | 14 cold / 2 warm, planning 2.5 (caller `users` via interceptor + author `graph` only if mentions + ≤ 10 `handles` in one `GetAll` + `idempotency` + `quotas`, the last two fresh in the txn); replay 14 cold / 1 warm | 4 (idempotency, post, `users.postsCount`, quotas) + 1 eventual TTL delete; replay 0. Mention notifications arrive with P6 |
| Delete post (ADR-0010 D4) | 2 cold / 0 warm, planning 1 (interceptor + post) | 1 (`postsCount` −1) + 1 delete (`Exists` precondition); not owner / unknown / already deleted = success, 0 writes |
| Get post (ADR-0010) | 4 cold / 0 warm, planning 1 (interceptor + post + author `users` + caller `graph`; +1 if caller `blockedByOverflow`; +1 `userLikes` from P5) | 0 |
| Like | 0–1 | 3 (like doc, post counter, userLikes) + 1 notification |
| Home timeline (ADR-0004, ADR-0010) | ceiling 2 + C + 2·page (269 at F = 5,000, page 50; 2 = interceptor + graph; +1 `userLikes` from P5), C = ceil((F+1)/30). Refresh planning 4 + new posts (graph expired: refreshes are ≥ 60 s apart); older page / cold open planning 30 (F = 60, page 20, k = 14) | 0 |
| Profile timeline (ADR-0010 D16) | 3 + page cold (53 at page 50: interceptor + target `users` + caller `graph` + `Limit(page)`), 0 warm (Posts-tab first page = author-recent cache), planning 11; `since` with 0 new = 4 cold | 0 |
| Post detail + 20 replies | 1 + ≤ 20 | 0 |
| Notifications page | ≤ 20 | 1 (reset unread) |

## Indexes (`firebase/firestore.indexes.json`)
- posts: `authorId ASC, isReply ASC, createdAt DESC` (home `in` chunks + profile Posts tab, `isReply == false`)
- posts: `authorId ASC, createdAt DESC` (profile Replies tab; purge/export pages, descending)
- posts: `conversationId ASC, createdAt ASC` (threads)
- posts: `hashtags ARRAY_CONTAINS, createdAt DESC` (hashtag pages)
- follows: `followeeId ASC, createdAt DESC`; `followerId ASC, createdAt DESC`
- users: single-field on `handleLower` (default) for prefix search
- Exempt large text fields from indexing (`posts.text`, `users.bio`) — saves storage and write cost.

## Query rules
- Every query has `.Limit(n)`, n ≤ 50. Cursor = last doc's `(createdAt, id)` encoded opaquely.
- Tie-breaker: order `createdAt DESC, __name__ DESC` explicitly. A composite index carries `__name__` in the direction of its **last** field, so an ascending `__name__` (or an ascending `createdAt` on a DESC index) needs a new index. Timeline tokens: bindings, window tokens, 30-day TTL and the `since` settle watermark per ADR-0010 D13/D14.
- `in` filters take ≤ 30 values → chunk and merge (k-way by createdAt).
- Prefix search: `where handleLower >= q and handleLower < q + ""` limit 10.
- Transactions only where invariants need them (handle uniqueness, like/unlike toggles). Keep them small.
- Read-your-writes: after a mutation, update the instance cache from the written data instead of re-reading.
- IDs: Snowflake (time-ordered) as decimal strings for posts/media. Fine below ~500 writes/s to a collection; revisit at Stage 2.
- **A uid never contains `_`** (ADR-0008 A3). `_` is the composite-key separator in `follows`, `likes` and `reposts` doc ids, so `a_b_c` would otherwise be ambiguous. A uid matches `^[A-Za-z0-9-]{1,128}$` (`pkg/platform/ids.ValidUID`), enforced on target ids, on the caller uid in authn, and in the single `edgeID` helper in `internal/graph`. A provider or import that issues `_` needs a new ADR before it is enabled.
- Idempotency: deterministic doc ID from `hash(uid, idempotency_key)` for creates; replay returns the existing doc.

## Deletes & privacy
- Deleting a post deletes its doc and its likes/reposts in a background Pub/Sub job; timeline caches invalidated; clients drop unknown IDs on refresh. Until P4/P5 add dependants, DeletePost is a synchronous batch only (ADR-0010 D4); account purge uses `posts.Eraser` (`authorId == uid ORDER BY createdAt DESC LIMIT 500`, self-resuming).
- Account deletion: Pub/Sub job batches (≤ 500 ops per batch) over posts, follows, likes, notifications, media objects, graph doc, `quotas/{uid}` (ADR-0003 amendment 2026-09-30;
  `docs/runbooks/account-deletion.md` Step 2), then the Firebase Auth user. Must be resumable.
- Export: same traversal written to a JSON file in a private GCS object with a 24 h signed URL.
- **Follow-edge invariant (ADR-0009, standing):** for any account that can call graph RPCs (ACTIVE), `follows/{a}_{b}` exists ⇔ `b ∈ graph/{a}.following` ⇔ both `users/{a}` and `users/{b}` exist. Only the account under purge (`DELETING`, rejected by the account-status interceptor) may violate it. This is why Unfollow's blind batch treats a failed precondition as a correct 0-write NONE with no extra read. Every new writer of `follows`, `following` or `users/*` deletes (follow requests, account restore/import, an automated deletion job, T27 extended to `following`) must preserve it and re-check ADR-0009's reopen criteria. Deletion is one-way once purge step 1 has run, and `users/{uid}` is deleted only after the purge dry run shows 0/0 edges (`docs/runbooks/account-deletion.md`).

## Migrations
Firestore is schemaless: add fields with defaults in Go structs; backfill with a throttled Cloud Run job (watch the 20k writes/day quota — spread across days or accept a few cents).
Never rename a field in place: add new → dual-write → backfill → switch reads → remove old.

## Local
`firebase emulators:start --only firestore,auth,pubsub,storage` — Go picks the emulator via `FIRESTORE_EMULATOR_HOST`.
