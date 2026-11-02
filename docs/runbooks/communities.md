# Communities runbook

Status: **W5-23, W5-24, W5-25 + W5-27 (feed).** `CreateCommunity`, `UpdateCommunity` and `GetCommunity` write and read the data model; `JoinCommunity`,
`LeaveCommunity` and `ListMyCommunities` (section 4a) are live; the lifecycle (eraser step `communities`, export section, owner hand-over) is
live whether or not the flag is on. The other six RPCs answer `UNIMPLEMENTED` past the flag until W5-25b (directory, member list) and W5-28
(moderation). Design:
`docs/adr/0031-communities-and-moderation-scope.md`; contract: `proto/dzeroth/communities/v1/communities.proto`.

## 1. The flag and the kill switch

`FEATURE_COMMUNITIES` (wire name `communities`, Terraform `feature_communities*`) is `off` in every environment. It gates every
`CommunityService` RPC, `TimelineService.GetCommunityTimeline`, `CreatePost.community_id` and (from W5-27) the COMMUNITY entries of
`SetHomeTabs` and `GetMe.home_tabs`. Outside the flag the answer is FAILED_PRECONDITION + `FEATURE_DISABLED`,
`metadata["feature"] = "communities"`, with 0 Firestore reads beyond the account-status interceptor.

- Dev ceiling: `allowlist`, at most 3 uids (`scripts/promotion/flag-ceiling.json`); there is no prod block (the prod apply is held,
  ADR-0019). `communities` never ramps ahead of `lists`.
- Kill switch: set `feature_communities = "off"` and deploy. The data stays; nothing to migrate. The eraser step and the export
  section keep working with the flag off (documents outlive the flag).
- Until W5-26 builds the posting gate, a `CreatePost` with `community_id` set is refused with the same `FEATURE_DISABLED` even for a
  caller inside the flag (it is never created as an ordinary post). The request log carries `community_refused` = `flag_off` or
  `not_built`.

## 2. `COMMUNITY_CREATORS` (startup failure mode)

`community_creators` (Terraform) / `COMMUNITY_CREATORS` (env): comma-separated uids that may call `CreateCommunity`; at most 10, each
1-128 characters of `[A-Za-z0-9-]` (`ids.ValidUID`). Default empty: nobody can create a community.

| Symptom | Cause | Fix |
|---|---|---|
| The new revision never becomes ready; the log says `config: COMMUNITY_CREATORS has an invalid uid` or `lists N uids, at most 10` | A bad or an eleventh uid. The message never names the uid on purpose | Correct `community_creators` and redeploy. The previous revision keeps serving (Cloud Run does not shift traffic to a revision that fails its startup probe) |
| `config: <KEY> must be > 0` | A community limit set to 0 or not a number | Fix the Terraform value; the keys are listed in section 3 |

The startup line `community_limits` shows the creators **count**, never the uids.

## 3. Limits (ADR-0031 D11, D12), all config, all > 0

| Key | Default | Effective |
|---|---|---|
| `COMMUNITIES_MAX_OWNED` / `COMMUNITIES_MAX_JOINED` / `COMMUNITY_MAX_MODERATORS` / `COMMUNITY_MAX_RULES` | 2 / 50 / 10 / 10 | exact |
| `COMMUNITY_RECENT_REMOVALS_MAX` / `COMMUNITY_MODLOG_MAX` | 50 / 100 | exact (capped arrays) |
| `QUOTA_COMMUNITY_JOINS_PER_DAY` / `QUOTA_NEW_ACCOUNT_COMMUNITY_JOINS_PER_DAY` | 20 / 5 | exact, per IST day (`quotas.communityJoins`) |
| `QUOTA_COMMUNITY_POSTS_PER_DAY` / `QUOTA_NEW_ACCOUNT_COMMUNITY_POSTS_PER_DAY` | 50 / 10 | exact, on top of the posts quota (`quotas.communityPosts`) |
| `RATE_LIMIT_COMMUNITIES_WRITE_PER_MIN` / `_READ_PER_MIN` / `RATE_LIMIT_COMMUNITY_TIMELINE_PER_MIN` | 20 / 30 / 12 | x3 instances |
| `COMMUNITY_MUTATIONS_PER_DAY` (`community_mutation_daily`) | 200 | 600; Create, Update, Join, Leave per uid |
| `COMMUNITY_MOD_ACTIONS_PER_DAY` (`community_mod_actions_daily`) | 200 | 600; Hide, Restore, SetMemberRole per actor |
| `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` (`community_posts_per_community_daily`) | 20 | 60; per `uid\|cid` (drawn on by the communities-side posts gate, W5-26) |
| `CACHE_COMMUNITIES_ENTRIES` / `CACHE_COMMUNITY_FEED_ENTRIES` / `CACHE_COMMUNITY_MEMBERS_ENTRIES` | 200 / 100 / 5,000 | per instance, 60 s |

A user who sees `RATE_LIMITED` with `metadata["limit"]` = one of the three daily names has hit the in-memory cap for the day (it
resets at IST midnight and per instance; a new revision resets it). A `QUOTA_EXCEEDED` with `quota` = `community_joins` or
`community_posts` is the Firestore quota record.

## 4. Creating and editing a community (W5-23)

Who may create: only a uid in `COMMUNITY_CREATORS` (section 2), with `FEATURE_COMMUNITIES` on for them. Everyone else gets
PERMISSION_DENIED + `FORBIDDEN` `reason=not_creator` with 0 reads, before the key or the text is even looked at.

