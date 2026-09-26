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
| `graph/{uid}` | following[] (uids), blocked[], muted[], updatedAt | follow/unfollow/block/mute (`ArrayUnion/ArrayRemove`) | **1 read = whole social context** for timeline filtering. 1 MiB doc ≈ 25k uids → cap following at 5,000 |
| `follows/{followerId}_{followeeId}` | followerId, followeeId, createdAt | follow | for followers/following list pages only |
| `posts/{postId}` | authorId, author{handle,displayName,avatarUrl}, text, media[{url,thumbUrl,w,h,blurhash}], replyToId, quoteOfId, conversationId, hashtags[], mentions[], likeCount, repostCount, replyCount, visibility, createdAt | create/delete, counter increments | author snapshot denormalized; refreshed lazily by a job when a profile changes |
| `likes/{postId}_{uid}` | postId, uid, createdAt | like (`Create`; AlreadyExists = no-op) | |
| `userLikes/{uid}` | recent[] (last 1,000 liked postIds) | like/unlike | 1 read tells the client which timeline posts are liked |
| `reposts/{postId}_{uid}` | same pattern as likes | | |
| `users/{uid}/notifications/{id}` | type, actor snapshot, postId, createdAt, expireAt (TTL 90 d) | like/reply/follow/mention | TTL deletes are billed (cheap) |
| `media/{mediaId}` | ownerId, status (PENDING/READY/REJECTED), objectPath, thumbPath, bytes, contentType, createdAt, expireAt (TTL 2 d while PENDING) | upload init / finalize | |
| `reports/{id}` | reporterId, targetType, targetId, reason, status | report | |
| `admin/visionUsage` / `admin/config` | monthly counters, feature flags | rare | cache 5 min |

## Operation cost table (keep in sync with code)
| Operation | Reads | Writes |
|---|---|---|
| Sign up | 1 (handle check) | 3 (users, handles, graph) |
| Follow | 1 (graph, often cached) | 4 (follows doc, graph, 2 user counters) |
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
- Idempotency: deterministic doc ID from `hash(uid, idempotency_key)` for creates; replay returns the existing doc.

## Deletes & privacy
- Deleting a post deletes its doc and its likes/reposts in a background Pub/Sub job; timeline caches invalidated; clients drop unknown IDs on refresh.
- Account deletion: Pub/Sub job batches (≤ 500 ops per batch) over posts, follows, likes, notifications, media objects, graph doc, then the Firebase Auth user. Must be resumable.
- Export: same traversal written to a JSON file in a private GCS object with a 24 h signed URL.

## Migrations
Firestore is schemaless: add fields with defaults in Go structs; backfill with a throttled Cloud Run job (watch the 20k writes/day quota — spread across days or accept a few cents).
Never rename a field in place: add new → dual-write → backfill → switch reads → remove old.

## Local
`firebase emulators:start --only firestore,auth,pubsub,storage` — Go picks the emulator via `FIRESTORE_EMULATOR_HOST`.
