# Communities runbook

Status: **W5-23 + W5-24.** `CreateCommunity`, `UpdateCommunity` and `GetCommunity` write and read the data model; the lifecycle
(eraser step `communities`, export section, owner hand-over) is live whether or not the flag is on. The other nine RPCs answer
`UNIMPLEMENTED` past the flag until W5-25 (join, leave, the lists) and W5-28 (moderation). Design:
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