| Symptom | Cause | What to do |
|---|---|---|
| A founder sees `not_creator` | Their uid is not in `community_creators` of that environment (dev and prod are separate) | Add the uid in Terraform (`community_creators`, at most 10) and deploy. The uid is the Firebase Auth uid, never the handle |
| `LIMIT_REACHED` `limit=communities_owned` | The creator already owns `COMMUNITIES_MAX_OWNED` (2) communities. The cap is exact and lifetime: there is no delete, and a hand-over to them counts | Nothing to fix for the user. To raise it for everyone, change the config; there is no tool to free a slot, by design (archive does not free one) |
| `LIMIT_REACHED` `limit=communities_joined` | 50 joined communities | The user leaves one |
| `IDEMPOTENCY_KEY_REUSED` | A client re-used a key with another body | A client bug: one key per user action |
| Create/Update `RATE_LIMITED` `community_mutation_daily` | 200 mutations per uid per instance per day | Wait for IST midnight, or a new revision resets it |
| `UpdateCommunity` returns `community_archived` for the owner | The community was archived (`opsctl community archive`, W5-29) | Intended: ARCHIVED is read-only. There is no undo at Stage 0: `restore` keeps an ownerless community ARCHIVED (section 6) |
| `UpdateCommunity` returns `not_owner` for everyone on a community | It has no owner (archived after its owner deleted the account, F12) | Intended: an ownerless community is read-only |

How a write behaves: `CreateCommunity` is one transaction (idempotency doc, memberships doc, then the community, the owner's member
doc and the memberships doc). `UpdateCommunity` is one transaction that appends an `EDIT` log entry (`modlog`, newest 100 kept) and, the
first time, adds the community to the owner's `modlogged` (I-L). A request that changes nothing writes only the idempotency doc.
Transaction contention shows as `community_txn_attempts` > 3 on the request line and a WARN `communities_txn_contention`; the caller
gets UNAVAILABLE with a 1 s retry-after.

Staleness: the community doc and the member doc are cached per instance for 60 s (`CACHE_COMMUNITIES_ENTRIES`,
`CACHE_COMMUNITY_MEMBERS_ENTRIES`); the writing instance is updated at once. A rename, a hand-over or a (W5-29) suspension therefore
reaches every other instance within 60 s. A missing id is remembered for 60 s too (no read on a repeat probe).

## 4a. Joining, leaving and My Communities (W5-25)

`JoinCommunity`, `LeaveCommunity` and `ListMyCommunities` run behind the same flag. One transaction each; the Join transaction **never reads
the community document** (`memberCount` is a blind `Increment` through `memberCountDelta`, the one writer), so a join burst does not abort
other joins. Budgets with the interceptor: Join 6 cold / 4 warm reads, 5 writes (1 when already a member); Leave 5 / 3 reads (6 / 4 for a
moderator, who makes the transaction read the community fresh), 3 writes + 1 delete (1 write for a non-member); ListMyCommunities 52 cold /
2 warm reads. Request-line fields: `community_op=join|leave|my`, `outcome`, `cache_hit`, `community_txn_attempts`, `txn_attempts`, `fs_reads`.

| Symptom | Cause | What to do |
|---|---|---|
| `FORBIDDEN reason=banned` on Join | The member doc is BANNED. A ban is only lifted by `SetMemberRole` (W5-28) | Intended. Leave by a banned user is a success that changes nothing: the ban stays |
| `COMMUNITY_STATE reason=owner` on Leave | The owner cannot leave (no transfer at Stage 0); checked against `communityMemberships.owned` in the transaction | Intended |
| `LIMIT_REACHED limit=communities_joined` | 50 joined, checked against the memberships doc in the transaction (exact) | The user leaves one |
| `QUOTA_EXCEEDED quota=community_joins` | 20 joins a day (5 for an account younger than `QUOTA_NEW_ACCOUNT_WINDOW`, 24 h), IST day; a repeat join of a community the user is in is free | Wait for IST midnight. Tune `QUOTA_COMMUNITY_JOINS_PER_DAY` only with the abuse numbers in front of you |
| `member_count` in a Join/Leave response looks stale | The transaction does not read the community; the response is the instance-cached count plus or minus this call, and other instances catch up within 60 s (`CACHE_TTL`) | Intended (communities.proto). Do not "fix" it by reading the community in the Join transaction (that reintroduces the lock contention) |
| Join into a community that was ARCHIVED or SUSPENDED in the last 60 s succeeds | The status comes from the 60 s instance cache | Bounded to 60 s per instance; the next call after the entry expires gets the real status |
| `UNAVAILABLE` on Leave of a moderator during a viral join burst | The moderator path reads the hot community doc, so concurrent `Increment`s abort it (`community_txn_attempts` > 1, WARN `communities_txn_contention` above 3) | Retry (the client does, `retry-after` 1 s). If it is sustained, or one community passes about 1 join/s, move `memberCount` to shards or Pub/Sub-batched increments (ADR-0031 hot-doc fallback, stage-ladder "Community counters") |
| A moderator who left is still listed in `moderatorIds` | The leaver was promoted on another instance and neither this instance's 60 s cache nor the leaver's `modlogged` named the community, so the transaction did not read the community (the one residual window of the cached moderator hint) | Rare (a promotion adds the target to `modlogged`, I-L, so the repository check covers it once W5-28 writes it). Fix by hand: remove the uid from `moderatorIds` and add a `MODERATOR_LEFT` entry. The owner can also remove the role with `SetMemberRole` (W5-28) |

`ListMyCommunities` is not paged (at most 50): it reads the memberships doc fresh and the community docs from the 60 s cache (misses in one
`GetAll`, 1 read each). It lists JOINED communities newest first (the reverse of `joined`), leaves out a SUSPENDED one unless the caller
owns it, keeps ARCHIVED ones, and skips a joined id whose document is gone. A non-empty `page_token` is `VALIDATION page_token` with 0 reads.

## 4b. The directory and the member pages (W5-25b)

