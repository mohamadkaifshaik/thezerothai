# Load tests (load-testing skill: $0 by default, everything runs on emulators)

Every scenario here runs against the **Firebase Emulator Suite + a local `cmd/api` process** — never
Cloud Run or real Firestore (see `.claude/skills/load-testing`). Cost/budget conclusions come from reading
`fs_reads`/`fs_writes` in the API's JSON logs and extrapolating with `docs/reviews/cost-model.md`, not from
how many requests k6 manages to fire.

## Prerequisites

- `k6` installed locally (`choco install k6` / `brew install k6` / see https://k6.io/docs/get-started/installation/).
  `make loadtest` does not install it for you; if it's missing the target just fails with `k6: command not found`.
- Emulators running: `make emulators` (or `bash scripts/with-private-tmp.sh firebase emulators:start --project demo-dzeroth-local --only firestore,auth,pubsub,storage`;
  the wrapper gives the run a private temp directory so another suite on the machine cannot wipe the Storage emulator's blobs,
  `docs/runbooks/emulator-collisions.md`).
- The API running against those emulators, **on a port other than 8080** (the Firestore emulator already
  owns 8080 — see the Makefile's `dev` target comment):

  ```sh
  cd backend
  FIREBASE_PROJECT_ID=demo-dzeroth-local \
  FIRESTORE_EMULATOR_HOST=localhost:8080 \
  FIREBASE_AUTH_EMULATOR_HOST=localhost:9099 \
  PUBSUB_EMULATOR_HOST=localhost:8085 \
  PORT=8081 \
  go run ./cmd/api
  ```

  (`make dev` does the emulators + API part of this for you, on the same default port 8081, but also
  launches `flutter run -d chrome`, which you don't need for a loadtest run.)

## Scenarios

| Scenario | File | RPC under test | What it checks |
|---|---|---|---|
| `identity_getme` | `identity_getme.js` | `IdentityService.GetMe` | Steady-state (mostly cache-hit) latency and error rate for the highest-frequency identity call (cost-model.md: 4 calls/DAU/day) |
| `graph_follow` | `graph_follow.js` | `GraphService.Follow` / `Unfollow` | 50-user churn at 20 rps; Follow p95 < 500 ms; `MODE=follow_only` for a no-Unfollow variant |
| `graph_lists` | `graph_lists.js` | `GraphService.ListFollowers` (+ `GetRelationships` at 5 rps) | 100 callers, 5 targets with 99 followers; ListFollowers p95 < 400 ms |
| `posts_create` | `posts_create.js` | `PostService.CreatePost` | 150 new users, 20 rps x 2 min, unique idempotency keys (16 posts/user, inside 10/min and the 20/day new-account quota); p95 < 500 ms |
| `timeline_read` | `timeline_read.js` | `TimelineService.GetHomeTimeline` (refresh with `since_token`, older page) + `GetUserTimeline` | 200 users following 10-45 accounts (60 authors); 14 rps refresh + 2 rps older + 4 rps user timeline + 1 rps background CreatePost; refresh p95 < 400 ms |
| `engagement_bookmarks_list` | `engagement_bookmarks_list.js` | `EngagementService.ListBookmarks` (+ `AddBookmark` seeding) | W2-15: viewers with 100 bookmarks page at 20 and 50 (cold then warm, `PAIRS` pairs), 4 warm passes/s for 30 s; `MODE=budget` pages one viewer until `read_budget_daily` rejects. Cold first page 43 / 103 reads, later cold pages 40 / 100, warm 20 / 50; `read_budget_spent` rises by `fs_reads`. Needs `FEATURE_POSTS`, `FEATURE_BOOKMARKS`, `FEATURE_ENGAGEMENT` on and the seed limits raised (list in the file header); run `node loadtest/analyze_bookmarks.js api.log` for reads per page. Setup idles 75 s (> `CACHE_TTL`) so the first pass is cold |
| `list_timeline` | `list_timeline.js` | `TimelineService.GetListTimeline` (+ `SetHomeTabs`, `GetMe`, the `ListService` reads and writes) | W5-18: 50- and 150-member lists, cold page 20/50, refresh with 0 and 5 new, old token, owner, Home-shared author entries, 5 tabs, then a warm herd (8 iterations/s, 20 viewers) with p95 < 400 ms. Two extra 70 s idles keep tab and list-read cases cold; `node loadtest/analyze_list_timeline.js api.log k6.out` pairs the i-th step with the i-th request line; `node loadtest/list_timeline_sizes.js` for response bytes. Needs the limit list in the file header; results in `docs/reviews/cost-model.md` §17 |
| `profile_w3_part_a` | `profile_w3_part_a.js` | `TimelineService.GetUserTimeline` tabs MEDIA / REPOSTS (+ `GetProfile`, `GetProfileRelationship`), `EngagementService.ListLikedPosts`, `GraphService.ListSuggestedUsers` | W3-23, three `MODE`s: `tabs` (a solo cold call, 38 profile-open flows, then a viral load of `RATE` calls/s on one author's Media tab; cold 24, first call after the header 21, warm 20, page 50 second page 10), `likes` (`PAIRS` pairs of viewers with `LIKES` likes, cold then warm pass; `CAP_LIKES=1000` scrolls a capped list: 53 then 19 x 50), `suggestions` (viewers following `FOLLOWEES` accounts: cold 32 at the default `SUGGESTIONS_EDGE_LIMIT` 20 since ADR-0024 Amendment 2 (42 when it is set to 30, the 2026-10-27 measurement in cost-model section 12), then 0, then 1 after the 60 s profile cache; curated viewers 12; `FOLLOWEES=600 VIEWERS=1` stays at the cap, 32 by default or 42 at edge limit 30). The Media tab selects on `hasMedia`, which setup patches through the Firestore emulator REST API (`FIRESTORE_EMULATOR_HOST`, `FIREBASE_PROJECT_ID`). Needs the four W3 flags and `FEATURE_POSTS`, `FEATURE_GRAPH`, `FEATURE_ENGAGEMENT` on, the per-minute limits and seed quotas raised (list in the file header), and for `MODE=suggestions` `SUGGESTED_USER_IDS=$(node loadtest/analyze_w3_part_a.js --curated-ids 12)`; run `node loadtest/analyze_w3_part_a.js api.log` for reads per call position. Setup idles 65 to 75 s (> `CACHE_TTL` 60 s) so the first call is cold. Results: `docs/reviews/cost-model.md` section 12 |
| `private_accounts_w3b` | `private_accounts_w3b.js` | `GraphService.Follow` (request path), `ListFollowRequests`, `RespondToFollowRequest`; `IdentityService.GetMe` (request count); stranger `PostService.GetPost` and `TimelineService.GetUserTimeline` of a protected account | W3-37 (ADR-0025 Part B), one timeline of five scenarios against one local API: a viral protected account (`REQUESTERS` Follows from `VUS` users at once, default 560 on 40: `txn_attempts` 1, 3 reads / 3 writes each), ListFollowRequests at pages 20 and 50 (cold 41 to 42 / 102, warm 20 / 50), a Respond burst (`RESPOND_N` accepts and declines plus replays: accept 3 to 4 reads / 4 writes / 1 delete, decline 2 to 3 / 1 / 1), then `HERD` strangers at once and `REFUSE_RATE` stranger calls/s for `REFUSE_DURATION` (the protected-set singleflight: one refresh line per 60 s, `protected_set_reads=1`). Needs `FEATURE_POSTS`, `FEATURE_GRAPH`, `FEATURE_PRIVATE_ACCOUNTS`, `FEATURE_ENGAGEMENT` on, `CACHE_TTL=60s` and the limits raised (list in the file header); runs about 6 minutes (setup mints about 600 users, the phases are timed offsets). Reads are not a k6 metric: `node loadtest/analyze_w3_part_b.js api.log`. Results: `docs/reviews/cost-model.md` section 13 |
| `messaging` | `messaging.js` | `MessagingService.SendMessage`, `ListConversations`, `ListMessages` (first pages and `since` polls), `MarkConversationRead` | W7-23 (ADR-0027), one timeline of seven scenarios against one local API: first pages cold then warm (inbox of 20, threads of 20 and 50, 70 s after setup so every cache is older than `CACHE_TTL`), the server time of a solo poll on a quiet thread (`EMPTY_DURATION`), a poll herd (`PAIRS` x 2 users, default 300, polling every `POLL_INTERVAL` s, default 15, for `HERD_DURATION`, plus a `TRICKLE_RATE` sends/s), then `BURST_RATE` sends/s (default 50, the rule-3 counter-contention shape) for `BURST_DURATION` into one conversation and a `verify` pass that pages the thread and checks both unread counts. Needs `FEATURE_MESSAGING=on`, `FEATURE_GRAPH=on` and the limits raised (list in the file header); `FEATURE_NOTIFICATIONS` off (no push). Runs about 7.7 minutes plus a setup that mints 329 users. Reads are not a k6 metric: `node loadtest/analyze_messaging.js api.log k6.out` cuts the API log into the phases the script marks (`W723 PHASE`). `node loadtest/messaging_sizes.js` measures the response bytes (JSON and binary proto, identity and gzip) for the egress line. Results: `docs/reviews/cost-model.md` section 14 |
| `search` | `search.js` | `SearchService.SearchPeople`, `SearchPosts`, `GetTrends`, and `POST /internal/cron/trends-refresh` and `/internal/cron/daily-maintenance` | W4-23 (ADR-0028), one timeline of six phases against one local API: `cold_calls` (serial, 27 steps after a 70 s idle: People at limit 5 and 20 cold, same viewer warm, new viewer on a warm prefix entry, sparse and empty prefix, rejected and unsupported queries; SearchPosts TOP / LATEST / MEDIA page 1 on one tag, page_size 50, an older page, a Media scan at the 30-post cap), `refresh` (2,100 seeded posts: run 1 stops at the 2,000-post cap with a backlog, run 2 takes the rest, `fresh` skips, a quiet day, 120 new posts), `trends` and `trends_herd` (30 GetTrends a second for 40 s from 60 viewers), `typeahead_burst` (600 SearchPeople limit-5 calls in 15 s, half progressive prefixes of one shared handle, half random 2-character prefixes), `hot_tag` (50 new posts a minute on one tag and 8 SearchPosts a second for 75 s, longer than the 60 s tag TTL). Needs `FEATURE_SEARCH`, `FEATURE_TRENDS`, `FEATURE_POSTS`, `FEATURE_GRAPH`, `FEATURE_ENGAGEMENT`, `FEATURE_BOOKMARKS` on (the last two add the `userLikes` read the budget counts), `ENV=local`, `TRENDS_MIN_INTERVAL=30s`, and the limits raised (list in the file header); runs about 8 minutes plus a setup that mints 60 users and 2,100 posts (about 1 minute). Media is written through the Firestore emulator REST API (`FIRESTORE_EMULATOR_HOST`, `FIREBASE_PROJECT_ID`), no upload. Reads are not a k6 metric: `node loadtest/analyze_search.js api.log k6.out` cuts the API log by the `W4 PHASE` / `W4 STEP` markers; `node loadtest/search_sizes.js` measures the response bytes (JSON and binary proto, identity and gzip) for the egress line. Results: `docs/reviews/cost-model.md` section 15 |
| `poll_vote` | `poll_vote.js` | `EngagementService.VotePoll`, `PostService.CreatePost` (poll) and `GetPost` | W6-21 (ADR-0029), one timeline of four scenarios against one local API: `cold_calls` (serial, 16 steps after a 70 s idle: poll and plain CreatePost, a new vote cold and warm, replay, ALREADY_VOTED, a vote through a REPOST id, refusals, POLL_CLOSED, GetPost of closed and open polls), `hot_poll` (50 votes a second for 60 s on one poll from 3,000 distinct voters, the rule-3 shape), `mix` (10 calls a second over 20 polls), `verify` (poll.total equals the committed votes). Needs `FEATURE_POSTS`, `FEATURE_ENGAGEMENT`, `FEATURE_POLLS` on, `POLL_MIN_DURATION=1m`, `ENV=local` and the limits raised (list in the file header); about 4.7 minutes plus a setup that mints 3,308 users. Reads are not a k6 metric: `node loadtest/analyze_poll.js api.log k6.out`. The emulator does not reproduce Firestore's per-document write limit. Results: `docs/reviews/cost-model.md` section 16 |

The graph scenarios share `graph_common.js`, and `analyze_logs.js` turns the API log into per-RPC mean/p95
`fs_reads`. They share 127.0.0.1, so raise `RATE_LIMIT_PER_IP_PER_MIN` and `RATE_LIMIT_PRE_AUTH_IP_PER_MIN` on the
API for the run (and only those). To run beside another emulator suite, use `firebase.graph-loadtest.json`
(Firestore 18080, Auth 19099, Pub/Sub 18085, Storage 19199) and API `PORT=18081`, with `API_URL` and
`AUTH_EMULATOR_HOST` set accordingly. Start that suite behind `scripts/with-private-tmp.sh` too (ports alone do not stop two
suites sharing the Storage blob directory; `docs/runbooks/emulator-collisions.md`). Measured results and findings: `docs/archive/reviews/loadtest-graph.md`.

Run one with:

```sh
make loadtest SCENARIO=identity_getme
```

which is exactly `k6 run loadtest/identity_getme.js`. Override defaults with env vars, e.g.:

```sh
API_URL=http://localhost:8081 RATE=50 DURATION=1m NUM_USERS=50 make loadtest SCENARIO=identity_getme
```

| Env var | Default | Meaning |
|---|---|---|
| `API_URL` | `http://localhost:8081` | Base URL of the running `cmd/api` process |
| `AUTH_EMULATOR_HOST` | `localhost:9099` | Firebase Auth emulator host:port, used to mint real ID tokens |
| `NUM_USERS` | `20` | Distinct signed-up users created once in `setup()` and reused for every request |
| `RATE` | `20` | Requests/second (k6 `constant-arrival-rate`) |
| `DURATION` | `30s` | How long the timed scenario runs |
| `VUS` / `MAX_VUS` | `20` / `50` | Pre-allocated / max virtual users k6 may use to sustain `RATE` |

### Posts and timelines (T22)

`posts_create` and `timeline_read` reuse `graph_common.js` (`mintUsers`, `rpcCall`). Extra requirements on top of the
graph ones: `FEATURE_POSTS=on` on the API, and the per-IP limiters raised (`RATE_LIMIT_PER_IP_PER_MIN`,
`RATE_LIMIT_PRE_AUTH_IP_PER_MIN`). Per-user limits stay at defaults: the scripts spread calls over enough users to
stay inside them (home 6/min, CreatePost 10/min, 20 posts/day and 50 follows/day for new accounts). `timeline_read`
setup is slow (it seeds posts and follows, retrying on 429); `setupTimeout` is 900 s. For F up to 300 (ticket) raise
`QUOTA_NEW_ACCOUNT_FOLLOWS_PER_DAY`, `QUOTA_FOLLOWS_PER_DAY`, `RATE_LIMIT_GRAPH_FOLLOW_PER_MIN` on the API and set `MAX_F=300`.

```sh
make loadtest SCENARIO=posts_create  2>&1 | tee posts_create.k6.txt
make loadtest SCENARIO=timeline_read 2>&1 | tee timeline_read.k6.txt
```

Env: `NUM_USERS`, `RATE`/`DURATION`/`VUS`/`MAX_VUS` (`posts_create`); `NUM_USERS`, `NUM_AUTHORS`, `POSTS_PER_AUTHOR`,
`MIN_F`, `MAX_F`, `REFRESH_RATE`, `OLDER_RATE`, `USER_RATE`, `NEW_POST_RATE` with `NEW_POST_EVERY` (seconds per unit, default 10), `DURATION` (`timeline_read`). A refresh gap is followed with `gap_page_token` (tagged `home_gap`); those extra calls need `RATE_LIMIT_TIMELINE_PER_MIN` raised on the API. Raise rates only
together with `NUM_USERS`.

k6 thresholds encode only latency/error targets (CreatePost p95 < 500 ms; `home_refresh`, `home_older`, `user_timeline`
p95 < 400 ms; 0 unexpected responses). **Reads per RPC are not a k6 metric.** Capture the API stdout to a file and run:

```sh
node loadtest/analyze_logs.js api.log CreatePost GetHomeTimeline GetUserTimeline
```

Check mean `fs_reads` per rpc against the planning budget (CreatePost 2.5; home refresh 4 + new posts; older page ~30;
GetUserTimeline 11) and 0 ERROR lines. Older-page reads per page > 1.4 x page size flags the `k`-factor lever. The
`since_clamped` rate and the interceptor cold share are read from the corresponding log fields with `jq` on the same
log. Record the machine used; emulator latency is indicative only.

## Reading the results

1. **k6's own output** (`http_req_duration`, `http_req_failed`) — indicative only on emulators (load-testing
   skill §1: "Latency on emulators is indicative only"). A failing `profile_required_errors` or
   `http_req_failed` threshold means something is actually broken (auth, routing, a regression in GetMe),
   not just "the emulator is slow".
2. **The API's own JSON logs** (stdout of the `go run ./cmd/api` process) — every request line has
   `fs_reads`/`fs_writes`. For `identity_getme`, `fs_reads` should mostly be `0` (warm cache) with the
   occasional `1`-`2` (cache eviction/TTL expiry across the `NUM_USERS` pool) — never above the documented
   worst case of 2 (`proto/dzeroth/identity/v1/identity.proto` GetMe comment). If it's consistently 2, the
   instance cache isn't warming as expected — that's a regression, not a loadtest artifact.
3. **Capacity estimate, not brute force** (load-testing skill §3): don't chase a big `RATE` number here.
   Use the observed reads/request together with `docs/reviews/cost-model.md`'s `calls/DAU/day` figure to
   recompute the DAU at which Firestore's free quota is consumed, the same way that doc already does.

Pass criteria (Stage 0, load-testing skill): `http_req_failed` rate < 1%, warm p95 < 400 ms at low
concurrency, and `fs_reads`/`fs_writes` per call never exceed the documented budget.
