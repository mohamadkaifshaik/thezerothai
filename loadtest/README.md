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
