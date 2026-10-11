# 0018. Engagement: likes, reposts and quotes
Status: Proposed
Date: 2026-10-11
Deciders: lead (founder delegated product decisions 2026-10-10); founder accepts the ADR (CLAUDE.md)

> Numbering: next free number after 0017. 0012-0015 stay reserved for the slices that ran in parallel (P2-P4 did not need an ADR).

## Context
Phase 1 slice P5 (`docs/plans/phase1.md`, `docs/plans/engagement.md`). Users must be able to like, repost and quote
posts. Already decided and in place:

- ADR-0003 data model: `likes/{postId}_{uid}`, `reposts/{postId}_{uid}`, `userLikes/{uid}`, counters on the post doc
  (`FieldValue.Increment`, <= 1 sustained write/s per post), a repost is a `posts` doc with `kind = REPOST` so pull
  timelines include it with no extra query (ADR-0003:94). `quotas/{uid}` carries per-user daily counters.
- ADR-0004 / ADR-0010 D3: viewer flags come from one cached `userLikes/{uid}` read; until P5 they are false with no read.
- ADR-0011: `Eraser` / export-section registry; the T11 guard fails `make ci` for a collection without a row.
- P4 (`docs/plans/media-uploads.md`): the shared `jobs` topic carries the `post_delete` kind; P5 extends it.
- P6 (ADR-0017): producers call `Emitter.Emit` after their commit; nothing else of notifications is needed here.
- `RATE_LIMIT_LIKES_PER_MIN` (30) exists in config and is not wired.

What is not decided: who writes the REPOST post doc (posts owns `posts/*`, engagement owns `reposts/*` and both must
change atomically), how a quote embeds the original, how counters stay exact when the original is deleted, and how the
account purge covers the copies of a deleted user's text that live inside other users' reposts and quotes.

