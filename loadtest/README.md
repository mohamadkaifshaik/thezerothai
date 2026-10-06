# Load tests (load-testing skill: $0 by default, everything runs on emulators)

Every scenario here runs against the **Firebase Emulator Suite + a local `cmd/api` process** — never
Cloud Run or real Firestore (see `.claude/skills/load-testing`). Cost/budget conclusions come from reading
`fs_reads`/`fs_writes` in the API's JSON logs and extrapolating with `docs/reviews/cost-model.md`, not from
how many requests k6 manages to fire.

## Prerequisites

- `k6` installed locally (`choco install k6` / `brew install k6` / see https://k6.io/docs/get-started/installation/).
  `make loadtest` does not install it for you; if it's missing the target just fails with `k6: command not found`.
- Emulators running: `make emulators` (or `firebase emulators:start --project demo-dzeroth-local --only firestore,auth,pubsub,storage`).
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

The graph scenarios share `graph_common.js`, and `analyze_logs.js` turns the API log into per-RPC mean/p95
`fs_reads`. They share 127.0.0.1, so raise `RATE_LIMIT_PER_IP_PER_MIN` and `RATE_LIMIT_PRE_AUTH_IP_PER_MIN` on the
API for the run (and only those). To run beside another emulator suite, use `firebase.graph-loadtest.json`
(Firestore 18080, Auth 19099, Pub/Sub 18085, Storage 19199) and API `PORT=18081`, with `API_URL` and
`AUTH_EMULATOR_HOST` set accordingly. Measured results and findings: `docs/reviews/loadtest-graph.md`.

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
`MIN_F`, `MAX_F`, `REFRESH_RATE`, `OLDER_RATE`, `USER_RATE`, `NEW_POST_RATE`, `DURATION` (`timeline_read`). Raise rates only
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
