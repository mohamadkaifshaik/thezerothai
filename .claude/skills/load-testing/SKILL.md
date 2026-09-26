---
name: load-testing
description: Low-cost k6 load testing — full runs against the local emulators, tiny budget-capped smoke runs in the cloud. Use when validating performance, cold starts or read/write budgets.
---

# Load testing without burning money

Load tests against real Firestore/Cloud Run **cost real reads and writes**. A 10-minute run at 100 RPS ≈ 60k requests
and can blow a day's Firestore quota. So:

## 1. Local (default, $0)
- `make emulators` + `go run ./backend/cmd/api` + `make loadtest SCENARIO=<name>`.
- Seed: `loadtest/seed` creates 2k users, power-law follows, 50k posts in the emulator.
- Scenarios: `timeline_refresh`, `post_create`, `like`, `profile`, `mixed` (90/8/2).
- Measure what matters at Stage 0: **Firestore reads/writes per request** (from the `fs_reads`/`fs_writes` log fields),
  CPU ms per request, memory per instance, cache hit rate. Latency on emulators is indicative only.
```js
export const options = {
  scenarios: { mixed: { executor: 'constant-arrival-rate', rate: 50, timeUnit: '1s', duration: '3m', preAllocatedVUs: 50 } },
  thresholds: { http_req_failed: ['rate<0.01'] },
};
```

## 2. Cloud smoke (dev project, capped)
- ≤ 2,000 requests total, read-heavy; run against the **dev** project only, never prod.
- Purpose: cold-start time, real p95 at low concurrency, confirm instance count stays ≤ max-instances.
- Record: cold start ms, warm p50/p95, Firestore reads consumed (console Usage tab before/after).

## 3. Capacity estimate instead of brute force
Extrapolate with the budget table: `reads/request × requests/DAU × DAU`. Report the DAU at which each free quota is hit
and the monthly cost at 2× and 10× that DAU. That report is the pass/fail artifact, not a 10k RPS run.

Pass criteria (Stage 0): no RPC exceeds its documented read/write budget; warm p95 < 400 ms at 10 concurrent users on dev;
free quotas hold for the current DAU target with ≥ 20% headroom.
