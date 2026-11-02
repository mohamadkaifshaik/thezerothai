# Communities runbook

Status: **W5-23, W5-24 + W5-25.** `CreateCommunity`, `UpdateCommunity` and `GetCommunity` write and read the data model; `JoinCommunity`,
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
| `UpdateCommunity` returns `community_archived` for the owner | The community was archived (`opsctl community archive`, W5-29) | Intended: ARCHIVED is read-only. Restoring is an operator action |
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

## 4b. Posting into a community and the community feed query (W5-26)

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
| A reply in a community conversation is not gated yet | W5-26 only copies `conversationCommunityId` into replies (+0 reads); the members-only reply gate is W5-26b | Until W5-26b the flag stays off |

`posts.Reader.ByCommunity` (the W5-27 feed's query) is `communityId == C ORDER BY __name__ DESC` with id-bound windows, on the automatic
single-field index (proven on dev, ADR-0031 D3). If Firestore ever answers `FAILED_PRECONDITION "requires an index"` for it, **stop**: the
fallback is the founder-gated composite `posts (communityId ASC, createdAt DESC)`; do not route it through `FirestoreRepo.run()`. The emulator
does not enforce indexes, so only the dev smoke (W5-40: F1, F2b, F3b on real posts) proves it.

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

## 6. Suspension (placeholder for W5-29)

`opsctl community suspend|restore|archive` arrive with W5-29; until then nothing sets `SUSPENDED` or `ARCHIVED` except the eraser's
archive-on-owner-deletion. A SUSPENDED community is `NOT_FOUND` ("community not found") on every RPC for everyone, with the same
bytes and the same read count as an id that never existed; only `GetCommunity` and `ListMyCommunities` show it to its owner, with
status `SUSPENDED`. It reaches every instance within 60 s (section 4, staleness).

## 7. Hidden posts and `recentRemovals` overflow (placeholder for W5-28)

`HideCommunityPost` (W5-28) appends `{postId, at}` to `recentRemovals` (newest 50 kept) and sets `removalsTruncatedAt` to the `at` of
the newest entry a cap ever dropped; a device whose cached feed is older than that cannot be told what was removed and gets a cold
open (a rejected `since_token`). Nothing writes either field in W5-23/24, so today `recentRemovals` is `[]` and `removalsTruncatedAt`
is absent. A flood of hides is bounded by `COMMUNITY_MOD_ACTIONS_PER_DAY` (200 per actor per instance).