## Options
**Who writes the REPOST doc.** (a) engagement writes `posts/*` directly; (b) posts exposes a write seam
(`posts.EngagementWriter`, the `identity.Counters` pattern: methods that append to a caller's `store.Batch`) and
engagement owns the transaction; (c) posts owns the whole repost RPC and writes `reposts/*`.
(a) breaks "each module owns its collections". (c) moves an engagement collection into posts and would put a second
write path next to the counters. (b) keeps one writer per collection and one atomic unit.

**Quote embed.** (a) store only `quoteOfId` and join on read; (b) embed a frozen one-level snapshot (author, text,
media, createdAt) written with the quote. (a) is an N+1 per timeline page (rule 6). (b) costs nothing on read and is
the shape `EmbeddedPost` in `posts.proto` already has. Staleness (an edited profile of the quoted author) is accepted;
nothing in the product edits post text.

**Counters on delete.** (a) leave likeCount drifting and repair with a sweep; (b) decrement in the same batch that
deletes the like doc, with an `Exists` precondition so it happens exactly once; fall back to a delete-only batch when
the post is gone. (b) is the graph module's proven pattern and keeps the invariant checker simple.

**Like daily quota.** (a) `quotas/{uid}.likes` read in the transaction; (b) an in-memory `ratelimit.DailyCap`.
(b) is a per-instance, lost-on-restart bound; one account at the 30/min bucket can write 43k likes/day (170k Firestore
writes), which alone exceeds the free write quota. (a) costs 1 read and 1 write per like and is exact.

**post_delete fan-out.** (a) one handler per kind (today) and a second kind for engagement; (b) one kind, a composite
handler that runs the media step and the engagement step. (a) needs a second message per delete and a second topic
consumer branch; (b) is one Pub/Sub message (the media plan already specified it).

## Cost impact
Per DAU per day (5 likes, 0.5 unlikes, 0.3 reposts, 0.1 quotes, 0.05 deletes): about +10.5 reads, +23 writes, +0.7
deletes (`docs/plans/engagement.md` "Cost line"). At 300 DAU that is 3.2k reads (6% of the free 50k), 6.9k writes (35%
of 20k) and 0.2k deletes per day. Reads are already over the free quota at 300 DAU in `cost-model.md` (the likes rows
there assumed 0 reads; this adds the quota read and the `userLikes` hydration), about +$0.06/month at list price.
Pub/Sub: one < 200 byte message per deleted post. No new GCP resource, no fixed cost, no new index, no new topic, no
new Terraform beyond `FEATURE_ENGAGEMENT` env vars.

## Decision
**D1. Contract.** A new additive `dzeroth.engagement.v1.EngagementService` with `LikePost`, `UnlikePost`,
`RepostPost`, `UndoRepost` (request: `idempotency_key`, `post_id`; response: `PostEngagement` counts + viewer flags).
Quote is `CreatePost.quote_of_post_id` (already in the proto). `ListLikers` is deferred: a useful page is one query
plus up to 50 profile reads plus block filtering, which is not cheap, and nothing in Phase 1 needs it.

**D2. Data model.**
- `likes/{postId}_{uid}`: `postId, uid, createdAt`. `reposts/{postId}_{uid}`: `postId, uid, repostPostId, createdAt`.
  Doc ids are deterministic (`ids.ValidUID` forbids `_`), so a create is its own idempotency record.
- `userLikes/{uid}`: `recent[]` (post ids, newest last, trimmed to <= 1,000), `recentReposts[]` (<= 500), `updatedAt`.
  Written with `ArrayUnion` / `ArrayRemove` (blind, race-safe). Trimming is a best-effort `ArrayRemove` of the oldest
  100 once a cached copy exceeds the cap by 100.
- `posts/{id}.embedded` (QUOTE and REPOST): `{postId, author{...}, text, media[], createdAt, unavailable}`; with
  `quoteOfId` / `repostOfId` and a top-level `embeddedAuthorId` (the `embedded` map is exempt from indexing in
  `firestore.indexes.json`, so the query field must be top level). A tombstone is `{postId, unavailable: true}` and
  drops `quoteOfId` and `embeddedAuthorId`.
- `quotas/{uid}.likes`: likes today (IST day), 500/day, 100/day for accounts younger than 24 h
  (`QUOTA_LIKES_PER_DAY`, `QUOTA_NEW_ACCOUNT_LIKES_PER_DAY`). Reposts and quotes use the existing `posts` counter.
- No composite index: the new queries are single-equality (`likes.postId`, `likes.uid`, `reposts.postId`,
  `reposts.uid`, `posts.quoteOfId`, `posts.embeddedAuthorId`) served by automatic single-field indexes.

**D3. Atomic units (counters exact).**
- *Like*: one transaction. It reads `quotas/{uid}` (1 read), then `Create`s the like doc (an `AlreadyExists` at commit
  is the replay: 0 writes), increments `posts/{id}.likeCount` (an `Update`, so a post deleted in between fails the
  commit with NotFound and nothing is written), `ArrayUnion`s `userLikes.recent` and sets the quota. Aborted
  transactions are retried a bounded number of times.
- *Unlike*: one blind batch: `Delete(likes/{id}, Exists)`, `likeCount -1`, `ArrayRemove`. A failed `Exists` is a
  correct 0-write no-op (the same proof as ADR-0009). When the post is gone the counter update is dropped and the
  delete is retried alone.
- *Repost*: one transaction like Like, with `Create(reposts/{id})`, `Create(posts/{newId})` through
  `posts.EngagementWriter`, `repostCount +1`, `users.postsCount +1` (`identity.Counters`), `ArrayUnion
  userLikes.recentReposts`, quota `posts`. The REPOST id is a Snowflake drawn in the attempt.
- *Undo repost*: read `reposts/{id}` (needs `repostPostId`), then one batch deleting both docs (`Exists` on each),
  `repostCount -1`, `postsCount -1`, `ArrayRemove`.
- *Quote*: inside the CreatePost transaction (like a reply): the quoted post is read and checked before the
  transaction, `quoteCount +1` is an `Update` with an implicit `Exists`.

**D4. Targets.** Like, repost and quote of a REPOST id act on `repostOfId` (the original). The target must pass the
GetPost visibility rules (`service.viewable`: missing, deleted, hidden, suspended or blocking author is the one
NOT_FOUND "post not found"). Unlike and Undo need no visibility check: a user can always retract.

**D5. Viewer flags.** `posts.ViewerFlags` (declared in posts, implemented by engagement) is called once per
GetPost / GetThread / timeline request: one `userLikes/{uid}` read, cached 60 s per instance, updated in place by this
instance's own like/repost writes. With the flag off for the caller there is no read and every flag is false. A read
failure degrades to false flags (logged), never to a failed timeline. A REPOST item's flags describe its original.
Likes older than the newest 1,000 render as not liked; the client's own cache covers the common case and a LikePost
replay returns the truth.

**D6. Delete cascade.**
- `DeletePost` publishes `post_delete` for every deleted post (P4 D4 revisited: the early return for posts without
  images is dropped).
- The `jobs` kind `post_delete` is handled by a composite in apiserver that runs `media.Jobs` then `engagement.Jobs`
  and nacks if either fails. `media.Jobs` acknowledges a message without images as "noop" before reading anything.
- `engagement.Jobs` refuses while the post exists (a fresh read, the C1 pattern), then in pages: deletes the likes docs
  (no counter: the post is gone), deletes each repost doc together with the REPOST post doc it created and
  `postsCount -1` of the reposter, and replaces the embeds of quotes of the post with a tombstone
  (`posts.EngagementWriter.TombstoneQuotes`). Work above a bounded number of pages per delivery republishes the
  same message and acknowledges; there is no unbounded loop and no nack storm.
- A stale `userLikes` entry for a deleted post is left (a clean-up is one write per liker; entries age out by the cap).
- Deleting a REPOST doc with `DeletePost` is an undo: `posts.RepostLinks.StageRelease` adds the
  `Delete(reposts/{originalId}_{uid})` to the delete batch and the original's `repostCount` and the user's
  `recentReposts` are released best effort after the commit (the P3 `releaseParent` pattern). Deleting a QUOTE
  releases the quoted post's `quoteCount` the same way.

**D7. Account lifecycle (ADR-0011).** `engagement.Eraser` is a new step `engagement` registered before identity and
after media: (1) the user's likes, pages of 100, each as an atomic pair (delete like with `Exists`, `likeCount -1`,
delete-only fallback when the post is gone); (2) the user's reposts, same shape with `repostCount`; (3)
`userLikes/{uid}`. The posts step additionally removes the copies of the deleted user's content that live in other
users' docs: after the user's own posts it pages `posts where embeddedAuthorId == uid`, deleting REPOST docs
(with their `reposts/{originalId}_{reposter}` doc and the reposter's `postsCount -1`) and tombstoning QUOTE docs. The
export gains an `engagement` section (likes and reposts as post id + time). T11 rows `likes`, `reposts`, `userLikes`
become `erasedByStep: engagement`. Reference budgets move by +3 reads and +1 delete per deletion and +2 reads per export.

**D8. Rate limits and flag.** `LikePost`, `UnlikePost`, `RepostPost`, `UndoRepost` share one per-user bucket,
`RATE_LIMIT_LIKES_PER_MIN` (30). `FEATURE_ENGAGEMENT` (wire name `engagement`, default off) gates the four RPCs, the
quote path of CreatePost (metadata feature `quotes`) and viewer-flag hydration; FEATURE_POSTS is still required.
Cleanup (the job, the Eraser, the export section) is never flag-gated.

**D9. Notifications seam.** engagement declares `Events` (`Liked`, `Reposted`; nil means no-op) and posts keeps
`PostEvents.Created` for quotes (a QUOTE carries `Embedded.Author.UserID`). apiserver adapts both to
`notifications.Emitter.Emit` when ADR-0017 merges. Events are called after the commit, never inside it.

## Consequences
- Counters are exact except for the best-effort releases in D6 (reply/quote/repost counters after a DeletePost whose
  second write fails) and quote/reply counters when the quoting user deletes the account (accepted, as in P3).
  The invariant checker in the integration tests asserts likeCount and repostCount exactly.
- One like costs 4 writes (like, counter, userLikes, quota). Dropping the quota write needs a different quota design
  (rejected above); the 300-DAU write budget still has 64% headroom.
- A repost is a real post: it counts toward the posts quota and `postsCount`, appears in the Posts tab and Replies
  tab, and is exported by the posts section (the export gains `kind` and the original's id for REPOST and QUOTE
  docs only, so plain posts export byte for byte as before and the golden is not affected).
- Embedded author snapshots in other people's docs are not refreshed by P2's profile job. They are removed or
  tombstoned when the original goes away (delete, or its author's account deletion).
- A taken-down post (P7, ADR-0016) must also tombstone its embeds; this ADR provides `TombstoneQuotes` and the
  repost removal for that job, which is P7's follow-up and not done here.
- A user that blocks someone keeps that user's old likes on their posts (counts stay exact; no per-block clean-up).

## Handoff
- backend-developer: `docs/plans/engagement.md` tickets T2-T5.
- frontend-developer: regenerate the Dart client; flag `engagement`; actions on `embedded.post_id` for REPOST items;
  hide like/repost/quote when `enabled_features` lacks `engagement`.
- production-deployer: `FEATURE_ENGAGEMENT[_ALLOWLIST|_PERCENT]`, `QUOTA_LIKES_PER_DAY`,
  `QUOTA_NEW_ACCOUNT_LIKES_PER_DAY` as plain env vars (default off); no new topic or index.
- security-auditor: the post_delete job still never trusts the message (fresh gone-check, ids validated, only
  collections keyed by the post id are touched); likes of a user are only ever written by that user's own call.
