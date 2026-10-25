# Graph emulator load smoke (T18)

Date: 2026-09-30. Plan: `docs/plans/graph.md` T18. ADR: `docs/adr/0008-social-graph.md` (A2 budget table).
Consumer: T21 (cost report / `cost-model.md` update). Emulators only, $0. No cloud access was used.

## Setup

- Machine: Windows 11 Home, 16 logical CPUs (Go reports GOMAXPROCS=16), local desktop, other work running
  (a concurrent `make test-int` on the default emulator ports). Latency is indicative only.
- Tools: k6 v2.2.0, Go 1.26.6, firebase-tools 15.31.0. API built from this branch (base `f92a636`) with
  `go build ./cmd/api`, run as a binary (no compile time in the numbers).
- Emulators on non-default ports via `firebase.graph-loadtest.json` (Firestore 18080, Auth 19099, Pub/Sub 18085,
  Storage 19199, hub 14400, logging 14500, UI off); API on port 18081. The default ports were left alone.
- API env: the local defaults plus **only** `RATE_LIMIT_PER_IP_PER_MIN=1000000` and
  `RATE_LIMIT_PRE_AUTH_IP_PER_MIN=1000000`. Reason: every k6 VU shares 127.0.0.1, and 20 rps is 1,200 req/min
  against a 120/min per-IP default. All per-user limits, daily quotas (50 follows/day new-account, 200 blocks, 100
  list calls/day, 500 graph mutations/day) and the graph flag stayed at their defaults; no threshold was changed.
- Each run used a freshly started API (cold instance caches) and freshly minted Auth-emulator users
  (`setup()`), so per-user quotas start from zero.
- Numbers below: k6 p95 is client-side (includes k6 and localhost overhead); `fs_*` and server latency come from the
  API's one-line-per-request JSON log (`node loadtest/analyze_logs.js <log>`). 20 rps for 2 min = 2,400 iterations.

## Results

| Run | Calls | k6 p95 | Server p95 | mean fs_reads | max fs_reads | fs_writes / deletes | ERROR lines | Result |
|---|---|---|---|---|---|---|---|---|
| `graph_follow` churn (Follow, 1,200 calls) | 1,200 | **20.2 ms** (limit 500) | 17 ms | **3.96** | 4 | 5 / 0 | 0 | p95 PASS, reads see below |
| `graph_follow` churn (Unfollow, 1,200 calls) | 1,200 | 16.9 ms all calls | 8 ms | **1.00** | 1 | 3 / 1 | 0 | reads exceed documented 0 |
| `graph_follow` MODE=follow_only (Follow) | 2,400 | **7.5 ms** (limit 500) | 6 ms | **3.98** | 4 | 5 / 0 | 0 | p95 PASS, reads see below |
| `graph_lists` ListFollowers, page 20 | 2,401 | **17.1 ms** (limit 400) | 16 ms | **20.16** | 42 | 0 / 0 | 0 | PASS |
| `graph_lists` GetRelationships, 20 ids (5 rps alongside) | 601 | 4.3 ms | 3 ms | **0.11** | 2 | 0 / 0 | 0 | PASS |

All requests returned 200 (0% `http_req_failed`, 0 unexpected responses, 0 ERROR and 0 WARN log lines in every run).

### Acceptance check (T18)

| Criterion | Result |
|---|---|
| 20 rps for 2 min | Met (2,400 iterations per run, 19.94 iterations/s) |
| Follow p95 < 500 ms | PASS: 20.2 ms (churn), 7.5 ms (follow-only) |
| ListFollowers p95 < 400 ms | PASS: 17.1 ms |
| mean fs_reads/call <= typical budget | ListFollowers PASS (20.16 <= 30 planning); GetRelationships PASS (0.11 <= 0.5); **Follow FAIL vs planning value 3 (measured 3.96 and 3.98); within the cold ceiling of 4.** Unfollow measured 1.00 vs the documented 0 |
| 0 ERROR log lines | PASS |

### Findings for T21 (reported, not tuned away)

1. **Follow mean is ~4 reads, not the ADR-0008 A2 planning value of 3.** It sits on the documented cold ceiling
   (4) on 96-99% of calls. Even the follow-only variant (no Unfollow in between, 50 callers, 50 targets) never got
   the "target warm" case. Cause visible in the code: a successful Follow calls `directory.Forget(caller, target)`
   (`backend/internal/graph/rpcs.go`), so the caller's profile is cold on the caller's next call
   (`AccountStatusInterceptor` reads it) and the target profile is cold on the next Follow that touches it. The
   planning value assumed the target is warm from the profile or list row the user just saw. With 3 instances and
   scale to zero that is even less likely. Suggest T21 plans Follow at 4 reads (1.5 -> 2.0 reads/DAU, +0.25 graph
   reads/DAU/day at 0.5 calls/DAU), or the architect revisits the `Forget` on the target. That is a design call,
   not made here.
2. **Unfollow reads 1, documented 0.** The read is not in the Unfollow batch (still 0 reads / 3 writes / 1 delete).
   It is the caller's `AccountStatusInterceptor` profile read after the preceding Follow's `Forget` evicted the
   caller. In real sessions an Unfollow that follows any Forget-ing mutation will show this. The 0 in the ADR table
   is the RPC's own reads; the per-request `fs_reads` log field includes the interceptor's. Worth a footnote in
   the cost model rather than a code change.
3. **ListFollowers 20.2 mean at page 20 is a warm-pool number.** The 100 callers and 5 targets stay resident in the
   instance cache for the whole run, so hydration is almost all hits. Cold requests in the run cost 40-42 reads
   (max), matching the "one follows page + hydration" ceiling. The planning value (30) was not exceeded, but the
   cache hit rate here is higher than a 300-DAU Stage 0 instance will see; treat 20 as a floor.
4. GetRelationships mean 0.11 reads (563 of 601 calls were 0 reads); worst 2 (cold caller profile + graph doc).
5. The per-user limiters were not hit at 24 calls/user/min (Follow/Unfollow limit 30/min), but the 30/min limit is
   only 25% above this test's 24/min per user, so a client that retried aggressively would see `RESOURCE_EXHAUSTED`.
6. Per-IP limit: with defaults (120/min) this test cannot run from one machine; production traffic arrives with
   many client IPs (and Hosting/Google-egress XFF hops), so this is a test artifact, not a finding.

## Reproduce

```sh
firebase emulators:start --config firebase.graph-loadtest.json --project demo-dzeroth-loadtest \
  --only firestore,auth,pubsub,storage                # non-default ports, see README
FIREBASE_PROJECT_ID=demo-dzeroth-loadtest FIRESTORE_EMULATOR_HOST=localhost:18080 \
  FIREBASE_AUTH_EMULATOR_HOST=localhost:19099 PUBSUB_EMULATOR_HOST=localhost:18085 PORT=18081 \
  RATE_LIMIT_PER_IP_PER_MIN=1000000 RATE_LIMIT_PRE_AUTH_IP_PER_MIN=1000000 \
  ./api.exe > api.log                                  # restart the API between runs for a clean log
API_URL=http://localhost:18081 AUTH_EMULATOR_HOST=localhost:19099 k6 run loadtest/graph_follow.js
API_URL=http://localhost:18081 AUTH_EMULATOR_HOST=localhost:19099 MODE=follow_only k6 run loadtest/graph_follow.js
API_URL=http://localhost:18081 AUTH_EMULATOR_HOST=localhost:19099 k6 run loadtest/graph_lists.js
node loadtest/analyze_logs.js api.log
```

The `graph_lists` API log also contains the 495 seed `Follow` calls from `setup()`; ignore that row.
