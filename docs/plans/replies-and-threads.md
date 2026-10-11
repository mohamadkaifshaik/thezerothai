# Replies and threads (Phase 1 slice P3)
Plan owner: backend (P3 resume) · Date: 2026-10-11 · Flag: `FEATURE_REPLIES` (wire name `replies`, default **off** everywhere) ·
Stage: 0 (0 – ~300 DAU, $0)
Inputs: CLAUDE.md, `docs/plans/phase1.md` (P3), `docs/plans/posts-and-timeline.md`, ADR-0004, ADR-0010 (D2, D6, D16),
`proto/dzeroth/posts/v1/posts.proto`, `backend/internal/posts/*`.

## Goal
Users can reply to a post and read a post with its conversation. Replies are ordinary `posts` docs with `isReply = true`;
they are never fanned out and never appear in Home or the Posts tab (the `isReply == false` filters already in ADR-0010).

## Contract (all additive, `buf breaking` clean against `origin/main`)
- `CreatePost.reply_to_post_id` is honoured when the flag is on for the caller; flag off keeps `FEATURE_DISABLED`
  (`metadata["feature"]="replies"`, 0 reads).
- `GetThreadResponse.parent_unavailable = 6`, `root_unavailable = 7` (new fields; nothing renumbered). `GetThread` stops
  returning UNIMPLEMENTED.
- No new Firestore collection, field or index: `posts.replyToId/replyToHandle/conversationId/replyCount/isReply` and the
  `conversationId ASC, createdAt ASC` index already exist in the data model.

## Decisions (delegated 2026-10-10)
1. **Flag.** One new flag `FEATURE_REPLIES[_ALLOWLIST|_PERCENT]`, independent of `FEATURE_POSTS` but requiring it (the posts guard runs first). Default off.
2. **Reply target visibility = GetPost rules** (`service.viewable`, shared with GetPost and GetThread's focal post). Missing, deleted, hidden, suspended author or author who blocks the caller are all the one NOT_FOUND "post not found". A caller who blocked/muted the author may still reply.
3. **Conversation.** A reply copies the parent's `conversationId` (a root's own id for a first-level reply); `replyToHandle` is the parent author's handle at reply time.
4. **replyCount.** Incremented with `FieldValue.Increment` inside the CreatePost transaction (an `Update` with implicit Exists: a parent deleted in between fails the commit with `ErrParentGone` -> NOT_FOUND, 0 writes). Decremented best effort after a reply is deleted (cosmetic if it fails). Replies stay out of the author-recent cache entry.
5. **GetThread page.** Default 10 (cost-model lever 6.2), clamped to 1..30 (below the CLAUDE.md max of 50, keeps the worst case inside the 55-read plan budget). Opaque HMAC page token bound to caller + focal post, 24 h TTL. Ascending `createdAt, __name__`; the root is skipped by starting strictly after its Snowflake position (no read, works when the root is deleted).
6. **Filtering.** Replies by authors the caller blocks or mutes, or who block the caller, are dropped after the read (a page may be short; a full page always carries a next token). `blockedBy` overflow fails closed for parent/root context (no per-row author-graph read).
7. **Tombstones.** An unavailable parent/root is not an error: returned unset with `parent_unavailable`/`root_unavailable = true`, never distinguishable by cause.
8. **Idempotency.** The request hash now includes `reply_to_post_id`, so reusing a key for a different parent is `IDEMPOTENCY_KEY_REUSED`.
9. **Replies tab** needs no backend change: `GetUserTimeline(include_replies=true)` already runs Q-R.
10. **Export** includes `replyToPostId` for the user's own replies.

## Worst-case Firestore reads/writes per RPC
Reads include the account-status interceptor's caller `users` read when cold. Asserted in
`backend/internal/posts/replies_integration_test.go` (budget assertions).

| RPC | Reads cold | Reads warm | Writes | Notes |
|---|---|---|---|---|
| CreatePost (reply) | 15 | 3 | 5 | interceptor 1, parent 1 + its author 1 + caller graph 1 (cached by the read path), <= 10 mention `handles` in one `GetAll`, idempotency + quotas in the txn; writes: idempotency, post, `users.postsCount`, quotas, parent `replyCount`; replay 0 writes; parent gone 0 writes |
| CreatePost (reply, flag off) | 0 | 0 | 0 | FEATURE_DISABLED before any read |
| GetThread (focal is a reply, page 30) | 38 | 1..30 | 0 | interceptor 1 + focal 1 + focal author 1 + caller graph 1 (+1 author graph on `blockedByOverflow`) + parent/root 2 (one `GetAll`) + <= 2 context authors (one batch) + one `Conversation` query `Limit(page)`; no N+1 |
| GetThread (focal is a root, default page 10) | 14 | <= 10 | 0 | no context reads |
| DeletePost (reply) | 2 | 0 | 2 + 1 delete | post delete (Exists), `postsCount` -1, parent `replyCount` -1 (blind Update, 0 if parent gone) |
| Replies tab | unchanged (Q-R, ADR-0010 D16) | | 0 | |

Every query has a `Limit` (<= 30), cursors are opaque and bound; no reads inside loops.

## Cost line
Unchanged from `phase1.md` P3: about +3.9k reads/day at 300 DAU (P1 + P3 ≈ 117% of the free read quota at 300 DAU, about
$0.16/month over, inside founder decision D1). The flag is off, so a rollout is the only thing that spends it. No new
fixed-cost resource, no new topic, no new index.

## Tickets
| # | Ticket | Owner | Status |
|---|---|---|---|
| T1 | Proto: additive GetThread fields and comments | backend | Done (this PR) |
| T2 | `FEATURE_REPLIES` config + registry + guard | backend | Done |
| T3 | CreatePost reply path (parent check, conversation, replyCount in txn, idempotency hash) | backend | Done |
| T4 | GetThread service + `Conversation` repo query (Q-T) | backend | Done |
| T5 | Reply delete releases parent `replyCount`; export field | backend | Done |
| T6 | Unit tests (fakes) + emulator integration with budget assertions | backend/tester | Done |
| T7 | Flutter: thread screen, reply composer, tombstones, `PostsFeatureGate`-style gate for replies | frontend | Open (needs regenerated Dart client; separate PR) |
| T8 | Flag ramp (off -> allowlist -> percent -> on) | founder | Open |

## Done when
Thread order is chronological; blocked/muted authors are dropped; budget assertions pass; deleting the parent yields a
tombstone; the reply count converges after create/delete (including concurrent creates).
