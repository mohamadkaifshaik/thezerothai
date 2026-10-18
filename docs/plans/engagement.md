# Likes, reposts and quotes (Phase 1 slice P5)
Plan owner: backend-developer (resumed from planner's P5 outline in `docs/plans/phase1.md`) · Date: 2026-10-11 ·
Stage: 0 (0 – ~300 DAU, pay-per-use only) · Flag: `FEATURE_ENGAGEMENT` (wire name `engagement`, default **off** in every environment)
Inputs: CLAUDE.md, ADR-0003, ADR-0004, ADR-0010 (D3, D6), ADR-0011, ADR-0017, **ADR-0018 (this slice, Accepted by the founder 2026-10-17)**,
`docs/plans/phase1.md` §P5, `docs/plans/media-uploads.md` ("post-delete job interface"), `docs/plans/replies-and-threads.md`,
`docs/plans/notifications.md`, `docs/reviews/cost-model.md`, `proto/dzeroth/engagement/v1/engagement.proto`.

## Goal
Users can like and repost posts and quote them, the counters are exact, the viewer sees their own like/repost state in
every list, and deleting a post or an account leaves no dependants behind.

## Status
| Ticket | Title | Owner | Status | PR |
|---|---|---|---|---|
| T1 | Contract and decisions: `engagement.v1` proto (additive), ADR-0018, this plan, data-model notes, regenerated Go/Dart code | backend (architect-delegated) | Merged (on main via integration PR #135; `proto/dzeroth/engagement/v1/engagement.proto`) | `feat/p5-engagement-contract` |
| T2 | Platform and posts seams: `FEATURE_ENGAGEMENT`, `quotas.likes`, `posts.Embedded`, `ViewerFlags` hydration (GetPost/GetThread/timelines), `EngagementWriter`, `RepostLinks`, publish `post_delete` for every post, relax the media job, composite handler | backend | Merged (on main via #135; `posts.WithViewerFlags`, `SetRepostLinks` in `apiserver.go:272-275`) | `feat/p5-engagement-backend` |
| T3 | `internal/engagement`: Like/Unlike/Repost/Undo, `userLikes` + cache, `engagement.Jobs`, Eraser, export section, `Events` seam | backend | Merged (on main via #135; `backend/internal/engagement/*`) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| T4 | Wiring and lifecycle: apiserver, rate-limit bucket, T11 rows, export golden, reference budgets, runbook, code map | backend | Merged (on main via #135; `apiserver/engagement_wiring.go`, `registerEngagementLifecycle` in `apiserver.go:308`) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| T5 | Tests: unit (fakes), emulator integration with budget assertions, invariant checker, 10-way concurrency | backend/tester | Merged (on main via #135; `apiserver/engagement_chain_integration_test.go`, `engagement/repo_integration_test.go`) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| T6 | Quotes: `CreatePost.quote_of_post_id`, quote counter, embedded tombstone on delete, notifications hook data | backend | Merged (on main via #135; `QuoteOfPostId` in `posts/server.go`) | `feat/p5-quotes` |
| T7 | Flutter: like/repost/quote actions, viewer flags, repost row, `engagement` gate | frontend | **Merged** (client PR #147) (like/unlike, repost/undo, quote composer, REPOST/QUOTE embeds with placeholders, optimistic + rollback, flag gate; deferred: likes list, REPOST-row counts, pruning own undone REPOST rows until refresh) | `feat/engagement-ui` |
| T7 follow-up | Quote UI hidden in MVP build (founder 2026-10-18); flip the switch (`kQuoteUiEnabled`, `app/lib/core/feature_flags/quote_ui.dart`) when quote UI ships. Required before any FEATURE_ENGAGEMENT ramp | frontend | **Done** (`feat/hide-quote-ui`) | `feat/hide-quote-ui` |
| T8 | Terraform env vars `FEATURE_ENGAGEMENT[_ALLOWLIST\|_PERCENT]`, `QUOTA_LIKES_PER_DAY`, `QUOTA_NEW_ACCOUNT_LIKES_PER_DAY` | deployer | **Terraform vars merged, NOT applied** (flag off; apply needs founder plan OK) | |
| T9 | Notifications: adapt `engagement.Events` and QUOTE `PostEvents.Created` to `notifications.Emitter` | backend | Merged (on main via #135; `engagementNotifier`, `postNotifier` in `apiserver.go:246,264`) | `feat/p5-engagement-impl` |
| T10 | P7: tombstone embeds of a taken-down post (uses `TombstoneQuotes` and the repost removal) | backend | Merged (on main via #135; `TombstoneQuotes` in `engagement/jobs.go`, `posts/repo_engagement.go`; opsctl takedown cleans up copies) | `feat/p5-engagement-impl` |
| T11 | D17: replies to a REPOST resolve to the original: one resolver shared by `replyParent` and `quoteTarget`, flip the REPOST-parent cases in `posts/service_replies_test.go`, `GetThread` on a REPOST id | backend | **Implemented** (founder approval 2026-10-17) | `TestCreateReply_ToARepostResolvesToTheOriginal`, `TestCreateReply_ToARepostNotFound`, `TestGetThread_OnARepostIdOpensTheOriginalsThread` |
| T12 | Orphaned likes: assert (not just log) the orphan count in `apiserver/engagement_lifecycle_integration_test.go` (~line 207) | backend/tester | **Implemented** (founder approval 2026-10-17) | `TestEngagementLifecycle_DeleteAccountWithEngagement` |
| T13 | Rule-4 replay tests (ADR-0018 "Rule 4"): LikePost replay after UnlikePost re-likes (documented); RepostPost replay while the repost exists = 0 writes, same `repostPostId` | backend/tester | **Implemented** (founder approval 2026-10-17) | `TestLike_ReplayAfterUnlikeReLikes`, `TestRepost_ReplayWhileRepostExistsIsTheSameId`, `TestRepo_Rule4Replays` |

T2-T5 are one PR on purpose: the seams in posts, the engagement module, the job and the lifecycle rows are consumed by
each other's tests (the invariant checker needs all four RPCs and the job) and splitting them would leave a PR that
cannot be exercised end to end. Quotes (T6) are a separate PR because they touch only the CreatePost path and depend on
T2's `posts.Embedded`. T1 merges first, then T2-T5, then T6. Nothing is user visible until `FEATURE_ENGAGEMENT` is on.

## Decisions (delegated 2026-10-10)
The founder delegated the open P5 choices. Each is reversible by config unless noted.

| # | Decision | Why | Revisit when |
|---|---|---|---|
| D1 | **One flag, `FEATURE_ENGAGEMENT`**, gates the four RPCs, the quote path of CreatePost (`metadata["feature"]="quotes"`, as P1 already answers) and viewer-flag hydration. FEATURE_POSTS is still required. Cleanup (job, Eraser, export) is never flag-gated. | One switch, one rollout (`flag-rollout`); no half-enabled state. | |
| D2 | **A new `EngagementService`** with `LikePost`, `UnlikePost`, `RepostPost`, `UndoRepost`; **no `ListLikers`**. | Additive proto. A liker page is one query + up to 50 profile reads + block filtering; nothing in Phase 1 needs it (phase1.md: "only if cheap"). | A "liked by" screen is designed. |
| D3 | **Natural-key idempotency**: `likes/{postId}_{uid}`, `reposts/{postId}_{uid}`; `idempotency_key` is validated for format only. A bend of CLAUDE.md rule 4, approved by the founder 2026-10-17 (ADR-0018 "Rule 4": RepostPost carve-out, risks, client rule, required tests T13). | State-setting ops keyed by (post, caller): a replay is the same effect. Same precedent as DeletePost (ADR-0010 D4), and it saves the 24 h idempotency doc (1 write + 1 TTL delete) per like. | |
| D4 | **Acting on a REPOST id acts on its original** (like, repost, quote, unlike). `UndoRepost.post_id` is the original (clients use `embedded.post_id`). | X behaves this way; keeps counters on one doc. | |
| D5 | **A repost is a real post**: a `kind=REPOST` doc, root (`isReply=false`), own Snowflake id, embedded snapshot, counts toward the `posts` quota (100/day) and `users.postsCount`. Own posts and replies can be reposted; a REPOST of a REPOST resolves to the original. | Pull timelines include it with no new query (ADR-0003). One quota for "things that appear in followers' feeds". | |
| D6 | **Likes quota 500/day, 100/day for accounts < 24 h** in `quotas/{uid}.likes`; unlike and undo are free. 1 read + 1 write per like. | `free-tier-budget` §4. An in-memory cap is not a bound (30/min = 43k likes/day = 170k writes for one account). | Reads become the binding quota (they already are at ~217 DAU): move the likes counter into the `userLikes` write (saves 1 write, not a read). |
| D7 | **`userLikes/{uid}`**: `recent[]` (<= 1,000), `recentReposts[]` (<= 500), blind `ArrayUnion`/`ArrayRemove`, cached 60 s per instance, updated in place by own writes. Older likes show as not liked. A failed read degrades to false flags. | 1 read hydrates a whole page (ADR-0004). Reading it inside Like to trim would add a read to every like. | Users with > 1,000 likes complain. |
| D8 | **Trim is best effort**: a cached copy over cap + 100 gets a follow-up `ArrayRemove` of its oldest 100 (1 write per ~100 likes). Two transforms on one field cannot share a write. | No read on the like path; the doc stays under ~60 KB. | |
| D9 | **One rate-limit bucket** (`RATE_LIMIT_LIKES_PER_MIN`, 30) shared by the four RPCs. | The config knob already exists and was meant for this. | |
| D10 | **post_delete is published for every deleted post** and handled by a composite (media step, engagement step). The media job acknowledges a message without images before reading anything. | media-uploads plan steps 1-3 for P5. | |
| D11 | **The job works in pages with a bounded number of pages per delivery, then republishes** and acknowledges. | A post with thousands of likes must not dead-letter by nack count (`maxDeliveryAttempts`). | |
| D12 | **Quote embeds are one-level frozen snapshots**; on delete of the original the embed becomes `{postId, unavailable}` and the REPOST docs of it are removed. | The proto already has `EmbeddedPost.unavailable`. A repost of a deleted post has nothing to show. | |
| D13 | **Block/mute/visibility**: the target of like/repost/quote passes `viewable` (the GetPost rules, incl. `!Visible()` once P7 lands). In feeds a REPOST or QUOTE is dropped when its embedded author is blocked or muted by the viewer or blocks the viewer; GetPost/GetThread drop it only for a blocking author (same as a direct post). Unlike/Undo never need visibility. | No content of a blocked user leaks through a copy. | |
| D14 | **Account deletion also removes the copies**: the posts step pages `embeddedAuthorId == uid` and deletes REPOST docs / tombstones QUOTE docs of other users. | Otherwise the deleted user's text survives inside other people's docs (privacy; ADR-0011 Q10 would need a new allowance). | |
| D15 | **Notifications are a seam, not a dependency**: `engagement.Events` (nil = no-op); QUOTE notifications derive from `PostEvents.Created` (a QUOTE carries `Embedded.Author.UserID`). Wiring waits for P6. | `notifications.Emitter` is in open PR #122. | P6 merges (T9). |
| D16 | **Quote/reply counters on account deletion are not decremented** (accepted drift, the P3 precedent); like and repost counters are exact. | A blind update per quote/reply in the purge costs a write each for a cosmetic number. | |
| D17 | **Replies to a REPOST resolve to the original** (founder approval 2026-10-17; decision brief item D10; **implemented**, T11): one resolver shared with `quoteTarget`, +2 cold reads; the REPOST's own counters stay 0; original gone => NOT_FOUND; the client keeps the "Reposted by" context. | Counters and threads live on one doc, as D4. | |

Decision numbers: ADR-0018 maps D1-D17 to its sections ("Numbering" table); code citing "ADR-0018 D10"-"D16" means
these plan numbers. Orphaned likes of a deleted user's posts are accepted (founder approval 2026-10-17, ADR-0018
"Orphaned likes", T12).

### Not decided here (needs the founder)
- ~~Accepting ADR-0018~~: accepted by the founder 2026-10-17, including the rule-4 bend (D3).
- Terraform env vars and the flag ramp (T8).

## Contract changes
- **New**: `dzeroth/engagement/v1/engagement.proto` (service + messages). `buf breaking` against `origin/main` is clean.
- **Comment-only**: `posts.proto` (CreatePost quotes, DeletePost job, GetPost flags, PostKind, EmbeddedPost, PostView)
  and `timeline.proto` (viewer flags with the flag on). No field added, renumbered or removed.
- No new field on `Post`/`PostView`/`EmbeddedPost`: everything the client needs already exists.
- Error mapping: NOT_FOUND "post not found" (byte-identical for every cause), RESOURCE_EXHAUSTED + QUOTA_EXCEEDED
  `metadata["quota"]="likes"` (or `posts` for reposts), FEATURE_DISABLED, VALIDATION, IDEMPOTENCY not applicable (D3).

## Data model (`firestore-data-model` skill updated in T1)
| Collection | Shape | Written by | Index |
|---|---|---|---|
| `likes/{postId}_{uid}` | postId, uid, createdAt | LikePost (`Create`), UnlikePost / Eraser / job (delete) | automatic: `postId ==`, `uid ==` (+ `__name__` ordering for the export) |
| `reposts/{postId}_{uid}` | postId, uid, repostPostId, createdAt | RepostPost (`Create`), UndoRepost / DeletePost / Eraser / job (delete) | automatic: `postId ==`, `uid ==` |
| `userLikes/{uid}` | recent[], recentReposts[], updatedAt | Like/Unlike/Repost/Undo (blind array ops), Eraser (delete) | none (arrays exempt) |
| `posts/{id}.embedded` + `quoteOfId` / `repostOfId` / `embeddedAuthorId` | embedded{postId, author, text, media[], createdAt, unavailable}; `embeddedAuthorId` is the top-level copy of the embedded author id (the `embedded` map is exempt from indexing) | RepostPost, CreatePost (quote), tombstone job | automatic: `quoteOfId ==`, `embeddedAuthorId ==` |
| `quotas/{uid}.likes` | int, resets with the IST day | LikePost | none |

No composite index and no `firestore.indexes.json` change. The new queries are single-equality filters.

## Worst-case Firestore reads/writes per RPC (kept in sync with the integration assertions)
"Cold" includes the account-status interceptor's `users/{uid}` read (1); warm is 0. A REPOST id as the target adds 2
reads (the original and its author). `+1 overflow` is the author's graph when the caller's `blockedBy` overflowed.
A QUOTE or REPOST target (or a GetPost/GetThread row) also checks its embedded author against the same caller graph
snapshot: 0 extra reads, and on a `blockedBy` overflow +1 for the embedded author's graph, so the overflow worst case is
+2 (post author, embedded author). The caller's own QUOTE/REPOST is exempt (D13, same as a direct post): no embed check
and no extra read. GetThread context rows (parent, root) check the embedded author against the snapshot only (0 reads,
fail closed on overflow); the timelines filter copies against the snapshot already read (0 reads), and a caller's own
Posts tab skips the filter entirely.

| RPC | Reads cold / warm | Writes / deletes | Asserted by |
|---|---|---|---|
| LikePost (first like) | 5 (+1 on blockedBy overflow (author graph), +1 more for a QUOTE/REPOST (embedded author), +2 REPOST id) / 1: interceptor 1, post 1, author users 1, caller graph 1, `quotas` 1 in the transaction | 4: like, `likeCount`, `userLikes`, quota; replay 0 writes (same reads) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| UnlikePost | <= 3 / 0: interceptor, the post for the returned counts (cache first), +1 for a REPOST id | 2 + 1 delete (`likeCount`, `userLikes`; the like doc); no-op 0 | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| RepostPost (first) | 5 (+1 on blockedBy overflow (author graph), +1 more for a QUOTE/REPOST (embedded author), +2 REPOST id) / 1: as Like, `quotas` 1 | 6: reposts doc, REPOST post, `repostCount`, `users.postsCount`, `userLikes`, quota; replay +1 read (the reposts doc), 0 writes | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| UndoRepost | 3 / 1: interceptor, `reposts/{id}`, the original (cache first) | 3 + 2 deletes (`repostCount`, `postsCount`, `userLikes`; reposts doc, REPOST post); no-op 0 | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| CreatePost (quote) | 17 cold / 2 warm (root post 14/2 + quoted post, its author, caller graph) | 5 (idempotency, post, `postsCount`, quota, quoted `quoteCount`) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| CreatePost (reply to a REPOST, D17) | 16 cold / 2 warm (reply 14/2 + the original and its author: +2 cold like a quote of a REPOST) | 5 (idempotency, post, `postsCount`, quota, the original's `replyCount`; the REPOST's counters stay 0) | `TestCreateReply_ToARepostResolvesToTheOriginal` |
| GetThread (REPOST id, D17) | 40 cold (38 + the original and its author), warm: the query only | 0 | `TestGetThread_OnARepostIdOpensTheOriginalsThread` |
| DeletePost (REPOST) | 2 / 0 | 1 write (`postsCount`) + 2 deletes (post, reposts doc) + best effort 2 writes (`repostCount`, `userLikes`) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| DeletePost (QUOTE) | 2 / 0 | 1 + 1 delete + best effort 1 (`quoteCount`) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| Viewer flags (GetPost, GetThread, home, user timeline) | +1 `userLikes` cold, +0 warm (60 s cache) | 0 | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| `post_delete` job, no dependants | 1 post + 3 queries (1 each) = **4** (the media step reads nothing without images) | 0 | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| `post_delete` job, L likes + R reposts + Q quotes (+ n images) | 4 + L + R + Q (+ 1 + n) | L + 2R deletes, R + Q writes (R `postsCount`, Q embeds) | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| Eraser `engagement` step, L likes + R reposts | 2 minimum + L + R | L + R writes (counters) + L + R + 1 deletes (+ `userLikes`) | `TestAccountLifecycle_ReferenceAccountBudgets` (+2 reads, +1 delete) |
| Eraser `posts` step, embeds | +1 read minimum (query on `embeddedAuthorId`), + 1 per copy | 1 delete or 1 write per copy (+ reposts doc and `postsCount` per REPOST) | same (+1 read) |
| Export section `engagement` | 2 minimum (likes, reposts) + 1 per doc, pages of 500 | 0 | `TestAccountLifecycle_ReferenceAccountBudgets` (+2 reads) |

Every query has a `Limit` (the job and Eraser pages are 100-200, an ops path under the ADR-0003 purge rule; RPC pages
do not exist). No reads in loops: the job and the Eraser read one page per query and write per document without
re-reading. Per-document counter updates are atomic pairs with the doc delete.

## Cost line (Stage 0, 300 DAU; 5 likes, 0.5 unlikes, 0.3 reposts, 0.1 quotes, 0.05 deletes per DAU)
| Resource | Per DAU/day | At 300 DAU/day | Free | Notes |
|---|---|---|---|---|
| Firestore reads | ≈ 10.5 (likes 6.5, hydration 3, job 0.3, reposts 0.4, rest 0.3) | 3.2k (6%) | 50k | Total product is already over the read quota at 300 DAU (`cost-model.md` §3); this adds about +$0.06/month. The cost-model likes rows assumed 0 reads. |
| Firestore writes | ≈ 23 (likes 20, reposts 1.8, unlikes 1, rest 0.3) | 6.9k (35%) | 20k | Same as the `[planned]` likes row (4 writes per like); the whole product stays free to ~630 DAU. |
| Firestore deletes | ≈ 0.7 | 0.2k (1%) | 20k | |
| Pub/Sub | 0.05 messages (< 200 B) | 15 | 10 GiB | |
| Storage | 2 x ~100 B per like/repost + `userLikes` ~30 KB per active user | < 10 MB/month | 1 GiB | |

No fixed-cost resource is added; nothing here can step to a fixed fee.

## Acceptance criteria and where they are tested
| Criterion (from `phase1.md` P5 "Done when") | Test |
|---|---|
| A like is idempotent under 10 concurrent calls | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` (one like doc, `likeCount == 1`, 0 or 1 quota unit) and the unit test `TestLike_ConcurrentCallsCollapseIntoOneTransaction`; leader/follower cancellation: `TestLike_LeaderCancellationDoesNotFailFollowers`, `TestLike_FollowerCancellationDoesNotFailTheLeader` |
| Counters are exact (an invariant checker, like graph's) | `requireEngagementInvariants` after every integration scenario: `likeCount == |likes|`, `repostCount == |reposts|`, every reposts doc has its REPOST post and vice versa |
| Hot-doc rule documented | ADR-0003 §counters (unchanged) and this plan: <= 1 sustained write/s per post; sharding only through an ADR with a measured trigger |
| Block / mute / hidden rules honoured | `TestGetForViewer_EmbeddedAuthorBlock`, `TestGetForViewer_OwnCopyIsExempt`, `TestGetThread_ContextCopyOfABlockingAuthorIsATombstone`, `TestEmbedAllowed`, `TestFilterEmbeds_IndependentOfFlag`, `TestTimelines_EmbedFilterAppliesWithFlagOff`, `TestUser_OwnProfileKeepsOwnCopyWithoutGraphRead` |
| Account deletion and export cover likes/reposts | T11 rows, `TestAccountLifecycle_*` golden and residue sweep, `TestEngagementLifecycle_DeleteAccountWithEngagement`, `TestPurgeUser_FallbackAndExport`, `TestPurgeCopies_Integration` |
| Deleting a post removes its likes, reposts and tombstones its quotes | `TestEngagementChain_LikeRepostQuoteAndDeleteJob` |
| Budget numbers asserted | the table above |

## Test inventory
- Unit (fakes, table-driven): `internal/engagement/{service,cache,server}_test.go`,
  `internal/posts/{service_delete,service_replies}_test.go`, `internal/timeline/{embed_filter,embed_rpc}_test.go`,
  `internal/media/jobs_test.go` (empty media is a noop), `internal/apiserver/{flags_wiring,guard}_test.go`.
- Integration (emulators, `//go:build integration`): `internal/engagement/repo_integration_test.go` (`TestRepo_LikeRepostCycle`, `TestRelease_NotFoundFallback`, `TestJobs_NoProgressGuard`) (budgets,
  invariants, concurrency, job, Eraser, export), `internal/apiserver/engagement_chain_integration_test.go` (RPCs through
  the real interceptors, flag off, timelines with flags), the existing lifecycle tests (golden regenerated, reference
  budgets bumped deliberately: +3 reads and +1 delete for deletion, +2 reads for export).

## Risks and follow-ups
- **Cache staleness of counts**: a like by someone else is visible to a viewer after at most 60 s per instance
  (the post cache TTL). Accepted (ADR-0010).
- **Reads are the binding quota** (cost-model §3). Levers, in order: (1) move the likes quota into the `userLikes`
  write (saves 1 write per like, no read); (2) drop the quota read by using the cached `userLikes` day counter;
  (3) hydrate flags only on the first page of a refresh.
- **Embeds are not refreshed** when the original author renames or changes their avatar (frozen snapshot, D12).
- **P7 takedown** must tombstone embeds of a hidden post (T10); until then a taken-down post's text remains inside
  quotes and reposts created before the takedown. Flagged to the P7 owner.
- A `post_delete` publish failure leaves likes/reposts of a deleted post until a reconciliation sweep (none at Stage 0;
  the orphan docs hold only other users' ids and are erased with those users).
- Consider detaching `Repo.Repost` with a single overall deadline (`repostTimeout` <= `rpcDeadline`) and wrapping the replay `Get`; and detaching ctx in apiserver `emitterSlot.emit` for quote/mention/follow.
