# 0025. Private accounts and follow requests (W3 Part B; amends ADR-0008 D1)
Status: Accepted (founder, 2026-10-27, by merging PR #325 with every recommended default)
Date: 2026-10-27
Deciders: architect (proposal); founder. Merging this ADR is the founder's acceptance **and** the founder's explicit
reversal of ADR-0008 D1, the deferral the founder accepted on 2026-09-28. The first Part B implementation PR flips
the status (W3-25) and adds dated pointer notes to ADR-0003 and ADR-0008 (D16). Eight founder questions are listed
below, each with a recommended default.
Implementation notes 2026-10-28 (W3-25a): "Implementation notes (W3-25a, 2026-10-28)" at the end answers the plan's
design points AQ1 to AQ6. Every default stands; no decision of this ADR changed.

Plan: `docs/plans/ui-w3-profile-graph-completion.md`, Part B, tickets W3-3 (this ADR) and W3-25 to W3-38; founder
question 1. Related ADRs:
- ADR-0003: the data model and its visibility-job paragraph, which D3 supersedes.
- ADR-0008: D1, D2, D4, D6, D9 and D10.
- ADR-0009: the Unfollow invariant; reopen criterion 5 is triggered and re-checked in D9.
- ADR-0010: D6 visibility matrix, D14 tokens.
- ADR-0011: erasers and export.
- ADR-0016: the detached removal-log read, the precedent for D3.
- ADR-0017: notification ids and suppression.
- ADR-0018: reposts and quotes.
- ADR-0021: I-3 quota kinds.
- ADR-0023: list drop rules, and the appended eraser step precedent.
- ADR-0024: Part A; its pin, tabs and likes list call this ADR's predicate.

**Sequencing: this ADR must be accepted before the W4 search ADR.** W4 adds hashtag and people search over posts by
any author. If it lands first, search either leaks protected posts or has to carry its own copy of the rule. With this
ADR accepted, W4 calls the D3 predicate and adds 0 per-row reads.

## Context
On X a protected account's posts are visible only to the account and its approved followers. A follow becomes a
request the account accepts or declines. The profile header stays public: name, handle, bio, counts and a lock badge.
The posts, the followers and following lists, and the pinned post are not.

Today (`main` 180080f) the contract has the pieces as stubs only:
- `Profile.is_private`, `UpdateProfileRequest.is_private` and `FOLLOW_STATE_REQUESTED` exist.
- `ListFollowRequests` and `RespondToFollowRequest` exist and always return FEATURE_DISABLED (ADR-0008 D1).
- `UpdateProfile(is_private=true)` is rejected.
- Nothing writes `followRequests/*` or `graph.requested[]`. The data model reserves both (ADR-0003), and the index
  `followRequests (followeeId ASC, createdAt DESC)` and the `graph.requested` fieldOverride already exist.

The hard part is not the request lifecycle. It is that **every read path** must apply one rule, and that rule needs
to know whether an arbitrary author is protected:
- Home only shows followed authors, so its primary rows are safe by construction. Its REPOST and QUOTE embeds are not.
- GetThread replies, ListBookmarks, ListLikedPosts, the Reposts tab and W4 search show posts by authors the viewer
  does not follow.

The pending security review of W2 (`docs/reviews/security-review-w2.md`, finding L-2, on another branch) asks for
exactly this. ListBookmarks must drop a post that is not public unless the viewer follows its author, once private
accounts exist.

Stage 0 numbers are as in ADR-0024 and `docs/reviews/cost-model.md`. With W2 and W3 Part A on, the product uses 288.9
reads per DAU per day, so free reads end at about 173 DAU and every added read is billed.

## Options
**(1) How a read path learns "this author is protected".**

| | A. Per-row lookup | **B. Instance-cached protected-author set (recommended)** | C. ADR-0003 visibility job |
|---|---|---|---|
| Mechanism | Every row by a non-followed, non-own author gets a batched, status-agnostic `users/*` read of `isPrivate`, cache-first 60 s | Identity keeps one doc listing the protected uids, written in the same transaction as `users.isPrivate`. Each instance reads it at most once per `CACHE_TTL` on a detached counter (the ADR-0016 removal-log pattern). The predicate is a map lookup | On a toggle, rewrite `visibility` on all of the author's posts and on every REPOST/QUOTE copy (`embeddedAuthorId == uid`). Readers check the stored field |
| Per-request reads | Up to +page cold on GetThread, ListBookmarks, ListLikedPosts, the Reposts tab and Home embeds; +page on every W4 search page | **+0 on every path** | +0 |
| Background cost | 0 | ≤ 1 read per instance per minute while serving: ≤ 4,320/day at 3 instances, typically about 1,000/day | O(posts + copies) writes per toggle: 300 posts = 300 writes; a 10,000-post author = 50% of the free daily writes, throttled to ≤ 5,000 per run |
| Reads per DAU per day (estimate) | about +14 at every scale | about +3.2 / 2.4 / 1.4 at 300 / 1,000 / 3,000 DAU, falling per DAU as traffic grows | about +0 reads, about +0.6 writes |
| INR/month at 300 / 1,000 / 3,000 DAU | about 4.2 / 14.2 / 42.5 | about 1.0 / 2.4 / 4.4 (set refresh only) | about 0 / 1.8 / 5.4 |
| Cost while **no** account is protected | the full per-row cost from the day Part B ships, unless gated by a flag. Gating enforcement by a flag is forbidden: D12 and ADR-0008 D6 say ramping `private_accounts` down must never un-protect anyone | 1 read per instance per minute (an empty or missing doc) | 0 |
| Correctness window after a toggle | 60 s (cache) | 60 s (cache) | minutes to hours (job run, throttle, retries). Going private leaves posts PUBLIC until rewritten, the worst case for a user escaping harassment. A failed job leaks indefinitely |
| Scale ceiling | none | one doc: about 30 B per uid, so about 30k uids per 1 MiB; capped at 20,000 (D2) | none |

- **A** pays on every page, forever, from the day it ships, to protect what is at Stage 0 a handful of accounts.
- **C** is cheap in steady state but wrong in exactly the window that matters, and it needs a job, a throttle and a
  stuck-job runbook.
- **B** costs a bounded background read and 0 per request. It is correct within the same 60 s as every other cached
  rule (ADR-0008 D8), and it gives W4 search and W5 lists the rule for free.

**The deciding constraint is not money:** A and B differ by tens of INR a month even at 3,000 DAU. It is that
enforcement must not be flag-gated and should cost about 0 while nobody is protected. B meets that by construction.

**(2) What happens to pending requests when an account goes public.**
- **A. Accept them all, through an async job (recommended, plan default).** Requesters wanted to follow, and the
  account is now public. This is X's and Instagram's behaviour.
  - Cost at the 500-request worst case: 1,000 reads, 1,505 writes, 500 deletes, once per toggle. The toggle quota in
    D8 bounds it.
- **B. Decline them all.** 500 writes and 500 deletes; requesters must re-follow.
- **C. Leave them pending.** The requests screen would show requests to a public account, and the follow button would
  stay "Requested" forever. Rejected.

**(3) Reposts and quotes of a protected post.**
- **A. Refused for everyone but the author (recommended, X behaviour).** A REPOST copies the post into the reposter's
  feed, where the reposter's followers, who are not the author's, would see it. 0 cost.
- **B. Allowed, filtered at read time by the embed rule.** It works, but it creates copies of protected text in other
  users' docs (rule 10 residue), and it relies on the embed filter alone.

## Decision
**D1. Private accounts ship in W3 Part B, reversing ADR-0008 D1** (founder question 1).
- `UpdateProfile(is_private=true)` is accepted while `private_accounts` is on for the caller (D12).
- `is_private=false` is always accepted.
- The ADR-0008 D1 legacy rule ("Follow on a stored `isPrivate` target → FEATURE_DISABLED") is replaced by D7.

**D2. Data model.**
- **`users/{uid}.isPrivate`** (exists; identity). The single source of truth.
- **`privacy/protectedAuthors`** (new; identity owns it): `{uids[] (protected uids), updatedAt}`.
  - It is a **derived index** of `users.isPrivate`, written only by identity, always in the same transaction as the
    `isPrivate` change: `ArrayUnion` on protect, `ArrayRemove` on unprotect or account deletion.
  - It holds no other field.
  - `uids` is exempt from indexing (fieldOverride, D15). Without the exemption, 20,000 entries would hit Firestore's
    40,000 index-entries-per-document limit and cost an index write per entry.
  - **Cap `PROTECTED_AUTHORS_MAX` = 20,000** (about 600 KB). At the cap, protect is FAILED_PRECONDITION
    LIMIT_REACHED `limit=private_accounts`. At Stage 0 (well under 10,000 users) it cannot be reached. The Stage-ladder
    trigger is 10,000.
  - The doc is created by the first protect (`Set` with merge on a missing doc, inside the transaction) and never
    deleted.
- **`followRequests/{requesterId}_{targetId}`** (graph; the ADR-0003 path): `{followerId, followeeId, createdAt}`.
  - The natural key gives replay for free (`Create` + AlreadyExists).
  - `_` is safe as the separator (ADR-0008 A3).
- **`graph/{uid}.requested[]`** (exists; cap 500, index-exempt): the caller's **outgoing** pending requests. It is in
  the caller's cached snapshot, so "Requested" costs 0 reads everywhere.
- **`quotas/{uid}.privacyToggles`** (new daily kind, `quota.PrivacyToggles`). Its `Record` field and its
  `valueFor`/`increment` cases ship together (ADR-0021 I-3).
- **`posts.visibility`** is **not** written by this ADR. Stored docs stay `PUBLIC`. The wire `Post.visibility` is
  computed: `VISIBILITY_FOLLOWERS` while the author is in the set.
- **Never filter on stored `posts.visibility`.** It is always `PUBLIC`, so a test such as "drop `visibility != PUBLIC`
  unless following" (the literal wording of security finding W2 L-2) would be a silent no-op. L-2 is closed by
  `Audience.Decide` (D3, D4).
- **`REQUESTED` everywhere.** The shared `relationshipFor` helper (ADR-0008 D4) reports `FOLLOW_STATE_REQUESTED`
  when the target is in the caller's `requested`, so GetRelationships, every `UserListItem.relationship`, the Follow
  and Unfollow responses, GetProfileRelationship and suggestions all show it, at 0 reads.

**D3. The one predicate: read time, Option 1B.** Every read path calls one `posts`-side function, never its own copy.
- **The rule.**
  - **`posts.Audience.CanSee(viewer, author, snap, set) bool`** = `author == viewer || !set.Has(author) ||
    snap.Following[author]`. It is pure: no I/O and no error.
  - `snap` is the viewer's `graph.Snapshot` (already read by every path that filters blocks).
  - `set` comes from **`identity.ProtectedAuthors.Current(ctx) (ProtectedSet, error)`**, a new identity interface
    implemented by the instance-cached loader.
  - posts already depends on identity's `api.go` interfaces (ADR-0002), so there is no cycle.
- **The decision.** `posts.Audience.Decide(ctx, viewer, snap, p *Post, surface)` wraps it for a whole post. It covers:
  - moderation (`Visible()`);
  - ADR-0010 D6 block and mute by surface;
  - `CanSee` on `p.AuthorID`;
  - `CanSee` on `p.EmbeddedAuthor()`.

  It returns Show, Drop, NotFound, or Show with the embed state (BLOCKED / MUTED / PROTECTED). Every path below uses
  it. `Engagement.Viewable` becomes a call to it.
- **The loader.**
  - **Lazy.** It reads `privacy/protectedAuthors` only when a request needs `set` and the cached copy is older than
    `CACHE_TTL` (60 s). One read per instance per minute at most: ≤ 1,440/instance/day, ≤ 4,320/day at max instances.
  - **Singleflight.** Concurrent requests share one refresh.
  - **Detached accounting.** The refresh runs on a detached `budget.Counter`, logged as `protected_set_reads`, **not**
    charged to the caller's read budget (the ADR-0016 D10 removal-log precedent). So the predicate adds 0 to every
    per-RPC ceiling and to `budgettest`.
  - **Missing doc.** A missing doc is an empty set.
  - **Only when needed.** `set` is consulted only for an author who is neither the viewer nor followed. A request whose
    rows are all own or followed authors, such as most Home pages, never triggers a refresh.
- **Fail closed.** A failed refresh keeps serving the last good set for at most `PROTECTED_SET_MAX_STALE` (10 min),
  with WARN `protected_set_stale`. After that, or if the instance never loaded a set, any request that needs `set`
  returns UNAVAILABLE (retryable), with ERROR to Error Reporting. **An unknown set never reads as "everyone public".**
- **Staleness: a toggle applies within 60 s across instances**, immediately on the instance that committed it (cache
  updated in place).
  - For that window a non-follower on another instance may still see the posts of an account that just went private.
    They were public a minute earlier.
  - For the same window, a just-unprotected account's posts stay hidden. That fails closed.
  - This is the same bound as blocks (ADR-0008 D8).
- **Own and followed authors are unaffected.** Paths that already read the author's `users` doc (GetPost, `Viewable`,
  GetUserTimeline, GetProfile) still decide from `set` through the same predicate, never from `users.isPrivate`, so
  there is one rule and one source.
