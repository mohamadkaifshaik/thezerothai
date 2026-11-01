# Communities runbook

Status: **skeleton (W5-22).** The flag, config, limits and the empty module exist; nothing writes a community yet. W5-23 + W5-24 add
the data model, the lifecycle and the failure modes of the data (eraser, export, owner hand-over), and extend this file. Design:
`docs/adr/0031-communities-and-moderation-scope.md`; contract: `proto/dzeroth/communities/v1/communities.proto`.

## 1. The flag and the kill switch

`FEATURE_COMMUNITIES` (wire name `communities`, Terraform `feature_communities*`) is `off` in every environment. It gates every
`CommunityService` RPC, `TimelineService.GetCommunityTimeline`, `CreatePost.community_id` and (from W5-27) the COMMUNITY entries of
`SetHomeTabs` and `GetMe.home_tabs`. Outside the flag the answer is FAILED_PRECONDITION + `FEATURE_DISABLED`,
`metadata["feature"] = "communities"`, with 0 Firestore reads beyond the account-status interceptor.

- Dev ceiling: `allowlist`, at most 3 uids (`scripts/promotion/flag-ceiling.json`); there is no prod block (the prod apply is held,
  ADR-0019). `communities` never ramps ahead of `lists`.
- Kill switch: set `feature_communities = "off"` and deploy. The data stays; nothing to migrate.
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
| `COMMUNITY_POSTS_PER_COMMUNITY_PER_DAY` (`community_posts_per_community_daily`) | 20 | 60; per `uid\|cid` (the posts gate, W5-26) |
| `CACHE_COMMUNITIES_ENTRIES` / `CACHE_COMMUNITY_FEED_ENTRIES` / `CACHE_COMMUNITY_MEMBERS_ENTRIES` | 200 / 100 / 5,000 | per instance, 60 s |

A user who sees `RATE_LIMITED` with `metadata["limit"]` = one of the three daily names has hit the in-memory cap for the day (it
resets at IST midnight and per instance; a new revision resets it). A `QUOTA_EXCEEDED` with `quota` = `community_joins` or
`community_posts` is the Firestore quota record.