`ListCommunities` and `ListCommunityMembers` run behind the same flag, read only (0 writes). Request-line fields: `community_op=directory|members`,
`cache_hit` (directory: the shared entry was warm), `rows_dropped` and `rows_dropped_by` ({inactive, blocked, blocked_by}), `fs_reads`.
**No index change:** the member pages order by `joinedAt` / `bannedAt` (field presence is the filter) and the directory by `memberCount`, all on
the automatic single-field indexes (ADR-0031 D3, proven on `dzeroth-dev`). A "requires an index" error here means stop and ask the founder; do
not add a `state ==` equality query.

| Symptom | Cause | What to do |
|---|---|---|
| A new, renamed, suspended or archived community still shows (or is missing) in the directory | The directory is one shared entry per instance, 5 minutes (`DirectoryTTL`), no per-viewer copy | Intended. Bounded to 5 minutes per instance; a restart refills it |
| Directory `viewer_role` lags a join, ban or eraser run by up to 60 s | The caller's memberships are cached 60 s for this list only; this instance's own Join, Leave and Create drop the entry at once | Intended. Join's cap and ListMyCommunities read fresh |
| First directory call on a cold instance costs about 51 reads | `ORDER BY memberCount DESC LIMIT 50` plus the caller's memberships; concurrent cold callers share one refill (singleflight). At Stage 0 (<= 20 communities) it is about 21 | Intended; at more than 50 communities the directory shows the top 50 only (a ticket for the W4 engine) |
| `FORBIDDEN reason=not_moderator` on the BANNED page | The caller is not the owner or a moderator in the (60 s cached) community document; the answer costs the community read only | Intended |
| `VALIDATION page_token` on a member page | Tampered, expired (24 h), or sealed for another caller, community or filter (the token binds `community_members\|uid\|cid\|filter`) | The client restarts the list. 0 reads |
| A member page is short, or empty, with a `next_page_token` | Rows of accounts that are not ACTIVE and (for a plain member) members who block the caller or whom the caller blocks are dropped after the page is read; the token follows the last row queried | Intended: keep following the token. The owner and moderators see every member either way (F14), so they can ban |

## 4c. Posting into a community and the community feed query (W5-26)

`CreatePost` with `community_id` runs `posts.CommunityGate` (ADR-0031 D5; implemented by `communities.PostGate`, wired late in `apiserver` with
`SetCommunityGate`). Order: flag, shape, protected caller, community status (60 s cache), then inside the transaction the member doc read
**fresh**, the quota write (`posts` and `communityPosts` in one `Set`) and the per `(uid, community)` daily cap. Extra cost over a plain
CreatePost: **+2 reads cold / +1 warm, +0 writes** (pinned by `TestCommunityPost_StoresFieldsAndBudgetDelta`). Request-line fields:
`community_post` (bool) and `community_gate` (`admitted`, `rejected`, `rejected:protected`, `rejected:forbidden`, `rejected:quota`,
`rejected:cap`), never the id or name. A set `community_id` with the flag on but no gate wired logs `community_refused=not_wired`.

| Symptom | Cause | What to do |
|---|---|---|
| `FEATURE_DISABLED feature=communities` for a caller the flag is on for | The gate was not wired (`community_refused=not_wired`): a build without `SetCommunityGate`. The refusal is deliberate, so a post can never become an ordinary public post outside its community | Fix the wiring; never relax the refusal |
| `FORBIDDEN reason=not_member` / `banned` on a post | The member doc is read fresh in the transaction: a non-member, or a ban made on any instance a moment ago | Intended. A ban is lifted only by `SetMemberRole` (W5-28) |
| `COMMUNITY_STATE community_archived` / NOT_FOUND on a post | Status comes from the 60 s community cache, so an archive or suspension on another instance reaches posting within 60 s | Intended |
| `RATE_LIMITED limit=community_posts_per_community_daily` | 20 posts per community per user per IST day per instance (`COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY`; effective x max-instances). The cap is drawn inside the transaction after the quota check, once per call: a refusal and a replay are not charged, a transaction retry is not charged twice, a commit that fails after the draw is | Wait for IST midnight; tune only with abuse numbers |
| `QUOTA_EXCEEDED quota=community_posts` | 50 a day (10 for a new account), counted in `quotas.communityPosts` on top of `posts`; a refusal charges neither | Wait for IST midnight |
| `PROTECTED_ACCOUNT` on a post | A protected caller cannot post into a public community (F6), 0 reads | Intended |
| `FORBIDDEN reason=not_member` on a reply | W5-26b: the parent's `conversationCommunityId` names a community the caller has not JOINED (a banned user gets the same answer), from the 60 s member cache | Intended; see section 4d |

