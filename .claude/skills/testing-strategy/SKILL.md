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
- **Budget assertions:** repository wrapper counts reads/writes; integration tests assert each RPC stays within its
  documented budget (e.g., `assert.LessOrEqual(t, counter.Reads, 12)`). A budget regression fails CI.
- Fuzz tests (`go test -fuzz`) for parsers: mentions, hashtags, URLs, cursors.
- Benchmarks for hot paths (`BenchmarkTimelineMerge`), compare with `benchstat`.

## Flutter
- `flutter test --coverage`; mock repos with `mocktail`; test blocs with `bloc_test` (`blocTest`: events in → states out) and widgets by supplying a mock bloc via `BlocProvider.value`.
- Goldens with `alchemist`; update only intentionally.
- `integration_test` against local API + emulators; run on Android emulator and `-d chrome`.

## E2E / API
- Go e2e suite in `backend/e2e`: runs against emulators in CI; against the prod `candidate` tagged URL as a < 100-request smoke with test accounts.

## CI cost
GitHub Actions: cache Go modules, pub cache and the emulator JARs; run Flutter iOS builds only on release tags.

## Flakiness policy
No `time.Sleep` for sync — use `eventually` helpers with timeout. Flaky test = bug, quarantine with ticket.
