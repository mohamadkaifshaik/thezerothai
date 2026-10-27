---
name: testing-strategy
description: Test conventions, tooling and commands for Go and Flutter using the Firebase Emulator Suite (no cloud cost). Use when writing or running tests.
---

# Testing ($0 by default — everything runs on emulators)

## Go
- Table-driven: `tests := []struct{name string; in X; want Y; wantErr error}{...}`; `t.Parallel()`.
- `go test -race -shuffle=on -coverprofile=cover.out ./...`; coverage gate 70% on `internal/`.
- Integration tag `//go:build integration`, run by `make test-int` against the **Firebase Emulator Suite**
  (`firebase emulators:exec --only firestore,auth,pubsub,storage 'go test -tags=integration ./...'`).
  Each test uses a unique project ID (`demo-test-<rand>`) so data never collides — the emulator treats `demo-*` projects as offline.
- **Concurrent emulator suites (several agents on one machine).** Unique project IDs and different ports do **not** isolate the
  Storage emulator: it keeps its blobs in `os.tmpdir()/firebase/storage/blobs`, shared machine-wide, and a second suite
  starting or stopping wipes it, so the first dies mid-upload (`ENOENT ... firebase\storage\blobs\<id>`, then the Auth emulator
  refuses connections). `make emulators`, `make test-int` and `make dev` already run behind `scripts/with-private-tmp.sh`
  (a private per-run `TEMP`/`TMP`/`TMPDIR`, removed afterwards). A raw `firebase emulators:*` call must be wrapped the same way:
  `bash scripts/with-private-tmp.sh firebase emulators:exec ...`. For ports and the leftover-`java.exe` rules see
  `docs/runbooks/emulator-collisions.md`.
- **Budget assertions:** repository wrapper counts reads/writes; integration tests assert each RPC stays within its
  documented budget (e.g., `assert.LessOrEqual(t, counter.Reads, 12)`). A budget regression fails CI.
- Fuzz tests (`go test -fuzz`) for parsers: mentions, hashtags, URLs, cursors.
- Benchmarks for hot paths (`BenchmarkTimelineMerge`), compare with `benchstat`.

## Flutter
- `flutter test --coverage`; mock repos with `mocktail`; test blocs with `bloc_test` (`blocTest`: events in → states out) and widgets by supplying a mock bloc via `BlocProvider.value`.
- Goldens with `alchemist`; update only intentionally.
- `integration_test` against local API + emulators; run on Android emulator and `-d chrome`.
- **Dates in tests.** A fixed absolute date (`DateTime.utc(2026, 10, 14)`, an ISO string, an epoch literal) must never be compared with the
  real clock, directly or through a widget that calls `DateTime.now()`: the test passes on the day it is written and goes red later with no
  code change. Cautionary example: the notification fixtures used a fixed date while the screen compared against the real clock, and the
  spoken relative time stops saying "ago" after 7 days, so the suite failed a week later (2026-10-21). Two accepted patterns: **inject**
  `now`/a clock (every `PostCard` in the tests gets `now: _now`), or build the date **relative to the real clock** once (`kNotifBase` in
  `test/support/notifications_fixtures.dart`: `DateTime.now()` truncated to the second, `minutesAgo` subtracted from it). The guard test
  `test/guards/fixed_date_guard_test.dart` enforces this: it scans `app/test` for fixed dates and fails for any file not in its allowlist,
  where each entry carries the reason the date cannot meet the real clock (stale entries fail too). It finds fixed absolute dates only, not
  every clock dependence.

## E2E / API
- Go e2e suite in `backend/e2e`: runs against emulators in CI; against the prod `candidate` tagged URL as a < 100-request smoke with test accounts.

## CI cost
GitHub Actions: cache Go modules, pub cache and the emulator JARs; run Flutter iOS builds only on release tags.

## Flakiness policy
No `time.Sleep` for sync — use `eventually` helpers with timeout. Flaky test = bug, quarantine with ticket.
