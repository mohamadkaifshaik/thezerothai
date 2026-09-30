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
| `posts/{postId}` | authorId, author{handle,displayName,avatarUrl}, text, media[{url,thumbUrl,w,h,blurhash}], replyToId, quoteOfId, conversationId, hashtags[], mentions[], likeCount, repostCount, replyCount, visibility, createdAt | create/delete, counter increments | author snapshot denormalized; refreshed lazily by a job when a profile changes |
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
| Create post | 1 (user, cached) | 2 (post, user counters) + 1 per mention notification |
| Like | 0–1 | 3 (like doc, post counter, userLikes) + 1 notification |
| Home timeline refresh | 1 (graph) + ceil(following/30) queries + new posts | 0 |
| Profile page (20 posts) | 1 user + ≤ 20 posts | 0 |
| Post detail + 20 replies | 1 + ≤ 20 | 0 |
| Notifications page | ≤ 20 | 1 (reset unread) |

## Indexes (`firebase/firestore.indexes.json`)
- posts: `authorId ASC, createdAt DESC` (profile + home `in` queries)
- posts: `conversationId ASC, createdAt ASC` (threads)
- posts: `hashtags ARRAY_CONTAINS, createdAt DESC` (hashtag pages)
- follows: `followeeId ASC, createdAt DESC`; `followerId ASC, createdAt DESC`
- users: single-field on `handleLower` (default) for prefix search
- Exempt large text fields from indexing (`posts.text`, `users.bio`) — saves storage and write cost.

## Query rules
- Every query has `.Limit(n)`, n ≤ 50. Cursor = last doc's `(createdAt, id)` encoded opaquely.
- `in` filters take ≤ 30 values → chunk and merge (k-way by createdAt).
- Prefix search: `where handleLower >= q and handleLower < q + ""` limit 10.
- Transactions only where invariants need them (handle uniqueness, like/unlike toggles). Keep them small.
- Read-your-writes: after a mutation, update the instance cache from the written data instead of re-reading.
- IDs: Snowflake (time-ordered) as decimal strings for posts/media. Fine below ~500 writes/s to a collection; revisit at Stage 2.
- **A uid never contains `_`** (ADR-0008 A3). `_` is the composite-key separator in `follows`, `likes` and `reposts` doc ids, so `a_b_c` would otherwise be ambiguous. A uid matches `^[A-Za-z0-9-]{1,128}$` (`pkg/platform/ids.ValidUID`), enforced on target ids, on the caller uid in authn, and in the single `edgeID` helper in `internal/graph`. A provider or import that issues `_` needs a new ADR before it is enabled.
- Idempotency: deterministic doc ID from `hash(uid, idempotency_key)` for creates; replay returns the existing doc.

## Deletes & privacy
- Deleting a post deletes its doc and its likes/reposts in a background Pub/Sub job; timeline caches invalidated; clients drop unknown IDs on refresh.
- Account deletion: Pub/Sub job batches (≤ 500 ops per batch) over posts, follows, likes, notifications, media objects, graph doc, then the Firebase Auth user. Must be resumable.
- Export: same traversal written to a JSON file in a private GCS object with a 24 h signed URL.
- **Follow-edge invariant (ADR-0009, standing):** for any account that can call graph RPCs (ACTIVE), `follows/{a}_{b}` exists ⇔ `b ∈ graph/{a}.following` ⇔ both `users/{a}` and `users/{b}` exist. Only the account under purge (`DELETING`, rejected by the account-status interceptor) may violate it. This is why Unfollow's blind batch treats a failed precondition as a correct 0-write NONE with no extra read. Every new writer of `follows`, `following` or `users/*` deletes (follow requests, account restore/import, an automated deletion job, T27 extended to `following`) must preserve it and re-check ADR-0009's reopen criteria. Deletion is one-way once purge step 1 has run, and `users/{uid}` is deleted only after the purge dry run shows 0/0 edges (`docs/runbooks/account-deletion.md`).

## Migrations
Firestore is schemaless: add fields with defaults in Go structs; backfill with a throttled Cloud Run job (watch the 20k writes/day quota — spread across days or accept a few cents).
Never rename a field in place: add new → dual-write → backfill → switch reads → remove old.

## Local
`firebase emulators:start --only firestore,auth,pubsub,storage` — Go picks the emulator via `FIRESTORE_EMULATOR_HOST`.