- **Supersedes:**
  - ADR-0003's "Visibility changes (private ↔ public) rewrite **all** of the author's posts (1 toggle/day)";
  - the `identity.proto` UpdateProfile comment "enqueues the visibility job (writes = author's post count; limited to
    1 toggle/day)";
  - ADR-0008 D1's "needs its own ADR section on the visibility job".

  No visibility job is built.
- **Hot doc (rule 3).**
  - The set doc takes 1 write per toggle, far below the 1 sustained write/s ceiling: the D8 quota of 4 per user per
    day would need about 21,600 DAU all toggling at the quota to reach 1/s.
  - Contention signal: `ABORTED` or `txn_attempts > 3` on UpdateProfile toggles (logged as `privacy_toggle_attempts`).
  - Fallback: shard by uid hash into 16 docs `privacy/protectedAuthors-{0..f}`. The loader reads 16 per refresh. The
    interface is unchanged, so no caller changes.

**D4. The visibility matrix (the tester's oracle; every cell has one outcome).** A = viewer. P = a protected author
whom A does not follow and who is not A. "Approved" = A follows P, or A == P. Every approved cell behaves as today.
NOT_FOUND strings are byte-identical to today's for each RPC.

| Path | Unapproved viewer of P's content | Extra reads |
|---|---|---|
| GetPost(P's post) | NOT_FOUND "post not found" | 0 |
| `Engagement.Viewable`: Like, AddBookmark, Report, reply parent, quote target | NOT_FOUND "post not found" | 0 |
| GetThread, focal by P | NOT_FOUND | 0 |
| GetThread, parent or root by P | unset with `parent_unavailable` / `root_unavailable` (tombstone) | 0 |
| GetThread, reply rows by P | dropped (the page may be short) | 0 |
| GetHomeTimeline, rows by P | cannot occur: Home shows only own and followed authors | 0 |
| Any feed or list: a REPOST whose original is by P | dropped | 0 |
| Any feed or list: a QUOTE whose embedded post is by P | row shown; `embed_viewer_state = PROTECTED`; the server strips the embed's text and media, keeping `post_id` and the author snapshot | 0 |
| GetUserTimeline(P), any tab | `author_protected = true`, no posts and no tokens, decided **before** the author-recent cache is consulted (3 cold reads: interceptor, target `users`, caller graph) | ≤ today's NOT_FOUND path |
| GetUserTimeline(X), Reposts or Replies tab rows embedding or quoting P | the REPOST and QUOTE rules above | 0 |
| ListBookmarks, ListLikedPosts (W2-L-2) | rows by P dropped, **kept, not pruned**: they return when A follows P or P unprotects | 0 |
| ListFollowers(P), ListFollowing(P) | FAILED_PRECONDITION + `ERROR_REASON_PROTECTED_ACCOUNT` (3 cold reads) | 0 |
| GetProfile(P) | returned: name, handle, bio, avatar, banner, location, website, counts, `is_private = true`; `pinned_post_id` **omitted** | 0 (the follow bit comes from A's snapshot through the existing `BlockChecker` seam, extended with `IsFollowing`) |
| GetProfileRelationship(P) | returned; `follow_state = REQUESTED` when P ∈ A.requested | 0 |
| ListSuggestedUsers | P may be suggested (header data only); following P creates a request | 0 |
| Notifications from P to A (mention, reply, quote, repost) | suppressed at fan-out (P is the actor, A the recipient, `CanSee(A, P)` false); like and follow rows unaffected | 0 (the recipient's snapshot is already read, D5 of ADR-0017) |
| **W4 search** (hashtag and text results, people search) | post rows by P dropped, and REPOST/QUOTE as above; people search shows P's header like GetProfile | 0: **W4's ADR must call `Audience.Decide` on every result** |
| **W5 lists and communities** | list and community timelines drop P's rows by the same call; adding P to a list needs A to be approved (W5 ADR) | 0 |
| **W7 messaging** | the W7 ADR gates "who may message a protected account" on the same snapshot and set; the recommended default is approved followers and accounts P follows | 0 |

- **Counts are public:** followers, following and posts on P's profile, and like, reply, repost and quote counts on
  public posts that include P's actions. This matches X, and costs nothing to hide.
- **A blocked or muted P** keeps the ADR-0010 D6 outcomes. Block is checked first, so a P who blocks A is NOT_FOUND
  everywhere, exactly as today.
- **ADR-0024 hooks.**
  - The pin is omitted for unapproved viewers.
  - The Media and Reposts tabs follow the GetUserTimeline row.
  - ListLikedPosts follows the list row.

**D5. Write-path rules.**
- **RepostPost of P's post and CreatePost(quote_of_post_id = P's post)** (Option 3A):
  - an unapproved caller gets NOT_FOUND (`Viewable`);
  - an approved caller other than P gets FAILED_PRECONDITION + `ERROR_REASON_PROTECTED_ACCOUNT`, 0 writes;
  - P may repost or quote their own post.
- **Like, bookmark, reply and report by approved callers** work as today. A reply by a public account to P's post is
  public. It shows "Replying to @P" and its own text, never P's.
- **Mentions of P** are unaffected (ADR-0010 D7 M2). P is notified as usual.
- **Existing copies.** REPOSTs and QUOTEs made while P was public are never rewritten. The D4 embed rules hide them
  from unapproved viewers at read time.

**D6. Follow to a protected target creates a request.**
- **Follow transaction.** It now reads the target's `users` doc **inside** the transaction through the existing
  `identity.TxProfiles.ProfileInTx`. Today it reads it from the 60 s cache.
  - A toggle and a follow therefore conflict and serialize, so no follow can slip past a just-committed protect.
  - Cost: +0 reads cold, +1 warm. Follow becomes 4 cold / 3 warm. The planning value of 4 (ADR-0008 A2) is
    unchanged.
  - **Contention (rule 3).** The target's `users` doc is now in every Follow's read set, so concurrent Follows of one
    popular account serialize on it (they already write its `followersCount` in the same transaction, so the hot doc
    is not new; the read adds conflicts, not writes). Signal: `txn_attempts > 3` or `ABORTED` on Follow, logged per
    target hash. Fallback: read the target from the 60 s cache again, accepting a documented 60 s window in which a
    Follow can become an edge to a just-protected account; then the sharded follower counter of ADR-0008 D3's revisit
    line.
- **Target `isPrivate` and not followed by the caller:**
  - `Create followRequests/{caller}_{target}`;
  - `ArrayUnion` into the caller's `requested`;
  - `quotas.follows` (a request counts as a follow).

  3 writes. Returns `REQUESTED`.
- **Replay.** The request already exists, or the target is already in `requested`: `REQUESTED`, 0 writes, no quota.
- **Caps and quotas.**
  - `requested` at 500 → LIMIT_REACHED `limit=follow_requests`.
  - The follows quota (200/day, 50 for new accounts) is unchanged.
  - The existing NOT_FOUND, TARGET_BLOCKED and VALIDATION rules come first.
- **Event.** After the commit: `FollowEvents.FollowRequested(requester, target)`. No `Followed` event.

**D7. Request lifecycle.**

| Action | Who | Effect (one transaction or batch) | Reads cold / warm | Writes | Deletes |
|---|---|---|---|---|---|
| Request | requester | D6 | 4 / 3 | 3 | 0 |
| Withdraw = `Unfollow(target)` | requester | Unfollow first runs today's blind edge batch. On its failed precondition it runs a second blind batch: `Delete(followRequests/{caller}_{target}, Exists)` + `ArrayRemove` from `requested`. A second failure is NONE | 0 in the batches (+1 logged interceptor) | 1 | 1 |
| Accept = `RespondToFollowRequest(accept=true)` | target | Read the request fresh (absent → replay). Read the requester's graph fresh. `Create follows/{requester}_{target}`; requester graph `following += target, requested -= target`; `followingCount +1` on the requester and `followersCount +1` on the target (`identity.Counters`); delete the request | 3 / 2 (interceptor, request, requester graph; requester status from `Directory`, cache-first) | 4 | 1 |
| Decline = `RespondToFollowRequest(accept=false)` | target | Delete the request; requester graph `requested -= target` | 3 / 2 | 1 | 1 |
| Respond replay (request gone) | target | Returns the caller's current relationship to the requester | 2 / 1 | 0 | 0 |
| Requester not ACTIVE at accept | target | The request is deleted and `requested` cleaned; OK, no edge | 3 / 2 | 1 | 1 |
| Requester at 5,000 following at accept | target | FAILED_PRECONDITION LIMIT_REACHED `limit=requester_following`, nothing written; the target may decline | 3 / 2 | 0 | 0 |
| Block, either direction | either | The Block transaction already reads and writes both graphs. It also deletes `followRequests` in **both** directions when present in either `requested`, and removes the entries from those arrays in the writes it already makes | +0 | +0 | ≤ +2 |

- **No notification on decline.** Accept emits `FollowEvents.FollowRequestAccepted(target, requester)`. The target
  gets no plain FOLLOW notification, because they did the accepting.
- **Idempotency (rule 4)** is by natural key and state, as in every graph mutation (ADR-0008): `idempotency_key` is
  validated, not stored.
- **Response.** `RespondToFollowRequestResponse.relationship` returns the caller's relationship to the requester
  (snapshot, 0 reads), so the client can offer "Follow back".
- **`ListFollowRequests`.** Incoming requests, newest first:
  - query `followRequests where followeeId == caller ORDER BY createdAt DESC, __name__ DESC Limit(page)` (the existing
    composite);
  - hydrate through `Directory` (non-ACTIVE dropped);
  - drop rows of users in the caller's `blocked` or `blockedBy`;
  - `relationship` from the caller's snapshot.

  Page 20 by default, max 50. The cursor is sealed and bound to `caller|follow-requests`, with a 24 h TTL. Reads:
  42 / 102 cold at page 20 / 50, 21 / 51 warm.
- **`GetMe.pending_follow_request_count`.** For a protected caller only: a `count()` on `followRequests where
  followeeId == caller` (1 read per 1,000 matches), cached 30 s. 0 reads for everyone else. It drives the drawer
  entry and the badge.

**D8. Toggling.**
- **Protect** (`is_private=true`):
  - **Transaction:** `users` (fresh) + `privacy/protectedAuthors` (fresh, for the cap) + `quotas` → `isPrivate=true`,
    `ArrayUnion` into the set, `quotas.privacyToggles`. 4 / 3 reads, 3 writes.
  - **Existing followers are kept.** Existing posts become followers-only **at read time, with no rewrite**, within
    60 s.
  - **Existing copies by others are hidden** from unapproved viewers per D4.
  - **Notifications already delivered stay.** Opening one leads to NOT_FOUND. That is a residual.
- **Unprotect** (`is_private=false`):
  - **Transaction:** the same transaction with `ArrayRemove`.
  - **Then the job.** After the commit, publish `{kind: privacy_public, uid}` to the existing `jobs` topic (Option 2A).
    The job:
    - reads `users/{uid}` fresh, and stops (acks) if the account is protected again;
    - pages `followRequests where followeeId == uid ORDER BY createdAt DESC Limit(100)`, self-resuming because
      accepted requests drop out;
    - accepts each page in **one transaction**: it re-reads every request and requester graph of the page fresh,
      then writes, per request, the D7 Accept effects (edge, requester graph, requester `followingCount`, request
      delete) and, once per page, the target's `followersCount += n`. That is at most 4 × 100 + 1 = 401 operations,
      under Firestore's 500, so a crash or a redelivery commits a whole page or nothing and no counter increment
      is ever lost or doubled (ADR-0008 D3 invariant 2). A requester at the following cap or no longer ACTIVE is
      handled as in D7 inside the same transaction.

    Per request: 2 reads, 3 writes, 1 delete, plus 1 write per page. Each accepted request emits
    `FollowRequestAccepted` after the page commits.
  - **Worst case at 500 pending:** 1,000 reads, 1,505 writes, 500 deletes. That is 7.5% of the free daily writes.
  - **Concurrency.** Follow's in-transaction read (D6) means no new request is created after the commit, so the job
    has no start gate.
  - **Delivery.** At-least-once is safe: a page is atomic and an accepted request is gone from the next query.
- **Quota.** `QUOTA_PRIVACY_TOGGLES_PER_DAY` = 4 (both directions count) → QUOTA_EXCEEDED `quota=privacy_toggles`.
  This bounds the job and the set-doc write rate. `is_private` sent equal to the current value is 0 writes and is not
  charged.
- **Snapshot.** A toggle bumps no `snapshotVersion` and enqueues no snapshot job: privacy is not in `AuthorSnapshot`.
  It is decided at read time.

**D9. Invariants: ADR-0009 re-checked (its reopen criterion 5 is triggered: Accept and the job are new writers of
`follows` and `following`).**
- **I1 (ADR-0009, unchanged)** holds. Accept and the job create `follows/{a}_{b}` and `b ∈ graph/{a}.following` in
  one transaction that reads `graph/{a}` and the request fresh.
- **New I-R:** `followRequests/{a}_{b}` exists ⇔ `b ∈ graph/{a}.requested`. Every writer touches both in one unit:
  - Request: transaction.
  - Withdraw: blind batch with `Exists`.
  - Accept and Decline: transaction.
  - Block: transaction.
  - Purge: the D11 step.
- **New I-X:** never both an edge and a request for the same ordered pair. Accept deletes the request in the
  transaction that creates the edge. Follow of a followed target is a replay before any request logic.
- **Unfollow's 0-read design stands.** A failed edge precondition still means "no edge" under I1. The withdraw batch
  is a second independent blind batch whose failed precondition means "no request" under I-R. No unconditional read
  is added, so ADR-0009's decision (A + E) is unchanged and its Option C stays on the shelf.
- **Invariant checker.** The T16a checker gains I-R and I-X (W3-35).

**D10. Notifications** (ADR-0017 seams; producers through `graph.FollowEvents`, never a direct call).
- **New types:**
  - `follow_request`: id `follow_request_{requesterUid}`, sent to the target.
  - `follow_accepted`: id `follow_accepted_{targetUid}`, sent to the requester.
  - Both are written by the existing fan-out handler, which sets `actorIds = [actor]` on every row, so the ADR-0017
    D10 eraser (the `actorIds` COLLECTION_GROUP query) finds and erases them when the actor deletes the account.
- **Both use `Create`.** AlreadyExists means no new row and no second push for the 90 d TTL. A withdraw or decline
  **does not delete** the `follow_request` row, so repeating request → withdraw → request sends one push, not 200.
  - The residual: the target may see a stale "requested to follow you" row. The requests screen shows the truth.
- **Suppression (ADR-0017 D5)** gains the D4 row: post-bearing types (mention, reply, quote, repost) whose actor the
  recipient may not see are dropped at fan-out. 0 reads: the actor comes from `set`, the recipient's snapshot is
  already read.
- **Push text** is generic: "New follow request" / "Follow request accepted".
- **Gating.** Both types are gated by `notifications` like every type. Their creation is never gated by
  `private_accounts`.

**D11. Deletion and export (rule 10, T11 guard).**
- **Eraser.** A new appended step, `follow_requests` (`graph.RequestEraser`), registered after `bookmarks` and before
  `identity`. This follows the ADR-0023 D6 precedent: step names are persisted in `deletionJob.step`, so graph's
  internal step numbers are never changed.
  - **Outgoing requests.** `followRequests where followerId == uid Limit(500)`, served by the automatic single-field
    index. 1 read + 1 delete each. The uid's own `graph` doc, with `requested`, goes in the earlier graph step.
  - **Incoming requests.** `followRequests where followeeId == uid ORDER BY createdAt DESC Limit(500)` (the existing
    composite). Each costs 1 read + 1 delete + 1 `Update` with `ArrayRemove(uid)` on the requester's `graph`. NotFound
    is skipped and logged as `purge_missing_counterpart`, never `Set` (ADR-0008 D10).
  - **Self-resuming.** Minimum 2 reads.
  - **Safety.** Follow rejects non-ACTIVE targets in its transaction (D6), so no request can appear behind the step.
- **The identity step** also `ArrayRemove`s the uid from `privacy/protectedAuthors` before `users/{uid}` is deleted.
- **T11 guard rows:**
  - `followRequests`: `erasedByStep: follow_requests`;
  - `privacy/protectedAuthors`: `erasedByStep: identity` (the entry, not the doc).
- **`lifecycle_wiring_test.go`** step list:
  `…, scheduled, bookmarks, follow_requests, identity, auth_delete, users_doc`. Its export list ends
  `…, bookmarks, follow_requests`.
- **Export.** A new appended section, `follow_requests`, keeps the graph section's bytes and golden file unchanged:
  - `{"sent":[{userId, handle, requestedAt}], "received":[…]}`, newest first;
  - 1 read per doc, minimum 2.
  - `isPrivate` is already in the profile section.
  - The set doc is never exported: it lists other users.

**D12. Flag `FEATURE_PRIVATE_ACCOUNTS` (`private_accounts`).**
- **Gated:**
  - `UpdateProfile(is_private=true)` needs the flag on for the caller, else FEATURE_DISABLED `feature=private_accounts`
    with 0 writes.
  - `ListFollowRequests` and `RespondToFollowRequest` need the flag **not globally off**, or the caller to be
    protected now (0 extra reads: the interceptor already read the caller's profile).
  - `GetMe.enabled_features` lists the name.
- **Never gated:**
  - the D3 predicate on every path;
  - Follow creating a request to a protected target;
  - withdraw;
  - `is_private=false`;
  - the `privacy_public` job;
  - notifications suppression;
  - the eraser and export.

  ADR-0008 D6: turning a flag off never un-hides anything.
- **Kill switch semantics.** With the flag globally off, nobody new can protect, and existing protected accounts stay
  protected and can still manage their requests or unprotect.
- **Ceiling.** In `flag-ceiling.json` (founder-gated, W3-25): dev `{"mode":"allowlist","max_allowlist":3,
  "max_percent":0}`; no prod raise.
- **Ramp.** Dev allowlist (3), then the founder's MVP decision. It ramps with `graph`.

**D13. Abuse limits** (config, rule 11). Per instance; the effective limit is ×3.
- **Request spam:**
  - the follows quota of 200/day (50 for new accounts) counts requests;
  - `requested` is capped at 500;
  - the Follow bucket of 30/min (90/min effective);
  - deterministic notification ids: one push per requester per target per 90 d;
  - the target can block, which deletes the request (D7).
- **Respond:** `RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN` = 60 (180 effective). No quota: responses are bounded by
  the requests that exist.
- **ListFollowRequests:** the existing graph list bucket (20/min) and `graph_list_daily` (100/day per instance). The
  caller can only list their own requests.
- **Toggle:** `QUOTA_PRIVACY_TOGGLES_PER_DAY` = 4 (D8). A toggle storm by one account costs at most 4 × 3 writes plus
  4 jobs a day.
- **Oracles.**
  - The protected state is public by design (`is_private`).
  - PROTECTED_ACCOUNT reveals nothing GetProfile does not.
  - P's posts stay NOT_FOUND byte-identical to a deleted post.
  - Blocks are still checked first, so no new block oracle appears.
- **Read budget.** Every new ceiling (42, 102, 3) is under `readBudgetMaxCallReads` (269).

**D14. Proto changes (in the first Part B PR, W3-25; all additive, `buf breaking` clean, no number reused).**
- `common.v1.ErrorReason`: `ERROR_REASON_PROTECTED_ACCOUNT = 17;` with the comment "FAILED_PRECONDITION: the
  account's posts are protected (ADR-0025). Returned for ListFollowers or ListFollowing of a protected account to a
  non-follower, and for a repost or quote of a protected account's post. Do not retry."
- `identity.v1.GetMeResponse`: `int64 pending_follow_request_count = 6;` (protected callers only; else 0).
- `graph.v1.RespondToFollowRequestResponse`: `Relationship relationship = 1;` (the caller's relationship to the
  requester).
- `timeline.v1.GetUserTimelineResponse`: `bool author_protected = 6;`.
  - True means: no posts, no tokens; show the protected view; **replace** any cached feed for this author.
  - Old clients see an empty list: it fails closed.
- `posts.v1.EmbedViewerState`: `EMBED_VIEWER_STATE_PROTECTED = 3;` (the server stripped the embed's text and media).
- `notifications.v1.NotificationType`: `NOTIFICATION_TYPE_FOLLOW_REQUEST = 7;` and
  `NOTIFICATION_TYPE_FOLLOW_ACCEPTED = 8;`.
- **Comment-only changes:**
  - `identity.proto`: `Profile.is_private`; `UpdateProfile` (no visibility job; the toggle quota; the set; the
    `privacy_public` job; FEATURE_DISABLED while off).
  - `graph.proto`: the header (requests live); `Block` (also deletes pending requests both ways: up to 4
    deletes, 2 edges + 2 requests); `Follow` (requests, the in-transaction target read, 4 cold / 3 warm);
    `Unfollow` (withdraw); `ListFollowRequests` (42 / 102 cold); `RespondToFollowRequest` (3 / 2 reads, accept
    4 writes + 1 delete, decline 1 + 1); `ListFollowers`/`ListFollowing` (PROTECTED_ACCOUNT); `FOLLOW_STATE_REQUESTED`
    (reachable).
  - `posts.proto`: `Visibility.FOLLOWERS` (computed at read time); `GetPost`, `GetThread` and `CreatePost` quote
    (D4, D5).
  - `engagement.proto`: `RepostPost` (D5); `ListBookmarks` and `ListLikedPosts` (the D4 list row).
  - `timeline.proto`: `GetUserTimeline` (the "Deferred with private accounts" sentence is replaced by D4).

**D15. Gate files (founder-gated; in W3-25).**
- **`firebase/firestore.indexes.json`:** one fieldOverride, `{ "collectionGroup": "privacy", "fieldPath": "uids",
  "indexes": [] }`, plus the re-hashed `firebase/field-overrides.ack`.
  - **No new composite index.** `followRequests (followeeId ASC, createdAt DESC)` exists; `followerId ==` uses the
    automatic single-field index; `graph.requested` is already exempt.
- **`scripts/promotion/flag-ceiling.json`:** the `private_accounts` entry.
- **Merge order.** If W3-2 (ADR-0024) is still open, the two index PRs merge one at a time and the second re-hashes
  the ack.

**D16. Records and sequencing.**
- The first Part B PR adds dated pointer notes to ADR-0003 (the visibility-job paragraph is superseded by ADR-0025 D3)
  and ADR-0008 (D1 reversed by ADR-0025). Their decisions are not edited.
- It also updates the `firestore-data-model` skill: the `privacy` row, the `followRequests` row and the op-cost rows.
- **This ADR is accepted before the W4 search ADR is written**, and that ADR's search paths call `Audience.Decide`.

## Cost impact
Convention as ADR-0024. Request paths only; the set refresh is a separate line.

| Operation | Reads cold / warm (planning) | Writes | Deletes | Calls per DAU | Reads per DAU |
|---|---|---|---|---|---|
| D3 predicate on every read path | +0 / +0 | 0 | 0 | all | 0 |
| Protected-set refresh (detached, per instance) | ≤ 1 per instance per minute while serving | 0 | 0 | n/a | 3.2 / 2.4 / 1.4 at 300 / 1,000 / 3,000 DAU (960 / 2,400 / 4,320 a day) |
| Follow, any target (in-transaction target read) | 4 / 3 (4) | 5 (edge) or 3 (request) | 0 | 0.5 | +0 planning |
| Withdraw (Unfollow) | 0 in batches + 1 interceptor | 1 | 1 | 0.005 | ~0 |
| ListFollowRequests, page 20 / 50 | 42 / 102 cold; 21 / 51 warm (42) | 0 | 0 | 0.02 | 0.84 |
| RespondToFollowRequest, accept / decline / replay | 3 / 2 (3); replay 2 / 1 | 4 / 1 / 0 | 1 / 1 / 0 | 0.04 | 0.12 |
| UpdateProfile toggle | 4 / 3 | 3 | 0 | 0.002 | 0.01 |
| `privacy_public` job, per pending request | 2 | 3 (+1 per page) | 1 | rare | ~0 |
| GetMe count for protected callers | +1 per 1,000 matches, cached 30 s | 0 | 0 | 4 × 5% protected | 0.10 |
| GetUserTimeline / ListFollowers / ListFollowing for an unapproved viewer of P | 3 / 0 (no page read) | 0 | 0 | replaces page reads | ≤ 0 |
| `follow_request` / `follow_accepted` notification fan-out | about 2 per recipient (ADR-0017 row) | 1 | 1 TTL (90 d) | 0.05 / 0.04 | 0.18 |
| Eraser `follow_requests` step | 1 per doc (min 2) | 1 per incoming doc | 1 per doc | per deletion | n/a |
| Export `follow_requests` section | 1 per doc (min 2) | 0 | 0 | per export | n/a |

**Assumptions.** 5% of DAU protected. 0.05 follows a day per DAU go to a protected target, which shifts 0.05 Follows
from 5 writes to 3. 0.04 responses a day per DAU.

**Per DAU per day:**
- request-path reads: **+1.25**;
- set refresh: **+3.2 / 2.4 / 1.4**;
- writes: **+0.16** (responses 0.16, notifications 0.09, toggles 0.006, minus 0.1 from cheaper Follows);
- deletes: **+0.05**.

This replaces the plan's placeholder of "+3 reads, +0.2 writes".

**Whole product (W2 + W3 A + B) at 300 DAU:** about 293 reads per DAU. Free reads end at about 170 DAU. Writes and
deletes are unchanged in practice.

| Quota | Part B alone runs out at | INR/month at 300 | at 1,000 | at 3,000 |
|---|---|---|---|---|
| Firestore reads | the set refresh is ≤ 4,320/day (8.6% of the free reads) whatever the DAU; with the request path (+1.25 per DAU), about 36,000 DAU | 1.4 | 3.7 | 8.2 |
| Firestore writes | about 125,000 DAU (the product: about 596) | 0 | 0.5 | 1.4 |
| Firestore deletes | not binding | 0 | 0 | 0.05 |
| Cloud Run requests (+0.1 per DAU) | not binding (the product: about 1,743) | 0 | 0 | 0.35 |
| Storage | a request doc is about 0.4 KB with indexes; the set at its cap is 600 KB | 0 | 0 | 0 |
| Egress to India | the set never leaves the server; responses are small | ~0 | ~0 | ~0 |
| **Total** | | **≈ INR 1.4** | **≈ INR 4.2** | **≈ INR 10** |

- **Fixed monthly cost added: INR 0.** No new GCP service, topic (the existing `jobs` topic), Scheduler job or
  composite index. One fieldOverride. The credit window lifts nothing.
- **Compared with the options.** Option A would be about INR 4 / 14 / 43 a month, paid from day one with 0 protected
  accounts. Option C would be about 0 / 2 / 5 in writes plus a privacy lag (Options).
- **Trigger:** none for Stage 0. Stage-ladder triggers below.

## Stage ladder

| Concern | Stage 0 (this ADR) | Seam | Stage 2/3 target | Trigger |
|---|---|---|---|---|
| "Is this author protected?" | One identity-owned set doc, instance-cached 60 s, detached refresh, fail closed | `identity.ProtectedAuthors` (loader) + `posts.Audience` (the only predicate); no caller reads `isPrivate` or the doc | Shard by uid hash (16 docs) first; then a Memorystore set, or `users.is_private` joined server-side in the Stage 2 SQL timeline | Protected accounts > 10,000 (half the cap); set doc > 300 KB; or sustained `ABORTED` on toggles |
| Visibility enforcement | Read time on every path, no stored per-post visibility | `Audience.Decide` called by every read path, including W4, W5 and W7 | The same predicate pushed into the Stage 2 query layer (SQL `WHERE` or a materialised per-viewer timeline that applies it at fan-out) | Moves with the timeline's Stage 2 ADR, never alone |
| Follow requests | `followRequests` docs + `requested[]` in the snapshot | `graph.Service` and `FollowEvents`; opaque `follow-requests` cursor | An edge table with a state column (SQL) | The §6 Firestore trigger |
| Requests counter | `count()` on demand (protected callers) | `GetMe.pending_follow_request_count` | A counter on the target (rule 3: per-target write rate, `ABORTED`) | A protected account receiving > 1 request/s sustained (a viral protected account) |
| Hot docs | The set doc: ≤ 1 write per toggle, quota 4/day/user | Loader interface | Sharded set | `ABORTED` on toggles |
| Follow on a popular target | The target's `users` doc is read in every Follow transaction (D6) | `identity.TxProfiles`; the Follow service | The cached target read (60 s window documented), then sharded follower counters | `txn_attempts > 3` or `ABORTED` on Follow for one target, sustained |

## Consequences
- **Positive.**
  - One rule, one source, one function for every current and future read path, including W4, W5 and W7.
  - 0 per-request reads.
  - No visibility job.
  - The flag can be ramped down without un-protecting anyone.
  - L-2 is closed by construction.
  - The request lifecycle keeps every existing invariant and adds two (I-R, I-X).
- **Negative.**
  - A 60 s window after a toggle.
  - A new global doc with a size cap (20,000).
  - A background read rate of ≤ 4,320 a day, even at low traffic, while instances serve.
  - Delivered notifications and other users' existing quotes stay as copies; they are hidden or stripped at read time.
  - Withdrawn requests leave a stale notification row.
  - Counts on protected profiles stay public.
- **Follow-up.** W3-25 to W3-38, and the D16 records. `docs/runbooks/private-accounts.md` covers:
  - the stale-set and UNAVAILABLE failure mode;
  - the `privacy_public` job (stuck or partial: rerun by republishing; it is idempotent);
  - the 20,000 cap;
  - how to verify the set equals `count(users where isPrivate == true)`, at 1 read per 1,000.
- **Revisit when:**
  - any Stage-ladder trigger fires;
  - W4, W5 or W7 needs a rule beyond `Audience.Decide`;
  - a user report shows the 60 s window or the stale notification row matters.

## Questions for the founder

| # | Question | Recommended default |
|---|---|---|
| 1 | Reverse ADR-0008 D1: ship private accounts and follow requests in W3 Part B, before the W4 search ADR | **Yes** (merging this ADR records it) |
| 2 | How the server knows who is protected: B set doc (0 per-request reads, about INR 1-4/month) / A per-row reads (about INR 4-43/month, paid with 0 protected accounts) / C visibility job (rewrites, privacy lag) | **B** |
| 3 | Going public: auto-accept pending requests (≤ 1,505 writes at the 500 worst case) / decline all / leave pending | **Auto-accept** |
| 4 | Reposts and quotes of a protected post: refused for everyone but the author (X) / allowed and filtered | **Refused** |
| 5 | What a non-follower sees: header, counts, bio, banner, location, website and lock; not posts, lists or the pinned post | **Yes** |
| 6 | Notifications: `follow_request` and `follow_accepted`; no notification on decline; a withdrawn request's row is not deleted (one push per requester per 90 d) | **Yes** |
| 7 | Toggle quota: 4 a day | **4** |
| 8 | Protected-account cap 20,000 in one set doc (Stage-ladder trigger at 10,000) | **20,000** |

## Handoff
- **architect:** the D14 proto changes, the D15 gate files and the D16 notes, in W3-25's PR or just before it, after
  this merges.
- **backend-developer:**
  - **W3-25:** the flag, config, rate limits, `quota.PrivacyToggles` (I-3) and Terraform vars default `off`.
  - **W3-26:** identity:
    - the toggle transaction and the set;
    - the `ProtectedAuthors` loader (lazy, singleflight, detached `protected_set_reads`, fail closed with
      `PROTECTED_SET_MAX_STALE`, ERROR on UNAVAILABLE);
    - the `privacy_public` job;
    - the GetProfile pin omission and `BlockChecker.IsFollowing`;
    - the GetMe count;
    - the identity-step `ArrayRemove`.
  - **W3-27:** graph:
    - the Follow request path with `ProfileInTx`;
    - the withdraw batch;
    - Block's request clean-up;
    - I-R and I-X.
  - **W3-28:** `ListFollowRequests` and `RespondToFollowRequest`; `FollowEvents.FollowRequested` and
    `FollowRequestAccepted`.
  - **W3-29:** posts and engagement:
    - `posts.Audience` (`CanSee`, `Decide`) as the only rule;
    - `Viewable`, GetPost and GetThread on it;
    - embed stripping;
    - the repost and quote refusal;
    - ListBookmarks and ListLikedPosts drops.
  - **W3-30:** timeline:
    - `author_protected` before any cache;
    - Home and tab embed rules through `Decide`.
  - **W3-31:** notifications: the two types, ids and push text; D4 suppression.
  - **W3-32:** lifecycle:
    - the `follow_requests` step and section;
    - T11 rows;
    - `lifecycle_wiring_test.go` lists.
  - Log `audience_dropped` by cause (protected, blocked, muted, hidden) on every list line. Every RPC is asserted with
    `budgettest` at the ceilings above.
- **frontend-developer:**
  - **W3-33:**
    - the protected profile view on `author_protected` (replace the cached feed);
    - the lock badge;
    - `FollowButton` Requested and withdraw;
    - the "Protect your posts" toggle with a confirm that explains the 60 s window and auto-accept;
    - the `EMBED_VIEWER_STATE_PROTECTED` embed;
    - `PROTECTED_ACCOUNT` copy.
  - **W3-34:** `/follow-requests` with Accept / Decline, "Follow back" from the response, and the drawer entry from
    `pending_follow_request_count`.
- **tester (W3-35):**
  - the D4 matrix on every path, including a W4 placeholder test that fails until search calls `Decide`;
  - the D7 lifecycle, including the races: follow vs protect (the in-transaction read), accept vs withdraw, accept vs
    block, and the job vs re-protect;
  - I-R and I-X in the invariant checker;
  - the stale-set and fail-closed behaviour;
  - flag-off keeps protection;
  - eraser and export.
- **sre-performance (W3-37):**
  - the Cost impact rows into `cost-model.md` (+1.25 request-path reads, the set refresh line, +0.16 writes, +0.05
    deletes per DAU);
  - a dashboard note for `protected_set_reads` and `protected_set_stale`;
  - the Stage-ladder triggers.
- **security-auditor (W3-36):**
  - every leak path in D4: embeds, notifications, lists, the pinned post, search hooks, counts;
  - request spam and its rate-limit arithmetic (×3);
  - the fail-closed loader;
  - the toggle race;
  - the export;
  - confirm L-2 is closed by `Audience.Decide`, not by a stored-`visibility` test (D2).
- **production-deployer (W3-38):**
  - the D15 gate files deployed (override READY);
  - a targeted dev Terraform plan for `feature_private_accounts*` shown to the founder;
  - allowlist 3 on OK;
  - the smoke: protect, request, accept, withdraw, unprotect with auto-accept, flag off keeps protection;
  - prod unchanged.

## Implementation notes (W3-25a, 2026-10-28)
Records only: no decision above changes. They answer the six open design points of the plan
(`docs/plans/ui-w3-profile-graph-completion.md`, Part B, AQ1 to AQ6). Every default stands. Three notes add a detail
the tickets need (AQ4, AQ5, AQ6). Cost: +0 reads and +0 writes on every row of the Cost impact table, except AQ4's
+1 delete on a rare path.

- **AQ1. The `privacy_public` job runs in graph.** Default kept.
  - Identity reports an unprotect through `identity.PrivacyListener.BecamePublic` after its commit. Graph owns the
    job: the publish (through an `apiserver` adapter), the handler and the accept code. This is the ADR-0024 A4 split,
    where identity calls `MediaRetirer` and media owns the job.
  - Why: the job's transaction writes `follows`, `graph` and `followRequests`, which graph owns (ADR-0002), and it must
    reuse W3-28a's one accept implementation. D8's behaviour is unchanged; only the owner of the handler moves (the
    Handoff listed it under W3-26).
  - A failed hand-over is ERROR `privacy_public_enqueue_failed`. The requests stay pending until the job is
    republished (runbook), and AQ4 keeps Follow correct meanwhile.
- **AQ2. The predicate's expression is written once, on `identity.ProtectedSet`.** Default kept.
  - `ProtectedSet` gets a pure method holding the D3 expression, `viewer == author || !Has(author) || following`.
    `posts.Audience.CanSee` delegates to it, so the rule exists in one place, as D3 requires.
  - Why: posts imports identity, so identity cannot import posts, yet GetProfile must decide the pin (D4).
  - GetProfile is the one caller outside `posts.Audience`. Every read path still calls only `posts.Audience`.
    W3-35a's audience guard enforces that these two are the only callers.
  - As D3 says, a caller decides own and followed authors before it asks the loader, so those never trigger a refresh.
- **AQ3. `pending_follow_request_count` comes through `identity.FollowRequestCounter`.** Default kept.
  - A consumer-side interface in identity, implemented by graph (the `BlockChecker` pattern), cached 30 s per uid in
    identity like the unread-notification count.
  - Why: identity cannot query graph's collection (ADR-0002), and a `count()` on demand is the D7 design. A counter
    on the target stays the Stage-ladder rung.
- **AQ4. A Follow of a public target with a leftover request becomes the edge.** Default kept.
  - The case: the target is not protected and is in the caller's `requested`, because the job has not run yet or its
    hand-over failed.
  - Follow's transaction then creates the edge as usual and, in the same transaction:
    - deletes `followRequests/{caller}_{target}` with a plain `Delete` (no `Exists` precondition, so a drifted entry
      cannot fail the Follow);
    - removes the target from `requested` in the caller-graph write it already makes.
  - That keeps I-R and I-X. Cost: +1 delete and 0 reads, because the caller's graph is already read fresh. The quota
    and the counters are an ordinary Follow's.
  - It serializes with the job: both transactions read and write `graph/{caller}`, and the job re-reads the request.
    So a request is accepted once, and `followersCount` moves once.
  - Why: without it, Follow answers REQUESTED for a public account until the job runs.
- **AQ5. Notifications declare a consumer-side audience checker.** Default kept.
  - notifications declares the check it needs at fan-out: may this recipient see this actor, given the recipient's
    snapshot. `apiserver` adapts it from `posts.Audience.CanSee`. notifications never calls `identity.ProtectedSet`
    itself, although it imports identity.
  - Why: notifications keeps depending only on graph and identity, so it can still split into its own service, and
    the one rule still runs through `posts.Audience`. Importing posts would also work (no cycle), but it would tie the
    fan-out to the posts module for one function.
  - Fail closed: when the set is unavailable, the fan-out of a post-bearing type (mention, reply, quote, repost)
    returns a retryable error, so Pub/Sub redelivers it. It never writes the row on an unknown set. Like, follow and the
    two request types do not need the set.
- **AQ6. GetProfile while the set is unavailable: the header needs no set, only the pin does.** Default kept.
  - The header is public data whatever the set says, and `is_private` comes from the `users` doc.
  - So GetProfile returns the header and omits `pinned_post_id` (fail closed), with WARN `pin_omitted=set_unavailable`.
    This applies only to a viewer who is neither the account nor a follower. The owner and followers get the pin
    without the set.
  - D3's rule stands: no path reads an unknown set as "everyone public", and every path that needs the set for content
    answers UNAVAILABLE.
  - Why: failing the whole profile would turn a set outage into a profile outage and protect nothing more.

## Implementation note (W3-29a, 2026-10-28): the caller's own copy of someone else's post

Founder decision 2026-10-28: accepted.

- **What:** a caller opening their own REPOST or QUOTE of another user's post (`GetForViewer`: GetPost, and the
  `Viewable` paths Like, AddBookmark, Report, reply parent and quote target) now reads the caller's graph once:
  +1 read cold, 0 warm (the graph snapshot is cached 60 s per instance).
- **Why:** D4 makes the copy depend on the caller's follow state toward the copied author. Before ADR-0025 the
  caller's own copies were exempt from the embed check (ADR-0018 D13) and needed no graph read. A caller who
  unfollows a protected author must lose that author's content in their own reposts too.
- **When:** only while a protected-set loader is wired (`posts.WithProtectedAuthors`). Writes stay 0, and creating
  a repost or quote costs nothing extra.
- **Cost:** with the W3-30 path below, this is the only exception to "+0 reads on every path" in the Cost impact table. GetPost of one's own
  copy goes from 3 to 4 reads cold per request (with the interceptor read), the same as GetPost of another user's
  post. Opening one's own reposts is a small share of GetPost calls, and the read is cached 60 s, so the daily
  total stays inside the Part B planning margin. No free-tier line moves.
- **Same rule on the caller's own profile tabs (W3-30, founder decision 2026-10-28: accepted).** GetUserTimeline of
  the caller's own profile, when a page holds the caller's REPOST or QUOTE of another user's post, reads the
  caller's graph once: +1 read cold, 0 warm (cached 60 s), only while a protected-set loader is wired. Own Media
  and Reposts tabs go from 24 to 25 cold at page 20; other viewers' tabs and Home are unchanged. Same reason:
  the copier's follow state toward the original's author decides whether the copy stays.

## Implementation note (W3-28a, 2026-10-28): Respond on a cold instance, and the request-count cap

Founder decisions 2026-10-28: both accepted.

- **Respond cold standalone.** RespondToFollowRequest costs 3 reads cold / 2 warm when it follows a
  ListFollowRequests on the same instance (the D7 row). On a fully cold instance with no List before it, an
  Accept or Decline reads up to 2 more (the requester's `users` doc through the Directory, and the caller's
  `graph` snapshot for the response relationship): up to 5 cold. A cold replay reads 1 more (3). A requester who
  is not ACTIVE or has drifted reads 4 on first sight. Writes are unchanged. The normal client flow (open the
  requests screen, then tap) stays at 3 / 2, so no free-tier line moves.
- **Request-count cap.** `pending_follow_request_count` (AQ3) is one `count()` aggregation on `followRequests`
  capped at 1,000 matches: 1 read, and the badge shows at most 1,000. The cap applies CLAUDE.md rule 5 (every
  query has a limit) to the aggregation.