`posts.Reader.ByCommunity` (the W5-27 feed's query) is `communityId == C ORDER BY __name__ DESC` with id-bound windows, on the automatic
single-field index (proven on dev, ADR-0031 D3). If Firestore ever answers `FAILED_PRECONDITION "requires an index"` for it, **stop**: the
fallback is the founder-gated composite `posts (communityId ASC, createdAt DESC)`; do not route it through `FirestoreRepo.run()`. The emulator
does not enforce indexes, so only the dev smoke (W5-40: F1, F2b, F3b on real posts) proves it.

## 4d. Members-only replies and the label kill switch (W5-26b)

A reply whose parent carries `conversationCommunityId` (every reply inherits it; a hidden root keeps it) runs `CommunityGate.CanReply` in
`posts.Create`, after the block and ADR-0021 reply-policy rules and before the transaction: the community status (SUSPENDED or missing is the one
NOT_FOUND, ARCHIVED is `COMMUNITY_STATE community_archived`) and the caller's member doc, both from the 60 s caches. Not JOINED, and BANNED, is
`FORBIDDEN reason=not_member`, 0 writes. Cost over the same reply in a plain conversation: **+2 reads cold / +0 warm, +0 writes** (pinned by
`TestCommunityReply_MembersOnlyAndBudget`); a reply to a non-community post is unchanged. A ban or leave on another instance reaches the reply path
within 60 s (posting, unlike replying, reads the member doc fresh).

Request-line field `community_reply_gate` (replies into a community conversation only): `admitted`, `rejected:not_member`, `rejected:state`,
`error`. `error` is a failed status or member read, returned as a wrapped Internal error that Error Reporting groups (no ids in the message).

`viewer_reply_permission` (ADR-0031 A7, no new enum value): GetPost and GetThread answer `NOT_ALLOWED` for a viewer who is not a JOINED member of the
conversation's community (+1 read cold for the member doc, +0 warm; a failed lookup is UNKNOWN). Home, profile, list, search and
bookmark rows keep the ordinary answer, 0 reads.

**The label kill switch.** `PostView.post.community` is decided only in `posts.ToView` (`communityRef`): present when the post carries `community`,
`communityHidden` is absent and `FEATURE_COMMUNITIES` is not globally off (mode `off` only; an allowlist or percent rollout is not the kill switch).
With the flag globally off, replies are not gated either (`CreateInput.CommunitiesGloballyOff`) and GetPost and GetThread skip the member read:
community posts behave as ordinary posts. Turning the flag back on needs no data change.

| Symptom | Cause | What to do |
|---|---|---|
| A new member cannot reply right after joining | The serving instance's member cache (60 s) still says "not a member" | Wait up to 60 s; the join refreshes the joining instance at once |
| A hidden post still blocks non-members from replying | By design: `conversationCommunityId` survives a hide | Intended |
| Community labels vanish everywhere | `FEATURE_COMMUNITIES=off` (the kill switch) | Intended; set the flag back to `on`, `allowlist` or `percent` |
| `community_reply_gate=error` spike | A failed Firestore read of the community or member doc | Check Firestore health; replies into community conversations fail closed, all other replies are unaffected |

## 4e. The community feed and the COMMUNITY Home tab (W5-27)

`TimelineService.GetCommunityTimeline` (`backend/internal/timeline/service_community.go`) reads a **shared per-community entry** (the newest 30
posts, one per community per instance, `CACHE_COMMUNITY_FEED_ENTRIES` 100) for cold opens and `since` refreshes, and `posts.Reader.ByCommunity`
for older pages. Order: flags (`communities`, then `posts`), shape and tokens (0 reads), community (missing or SUSPENDED is the one NOT_FOUND,
ARCHIVED is readable), `removed_ids` check, the caller's role, the rows, then the caller's graph and userLikes (skipped when no row came back).
Wire reads (interceptor included): cold **page + 5** (25 at page 20, 55 at page 50), warm 3, empty `since` refresh 4 cold, NOT_FOUND 2, writes 0.
Request-line fields: `timeline_op=community`, `timeline_mode`, `timeline_cache_hit`, `items_returned`, `items_filtered`, `removed`,
`viewer_role` (an enum name), never an id or text.

Staleness bounds: a post written on another instance appears within 60 s (the entry refills incrementally at the next call after that, charged to
that caller, `1 + new posts` reads, never more than the page size); a hide reaches this instance within the 60 s of the cached community
document (`recentRemovals` is applied to every entry row); the LRU drops an entry after 5 min whatever happens, which bounds a row that is no
longer listed (a hide older than the capped array) and a restore that put a post back below the entry's range. A hide or restore handled on
this instance: a **committed restore** (RestoreCommunityPost, outcome Written; not a replay, a no-op or a refusal) calls `timeline.Server.ForgetCommunityFeed(cid)` through `communities.Deps.OnPostRestored`, wired in `apiserver` (W5-57), so the next feed read on that instance cold-fills and returns the restored post (0 Firestore ops at the call, in-process only; the refill is 25 / 55 wire reads at page 20 / 50 once). A hide does not call it (`recentRemovals` already drops the row). A restore handled on another instance keeps the 5-minute bound above.

| Symptom | Cause | What to do |
|---|---|---|
| `GetCommunityTimeline` answers UNIMPLEMENTED for a caller inside the flag | `timelineServer.SetCommunities(...)` was not called in `apiserver` (the stub answer of W5-22) | Fix the wiring; the call must precede `ListenAndServe` |
| Clients cold-open every few refreshes in one community (`removed_reset=true` on the request line, VALIDATION `since_token`) | More than 50 hides since the token was issued: `removalsTruncatedAt` is newer than the token's cutoff (ADR-0031 A3) | Intended: the client replaces its cache. If it is every refresh, the community is being hidden faster than the clients poll; check the modlog, not the code |
| A restored post does not come back on a device | The restore deletes its `recentRemovals` entry, so it is never listed; a device that dropped the card gets it at the next cold open (as `restore-post` on Home) | Intended |
| A moderator sees posts by users who block them; members do not | F14: the "author blocks the viewer" drop is waived for the OWNER and MODERATORS only; their own blocks and mutes, and protected authors, still drop | Intended |
| `UNAVAILABLE` on the feed | The protected-author set could not be loaded younger than `PROTECTED_SET_MAX_STALE` (the page is never served unfiltered) | Same as Home; see the identity runbook |
| `SetHomeTabs` answers VALIDATION `tabs` for a COMMUNITY tab | The community is missing or SUSPENDED (one answer for both), or the build does not wire communities | Intended / fix the wiring |

## 5. Deleting an account that owns, moderates or joined communities (W5-24)

The `communities` step runs after `poll_votes` and before `identity` (step names are persisted in `deletionJob.step`; this one was
appended, never inserted). It is never flag-gated: the documents outlive the flag. It reads `communityMemberships/{uid}` (1 read),
takes the union `joined + owned + banned + modlogged` in sorted order and, **per community, in one transaction**:

1. deletes the member doc (and lowers `memberCount` by 1 only if it was `JOINED`; a banned member never counted);
2. removes the uid from `moderatorIds`;
3. for an **owned** community, hands it over to the **first ACTIVE uid in `moderatorIds`** (appointment order): that moderator becomes
   `ownerId`, leaves `moderatorIds`, gets the community in its own `owned` and `modlogged`, and an `OWNER_HANDOVER` log entry (actor
   `_deleted`, target the new owner) is appended. If no moderator can take over, `ownerId` becomes `""` and an ACTIVE community becomes
   **ARCHIVED** (read-only, out of the directory; name, description and rules stay). A SUSPENDED community stays SUSPENDED, ownerless;
4. rewrites every log entry that names the uid as actor or target to `_deleted` (the action and time stay).

Then it deletes the memberships doc. One invocation handles up to 10 communities and resumes from the last community id in the
checkpoint (`{"after": "<community id>", ...}`), so a crash between communities loses nothing and a rerun writes nothing.

Cost for the reference account (2 joined communities): 5 reads, 2 writes, 3 deletes. Per owned community with moderators add at most 10
profile reads (cache-first) and 10 memberships reads. An account with no memberships pays 1 read.

Export: the `communities` section is `{joined, owned, banned, moderationActions, redactedCount}`. It never names another user (no
moderator ids, no log targets, no post ids). A joined or banned community that is now SUSPENDED (and not the user's own) only raises
`redactedCount`. Reads: 1 + 2 per community (the community doc and the user's own member doc, which carries `joinedAt` and `bannedAt`).

| Symptom | Cause | What to do |
|---|---|---|
| Deletion job stuck at step `communities` (the `account_job` lines repeat, `deletionJob.step = communities`) | A transaction keeps failing for one community: contention on a viral community's doc (`community_txn_attempts`, `communities_txn_contention`), or a document that no longer decodes | Read the redacted error in Error Reporting. Contention clears by itself (the job retries with backoff). For a poison document, fix that one `communities/{cid}` document by hand, then the next delivery finishes. The checkpoint resumes at that community; nothing else is lost |
| A community has `ownerId ""` and is ARCHIVED | Its owner deleted the account and no ACTIVE moderator could take over (F12) | Intended. If the community should live on, a founder can set a new `ownerId` by hand in the console **and** add the community to that user's `communityMemberships.owned` (I-M); there is no RPC for transfer at Stage 0 |
| A hand-over went to an unexpected moderator | The first moderator in appointment order was not ACTIVE (deleting or suspended), or had no memberships doc (being deleted): the next one took over | Intended. `moderatorIds` is in appointment order |
| The residue sweep names `communities/{cid}#modlog` after a deletion | A log entry still names the uid: the community was not in the user's memberships (I-L broken by a writer that forgot `modlogged`) | Fix the writer (every modlog append adds the community to both users' `modlogged` in the same transaction). Clean the one document by hand |

## 6. Platform levers: suspend, restore, archive, reports and removals (W5-29)

Three operator commands (`go run ./cmd/opsctl community ... --project P`; a `*-prod` project asks for the project id typed in; each takes
`--dry-run` and prints `cost: reads=... writes=...` last; the community id appears only as `community_hash`, the keyed hash the request
lines carry (W5-52: before it was the unkeyed `HashUID`, so older operator output does not match the logs; now it needs `CURSOR_HMAC_KEY` in the shell, else it prints `unavailable(set-CURSOR_HMAC_KEY)`), in a fixed-shape `audit:` line, because the document records no platform actor):

| Command | What it does | Cost (reads / writes) |
|---|---|---|
| `community suspend CID [--report R] [--note N]` | Field-level `Update` of `status = SUSPENDED` and `updatedAt`. `--report R` first checks R is a COMMUNITY report of exactly this id (a typo cannot close another report), then resolves it as `TAKEDOWN` after the write, also when the community was already suspended | 1 / 1; a repeat 1 / 0; `--report` +1 read to check, +1 / +1 to resolve |
| `community restore CID` | `status = ACTIVE` when `ownerId` is set, else `ARCHIVED`. Only a SUSPENDED community changes; anything else is "not suspended", 0 writes | 1 / 1; otherwise 1 / 0 |
| `community archive CID` | An owner's support request (F12). One transaction: `status = ARCHIVED`, `ownerId = ""`, an `OWNER_HANDOVER` modlog entry (actor the former owner, empty target), and the community leaves the owner's `owned` and joins their `modlogged` (I-M, I-L). The former owner **stays a member**. Refused for a SUSPENDED community (restore it first: archiving would quietly lift the suspension). **No undo**: `restore` keeps an ownerless community ARCHIVED; to give it a new owner follow section 5 ("A community has `ownerId ""`") | 3 (community, owner memberships, owner member doc) / 2; a repeat 1 / 0 |

Every command is a field-level `Update` inside a transaction, never a `Set`: a missing community is refused ("no such community", exit 1) and
never created. **Reach.** opsctl is a separate process and cannot evict an api instance's cache, so a change reaches every warm instance within
**60 s** (the community cache, section 4); the command prints that line. A SUSPENDED community is `NOT_FOUND` ("community not found") on every RPC for everyone, with the same bytes and the same
read count as an id that never existed (the feed, the member lists, the moderation log, `JoinCommunity`, the reply gate); `CreatePost` into it is refused the same way; it is out of the directory. Only `GetCommunity` and
`ListMyCommunities` show it to its owner, with status `SUSPENDED`. A screen already open keeps its copy until it refreshes. An ARCHIVED community is
read-only (posting, joining and editing refused) and out of the directory.

**Reports.** `ReportContent` accepts the COMMUNITY target (`REPORT_TARGET_TYPE_COMMUNITY`; behind `FEATURE_REPORTS` for the caller and `FEATURE_COMMUNITIES` not
globally off, the LIST and MESSAGE rule: someone dropped from the allowlist can still report what they saw). `target_id` is the community id; the
report's owner is the community owner (`""` when ARCHIVED). A missing or SUSPENDED community and the caller's own community are not distinguishable from outside
(the one NOT_FOUND "community not found"; an own community is VALIDATION `target_id`). The evidence is kept in the report document: the owner's handle, the name, the
description, the rules and the creation time (public text, no member or moderator id, no child document), with the usual retention (resolved + 90 days). Cost: 5 reads cold / 2 warm (interceptor, community, owner profile, report,
`quotas`), 2 writes. Reports of a community's **posts** use the POST target. `reports show` prints the snapshot; act with `community suspend CID --report R` (the
`target` of the report) or resolve with `reports resolve`. The request line has `report_target=COMMUNITY` and the existing `outcome`.

**Takedowns and suspensions reach the community feed.** `takedown-post` of a community post also appends `{postId, now}` to that community's `recentRemovals`
(`communities.PlatformRemovals`), so the next `since_token` refresh of the community feed lists it in `removed_ids` within 60 s; it reads `communityId` from the post it already reads
(+1 read, +1 write; a repeat or an already listed post writes nothing). `suspend-user` does the same per page of hidden posts, once per community per page (+1 read,
+1 write per community per page), for the community posts of the page whether they were just hidden or already were, so a re-run after a crash finishes the job. The cap is the community's
50 newest entries: a **spam account with more than 50 community posts in one community rolls the log**, sets `removalsTruncatedAt`, and every device whose cached feed is older
than that cold-opens that community (a rejected `since_token`, about 25 reads each), exactly as with a burst of moderator hides (section 7). A post a community moderator
already hid has no `communityId` and is not listed again (its entry exists). A deleted community is a note in the output (`missing=1`), not an error. `restore-post` and `unsuspend-user`
do not touch the log (D6): their entries age out.

| Symptom | Cause | What to do |
|---|---|---|
| A suspended community still shows on one device | The device's cached copy, or an instance that cached it less than 60 s ago | Intended; wait 60 s, the client refreshes on its next open |
| `community archive` says "the community is SUSPENDED" | Archiving would lift the suspension | `community restore CID`, then `community archive CID` |
| `community restore` left the community ARCHIVED | It has no owner (an archive, or an owner who deleted the account) | Intended; section 5 for giving it an owner by hand |
| `takedown-post` printed `community removal log: ... missing=1` | The post's community document no longer exists | Nothing to do; the post is hidden either way |
| `takedown-post` failed with "(re-run takedown-post to finish)" | The removal-log append failed after the post was hidden | Run it again: the takedown is idempotent and the append finishes the job |
| After `suspend-user`, followers see a cold open of a community feed | More than 50 removals rolled that community's log | Intended (see above); nothing to do |
| A COMMUNITY report cannot be filed (NOT_FOUND) | The community is missing or SUSPENDED, or `FEATURE_COMMUNITIES` is globally off (then FEATURE_DISABLED `feature=communities`) | Intended |

## 7. Moderation: hide, restore, roles, bans and the log (W5-28)

`HideCommunityPost`, `RestoreCommunityPost`, `SetMemberRole` and `ListModerationLog` run behind `FEATURE_COMMUNITIES` (`communities.Moderation`; the post
write goes through `posts.CommunityModerator.SetCommunityListing` inside the same transaction). Request-line fields: `community_op=hide|restore|role|log`,
`mod_action=hide|restore|ban|unban|make_moderator|remove_moderator|log`, `outcome` (`done`, `noop`, `replay`, `rejected:not_moderator`, `rejected:not_owner`,
`rejected:moderator`, `rejected:invalid_target`, `rejected:limit_reached`, `rejected:post_not_found`, `rejected:user_not_found`, `contention`), `community_txn_attempts`,
`fs_reads`, `fs_writes`; never a raw id. Every request that can write a modlog entry (hide, restore including replies, ban, unban, make or remove moderator, update, a moderator's leave) also carries the keyed `community_hash`; hide and restore add `post_hash`, role actions add `target_hash` (W5-52, ADR-0031 D13a; HMAC with the key derived from `CURSOR_HMAC_KEY`, so a hash cannot be recomputed from an id without the secret, and a secret rotation changes every hash: use the version live when the lines were written). `go run ./cmd/opsctl community loghash [--community CID] [--post ID] [--user UID]` (no project; `CURSOR_HMAC_KEY` in the shell, from the `cursor-hmac-key` secret) prints them, and `--user` also prints the plain `uid_hash` to join a target to that user's own lines. Budget: 0 reads, 0 writes. Budgets (module only, interceptor excluded): Hide / Restore 4 reads, 3 writes for a post or a reply (+1 on the actor's first entry in the
community); SetMemberRole 5 reads, BAN 4 / UNBAN 3 + 1 delete / MAKE or REMOVE 2-3 writes (+1 first entry, worst 5); a request that changes nothing writes only the
idempotency document. Every change appends one `modlog` entry (newest `COMMUNITY_MODLOG_MAX` kept) and adds the community to the `modlogged` of the actor and of
the target (I-L), which is what lets the account-deletion eraser find and scrub them.

A hide **deletes `posts.communityId` and sets `communityHidden`**; a restore puts `communityId` back and deletes the flag. Both also write `communityHiddenAt` (server time of the hide; a restore deletes it; absent on posts hidden before W5-51b, no backfill). **A reply (W5-51b, ADR-0031 Amendment 1 D4a)** whose `conversationCommunityId` is this community can be hidden and restored by the owner and moderators through the same two RPCs: it has no `communityId`, so a hide sets `communityHidden` and `communityHiddenAt` only and a restore deletes both; the modlog entry is written as for a post, with the reply id and no author, and **no `recentRemovals` entry** is written (the feed never lists replies). The F16 `not_owner` rule and the platform-removal NOT_FOUND apply to replies unchanged. GetThread drops a hidden reply for every viewer but its author (`rows_dropped` cause, request field `audience_dropped_community_hidden`; a reply to it keeps its place and "Replying to"; as a focal post's parent it is an unavailable parent; a hidden focal reply and a hidden root are served as before; replying to a hidden reply stays allowed): +0 reads. The request line adds `mod_target=post|reply` (absent on a replay). The post stays on the author's
profile and in Home (it is never `Hidden()`); only the community feed and the community label change. The label of a post already cached by the posts module
(post cache, author-recent cache) can show for up to `CACHE_TTL` (60 s) after a hide; the community feed does not depend on it (it drops the id through
`recentRemovals`). `recentRemovals` keeps the newest 50 `{postId, at}`; when the cap drops an entry, `removalsTruncatedAt` is set to its `at`, and a device whose
cached feed is older than that gets a cold open (a rejected `since_token`) instead of a removal list. A flood of hides is bounded by `COMMUNITY_MOD_ACTIONS_PER_DAY`
(200 per actor per instance, effective x max-instances).

| Symptom | Cause | What to do |
|---|---|---|
| `FORBIDDEN reason=not_moderator` on a hide, restore, ban, unban or the log | The caller is not in `ownerId` / `moderatorIds` of the community document read fresh in the transaction (the log reads the 60 s cached document) | Intended. A moderator removed on another instance can still read the log for up to 60 s |
| `FORBIDDEN reason=not_owner` on a ban | A moderator tried to ban the owner or another moderator, or anyone but the owner tried MAKE / REMOVE_MODERATOR | Intended |
| `COMMUNITY_STATE reason=moderator` on a ban | The owner banned a moderator | Remove the role first (`REMOVE_MODERATOR`), then ban |
| `LIMIT_REACHED limit=community_moderators` | The community has `COMMUNITY_MAX_MODERATORS` (10) | Remove a moderator first |
| `NOT_FOUND "post not found"` on a hide or restore | The post is gone, is a REPOST or a plain post, is a root not created into this community (`community.id` differs), or is a reply whose `conversationCommunityId` is not this community (another community's conversation, or none; W5-51b) | Intended. 0 writes, no idempotency document |
| `FORBIDDEN reason=not_owner` on a hide or restore (W5-53, F16) | A moderator (not the owner) acted on a post whose author is the owner or another current moderator. The author's role is the one in the community document now, so a post by a former moderator can be hidden; a moderator can act on their own post; the owner can act on every post | Intended. Asked of the one post read already made (+0 reads) and before any write: nothing is written, no idempotency document, the same key stays free. `outcome=rejected:not_owner`, `mod_action=hide|restore` || `NOT_FOUND "post not found"` on a hide or restore of a post that was taken down or whose author was suspended | The post carries `moderation` (W5-53, L-2): a hide and restore must never touch a platform removal, so a hide then restore cannot erase it. The `recentRemovals` entry from the takedown stays | Intended; lift the removal with `opsctl restore-post` / `unsuspend-user`. `outcome=rejected:post_not_found` |
| `NOT_FOUND "post not found"` on a hide or restore of a taken-down post or one by a suspended author (W5-53, L-2) | The post carries `moderation`: a hide and restore must never touch a platform removal, so a hide then restore cannot erase it. The takedown's `recentRemovals` entry stays | Intended; lift the removal with `opsctl restore-post` / `unsuspend-user`. `outcome=rejected:post_not_found` |
| A moderator hid a reply and it still shows to another viewer (W5-51b) | GetThread's conversation query reads fresh, so a new page drops it at once. A device keeps a thread it already loaded until it fetches it again (threads have no `removed_ids`); the parent slot of a reply to it reads the post cache-first, so another instance can show it there for up to `CACHE_TTL` (60 s) | Intended. Nothing to fix; the author always sees their own reply |
| A hidden reply is in the community's modlog but not in `recentRemovals` | Replies are never in the community feed, so a reply hide writes the modlog entry only (R1) and feed tokens stay valid | Intended |
| Replies are hidden and the flag is `off` | GetThread drops a hidden reply whatever the flag state (R5): the kill switch must not undo a moderation decision. Hide and Restore are FEATURE_DISABLED while the flag is off for the caller | Intended; the platform lever for a raid is `opsctl community restore-hidden` (W5-52b) |
| A hidden post still shows its community label on one device | The label comes from the cached post (60 s) | Intended; the feed already dropped the post |
| A late retry of a hide did not hide the post again | The standard idempotency document answers a replay with 0 writes, so a retry after a restore cannot re-hide (A13) | Intended: send a new idempotency key to hide again |
| A user is BANNED but still counted in `memberCount` | A ban of a JOINED member lowers `memberCount` in the same community Update; a count that disagrees points at a writer other than `SetMemberRole` | Recount by hand (JOINED member docs) and fix the writer |
| `modlog` is shorter than the actions taken | Only the newest 100 entries are kept; older ones are dropped by design | Intended; the request log keeps one line per action |

## 8. Rogue moderator or community raid (W5-52b, ADR-0031 Amendment 1 D14a)

Use this when a moderator (or a hijacked moderator account) hides posts and replies that should stay, or a raid fills a community with abuse. The
in-app tools hold only the newest 100 modlog entries and 50 `recentRemovals`, so the platform levers below read the posts themselves.
Triggers: a report or support mail about vanished posts, a spike of `mod_action=hide` on one `community_hash`, or a `rejected:` burst on one actor.

**1. Identify.**
- *Modlog.* `ListModerationLog` (owner and moderators) shows the newest 100 entries with the actor; a platform run shows as the platform, not a person.
- *Request lines.* One line per moderation request carries `mod_action`, `outcome`, `uid_hash` (the actor) and, from W5-52, `community_hash`,
  `post_hash` and `target_hash`, keyed with `CURSOR_HMAC_KEY` (so the key version live when the line was written must be used). Logs Explorer,
  `resource.type="cloud_run_revision" AND resource.labels.service_name="api"`:
  - `jsonPayload.community_op=("hide" OR "restore" OR "role") AND jsonPayload.community_hash="<H>"` for one community;
  - add `AND jsonPayload.uid_hash="<U>"` for one actor, and group by `jsonPayload.mod_action` and `jsonPayload.outcome`;
  - `opsctl community loghash --community CID` prints the `community_hash` to paste (W5-52); `opsctl community hidden` and `restore-hidden` print the same keyed value (or
    `unavailable(set-CURSOR_HMAC_KEY)` when the shell has no key). Use the key version that was live when the lines were written.
- Count the damage with `opsctl community hidden CID` (step 3), not from the capped arrays.

**2. Contain.** Choose the smallest lever that works.
- A rogue moderator: the owner removes the role (`SetMemberRole` REMOVE_MODERATOR, then BAN if needed).
- A rogue or hijacked owner, or a raid the owner cannot handle: `opsctl community suspend CID` (NOT_FOUND to everyone within 60 s; the owner still sees it), else
  `FEATURE_COMMUNITIES=off` (a Terraform change; hidden replies stay hidden, R5). Section 6 has the commands.
- Sock accounts: `opsctl suspend-user --uid U` (hides their posts, adds the community posts to `recentRemovals`) or `takedown-post`.

**3. List.** `go run ./cmd/opsctl community hidden CID --project P [--page-token T]`. It is read-only and prints, per row, the post id, `root` or `reply`, the hide time
(`unknown` for a post hidden before W5-51b wrote `communityHiddenAt`; there is no backfill) and `moderation=set` for a post under a platform takedown. It never prints text
or a user id; the community appears only as `community_hash`. Fifty rows a page; the line `page: ... next_page_token=` resumes the next one. Cost: 1 read (the
community) + max(1, rows) per page. The query is `conversationCommunityId == C AND communityHidden == true` ordered by document id; it was proven on `dzeroth-dev` (plan W5-52b).

**4. Undo.** `go run ./cmd/opsctl community restore-hidden CID --project P [--since T] [--dry-run]`.
- Always `--dry-run` first: it makes the same reads and prints `listed`, `would_restore`, `skipped_platform`, `skipped_no_time` and `skipped_other` (a REPOST or a root labelled with another community, never restored).
- `--since T` (RFC 3339, UTC, for example the time of the first suspicious `hide` line) restores only posts hidden at or after T. It is applied in memory on every hidden row,
  so a `--since` run reads as much as a full one. A row with no hide time is **not** restored under `--since` (`skipped_no_time`); a run without `--since` restores it. Decide
  those by hand: list them with `community hidden` and judge by post id and neighbours.
- A post with `moderation` set (a platform takedown or a suspended author) stays hidden and is counted in `skipped_platform`; its `recentRemovals` entry stays too.
- Each page is one transaction with the community document (field-level updates, never a `Set`): up to 50 post restores, the restored roots' `recentRemovals` entries deleted,
  and, in the first page that restores anything, **one** modlog entry for the whole run (RESTORE, actor `_platform`, no post id). A re-run restores nothing and writes nothing.
  A crashed run that is run again may add a second entry. The counts are in the printed `audit:` line, not in the modlog.
- Budget per page: at most 51 reads (1 community + 50 posts) and 51 writes. A run stops after 100 pages (5,000 post writes, a quarter of the Firestore free write quota of a day);
  run it again, or with `--since` resume with the printed `--page-token`. Check `make cost` before a very large run.
- **Reach.** opsctl cannot evict a server cache. A restored root is back in community feeds within **5 minutes** (`communityEntryMaxAge`); a restored reply is back in thread pages
  at once and in parent slots within 60 s. Devices that cached the feed or a thread keep their copy until they refresh.
- It works in any community status (a SUSPENDED community is recovered too) and in any flag state.

**5. Clean a raid.** Ban the accounts (`SetMemberRole` BAN), hide the posts and replies (HideCommunityPost works on replies since W5-51b), and use `takedown-post` and `suspend-user`
for sock accounts. Hides of replies write the modlog only (no `recentRemovals` entry), so a hundred of them do not roll the removal log. If the clean-up itself overreached, step 4 undoes it.

**6. Residual (I-7).** The platform can act on a whole community, but it cannot replace a rogue owner, and `restore-hidden` cannot stop the owner hiding again.
The only way to change the owner is the console edit of section 5: set `ownerId` by hand **and** add the community to that user's `communityMemberships.owned` (I-M).
Until an in-app transfer exists, suspend the community and decide with the founder.

| Symptom | Cause | What to do |
|---|---|---|
| `community hidden` says "no such community" | A wrong id, or the community document was deleted | Check the id; the listing needs the community document (1 read) |
| `restore-hidden` restored fewer posts than `listed` | `--since` cut, `moderation` set, or no hide time (`skipped_*` counts) | Intended; see step 4 |
| A restored post is still missing from the feed | The shared feed entry lives up to 5 minutes on each instance | Wait 5 minutes; devices refresh on their own schedule |
| A restored root has no community label | It was a REPOST, or its label names another community (never restored) | Intended; only posts created into this community return |
| The `modlog` shows a RESTORE with no person | The platform marker `_platform` of a `restore-hidden` run | Intended; an older client shows "A moderator restored a post" |
