# Test report: social graph (T17, milestone M4), 2026-09-30

Tester: tester agent. Branch `feat/graph-t17` on `main@f92a636` (graph backend, Flutter app, T16a/T16b emulator suites and the
security fixes are all merged). Plan: `docs/plans/graph.md` (T16a, T16b, T17). Design: ADR-0008.

**VERDICT: PASS, with one documented flaky test (section 6) and two environment caveats (section 7).**
Every measured per-RPC read/write/delete count is at or under its budget. No test failed on a deterministic basis.

---

## 1. What was run

| Suite | Command | Result |
|---|---|---|
| `make ci` (fmt, vet, unit tests with coverage gate, buf lint, buf breaking, flutter analyze, flutter test) | `GOWORK=off make ci` | **green** (exit 0; Flutter 143 tests passed, `flutter analyze` no issues) |
| Go integration on emulators, run 1 | `GOWORK=off GOFLAGS=-v make test-int FIREBASE=firebase` (Firestore, Auth, Pub/Sub, Storage) | **green** (exit 0; 722 PASS, 0 FAIL, 0 SKIP; internal/ coverage gate 89.4% vs 70%) |
| Go integration on emulators, run 2 (after adding the T17 GetProfile budget test) | same tests via `firebase emulators:exec --only firestore,auth,storage` (see caveat 7.1) | **green** (723 PASS, 0 FAIL, 0 SKIP; 89.4%) |
| New E2E graph smoke | `TestE2E_GraphSmoke_FollowListBlockUnblock` | PASS in both runs (about 3 s) |
| Flutter | `flutter test` (inside `make ci`) | 143 passed (139 before this ticket, +4 added here) |

`-race` was not run: CGO is unavailable on this Windows machine, so the Makefile `RACE_FLAG` is empty. See caveat 7.2.

## 2. New in this ticket

1. `backend/e2e/graph_smoke_test.go` (`TestE2E_GraphSmoke_FollowListBlockUnblock`). Same style as `identity_smoke_test.go`
   (build tag `integration`, real `apiserver.Build` handler, Auth-emulator ID tokens, real Firestore, no mocks).
   - Emulator mode (default): creates two users and profiles, then runs the flow below.
   - Remote mode: set `E2E_GRAPH_BASE_URL`, `E2E_GRAPH_ID_TOKEN_A`, `E2E_GRAPH_ID_TOKEN_B` (two pre-provisioned smoke
     accounts with profiles; on prod they must be on the `FEATURE_GRAPH` allowlist). uid and handle come from `GetMe`.
     Polls up to 90 s for a peer instance's 60 s graph cache to expire. Not run against any cloud URL (rules: no prod).
   - Flow: pre-clean; A follows B; `GetRelationships(A,[B])` is FOLLOWING; `ListFollowers(B)` contains A; A can read B's
     profile; B blocks A; A's `GetProfile(B)` is NOT_FOUND by user_id and by handle; B's `GetRelationships` shows
     blocking; B unblocks; A can read B's profile again.
   - Clean-up (`t.Cleanup`, runs on failure too): Unblock(B->A) and Unfollow(A->B) with fresh idempotency keys, so
     the test is re-runnable on the same accounts. Fresh keys per call so re-runs never replay a cached response.
   - Cost per run: about 17 requests (cap 100), about 15 reads and 12 writes, matching the T17 budget of 15/12.
2. `backend/internal/graph/get_profile_budget_integration_test.go` (`TestT17_GetProfile_BlockEnforcement_Budget`).
   **Gap found and closed:** the plan budget for `IdentityService.GetProfile` with the block check wired (3 reads worst)
   had no measured assertion, because identity's own budget tests run without a `BlockChecker`. The new test wires a
   cold instance (fresh caches, same Firestore) and measures cold, warm and blocked paths.
3. `app/test/features/profile/presentation/profile_screen_test.dart`: 4 new widget tests (section 5).

## 3. Per-RPC budget: measured vs budget

Measured values are the `BUDGET ...` and `READS ...` lines emitted by the T16a/T16b/T17 tests (`budget.WithCounter` around
each call; `budgettest.Assert` fails the test on a regression). Budget = `docs/plans/graph.md` Cost table (worst case).
The "scenario" column names the measured case that hit the worst number.

| RPC | Scenario | Measured R / W / D (worst) | Budget R / W / D | Status |
|---|---|---|---|---|
| Follow | cold identity cache, new edge | 4 / 5 / 0 | 4 / 5 / 0 | OK (at budget) |
| Follow | warm, typical | 2 / 5 / 0 | 2 / 5 / 0 (typical) | OK |
| Follow | replay, same key, cold | 4 / 0 / 0 | 4 / 0 / 0 | OK |
| Follow | replay, new key, warm | 2 / 0 / 0 | 2 / 0 / 0 | OK |
| Follow | overflowed caller (blockedBy at cap) | 3 / 5 / 0 | 5 / 5 / 0 | OK |
| Follow | rejected: blocked-by, private target, at cap, quota exhausted, self, bad input, flag off | 0 to 4 / 0 / 0 | 0 to 4 / 0 / 0 | OK (no writes on any rejection) |
| Unfollow | existing edge | 0 / 3 / 1 | 0 / 3 / 1 | OK |
| Unfollow | no-op, replay, after block, self, flag off | 0 / 0 / 0 | 0 / 0 / 0 | OK |
| Block | worst: mutual follow | 3 / 5 / 2 | 3 / 5 / 2 | OK (at budget) |
| Block | typical: no edges | 3 / 3 / 0 | 3 / 3 / 0 | OK |
| Block | one-way follow | 3 / 5 / 1 | 3 / 5 / 2 | OK |
| Block | target `blockedBy` at cap | 3 / 3 / 0 | 3 / 3 / 0 | OK |
| Block | replay, at cap, quota exhausted | 3 / 0 / 0 | 3 / 0 / 0 | OK |
| Unblock | seeded block | 1 / 2 / 0 | 1 / 2 / 0 | OK |
| Unblock | no-op (same or new key) | 1 / 0 / 0 | 1 / 0 / 0 | OK |
| Mute | normal | 2 / 2 / 0 | 2 / 2 / 0 | OK |
| Mute | replay, at cap, quota exhausted | 2 / 0 / 0 | 2 / 0 / 0 | OK |
| Unmute | normal / no-op | 1 / 1 / 0 and 1 / 0 / 0 | 1 / 1 / 0 | OK |
| GetRelationships | cold / warm (60 s cache) | 1 / 0 and 0 / 0 | 1 / 0 (typical 0.5) | OK |
| ListFollowers / ListFollowing | page 20, warm caches (first page) | 42 (first page, all rows are hydration misses) | 42 | OK (at budget) |
| ListFollowers / ListFollowing | page 20, cold | 41 | 42 | OK |
| ListFollowers / ListFollowing | page 50, warm | 50 | 102 | OK |
| ListFollowers / ListFollowing | page 50, cold (worst) | 101 | 102 | OK |
| ListBlockedUsers / ListMutedUsers | page 20 cold / warm | 21 / 1 | 21 | OK |
| ListBlockedUsers / ListMutedUsers | page 50 cold (worst) / warm | 51 / 1 | 51 | OK |
| ListFollowRequests, RespondToFollowRequest (flag-off stubs) | any | 0 / 0 / 0 | 0 | OK |
| Rejected page tokens (tampered, wrong list) | any | 0 reads | 0 | OK |
| IdentityService.GetProfile with block check (**new T17 test**) | cold instance / warm / blocked (NOT_FOUND) | 2 / 0 / 2 reads, 0 writes | 3 reads | OK |
| GetMe | unchanged by the graph slice (`enabled_features` comes from env) | not re-measured here (identity suite, unchanged) | 2 / 1 | OK by identity suite |

Every list RPC at page 20 and 50 stays at or under budget; the two at-budget cells (List page 20 warm first page = 42,
Follow cold = 4) are exact matches, not headroom, so any extra read is caught immediately by `budgettest.Assert`.

Purge (T11, `TestPurgeUser_Integration_StepBudgets`): passed; step budgets are O(edges) as documented.

Daily-total implication (plan cost table, 300 DAU): unchanged. Nothing measured exceeds the plan numbers, so the plan's
about 11.8 reads and 2.9 writes per DAU still hold.

Measured better than budget (informational, for sre-performance T21): GetProfile with block check is 2 reads cold, not 3
(the target graph read is not needed because `blockedBy` lives on the viewer's own graph, ADR-0008 Q2). The plan and the
proto comment may be tightened from 3 to 2 if T21 wants.

## 4. Coverage

| Scope | Coverage | Gate |
|---|---|---|
| `backend/internal/` combined unit + integration (`make test-int`, `-coverpkg=./internal/...`) | **89.4%** | 70% - pass |
| `internal/graph` | 89.6% (930 statements) | - |
| `internal/identity` | 89.5% (449) | - |
| `internal/apiserver` | 86.7% (60) | - |
| `pkg/platform` (unit, gate in `make test`) | passes the 70% gate inside `make ci` | 70% - pass |
| Flutter (graph and profile files, from `flutter test --coverage`) | `paged_user_list` 43/43 lines, `graph_list_screen` 60/61, `user_list_row` 21/22, `follow_button` 23/23, `user_list_cubit` 33/33, `managed_accounts_screen` 50/65, `profile_screen` 43/48, `profile_header` 90/123 before this ticket (higher now), `block_confirmation_dialog` 0/8 before this ticket (now covered) | no numeric gate; Definition of Done is a widget test per screen |

Uncovered graph Dart lines are error-message mapping branches (`graph_error_messages.dart` 2/10) and generated protobuf.

## 5. Flutter: widget test per new graph screen

| Screen or widget | Test file | Status |
|---|---|---|
| `GraphListScreen` (Followers / Following tabs) | `test/features/graph/presentation/graph_list_screen_test.dart` (7 tests: pagination 45 rows as 3 pages, empty, rate-limited, lazy Following tab, uid via extra or GetProfile, retry) | covered |
| `BlockedAccountsScreen`, `MutedAccountsScreen` | `.../managed_accounts_screen_test.dart` (3 tests incl. unblock with undo) | covered |
| `ProfileScreen` + `ProfileHeader` (Follow, banner, overflow menu) | `test/features/profile/presentation/profile_screen_test.dart`: 6 existing + **4 added** (Block confirmation Cancel never calls API; confirm Block calls API and shows banner; banner Unblock restores Follow; overflow Mute) | covered (was missing the block dialog and menu paths) |
| Settings entries "Blocked accounts" / "Muted accounts" (flag-gated) | `test/features/settings/presentation/settings_screen_test.dart` | covered |
| `FollowButton` | `test/shared/widgets/follow_button_test.dart` | covered |
| `PagedUserList`, `UserListRow` (no separate screens) | exercised through the list-screen and managed-account tests (100% and 95% line coverage) | covered indirectly; no dedicated file (judged not needed) |
| Cubits and repository | `relationship_cubit_test`, `user_list_cubit_test`, `graph_repository_test`, `graph_feature_flags_test` | covered |

Not done: golden tests and `integration_test` against a local API (no such harness exists in `app/` yet; outside T17).

## 6. Matrix results (T16a and T16b, from the run-1 and run-2 logs)

All 66-plus budget/matrix cells pass. Areas covered by the emulator suites and their outcome:

| Area | Result |
|---|---|
| Visibility/block matrix: every RPC vs blocker/blocked/third party (`TestListFollowing_Integration_BlockMatrix`, `visibility_t16b`) | PASS, every cell matches ADR-0008 |
| Byte-identical NOT_FOUND for blocked-by vs missing (`TestNotFound_Integration_ByteIdentical`, identity unit test) | PASS |
| `blockedBy` never in any response or export (serialized JSON grep) | PASS |
| Pagination completeness, stability, exact-multiple page, removed-between-pages | PASS |
| Tampered / cross-list cursors; token leaks no hidden uid (M1 fix); rejected tokens cost 0 reads | PASS |
| Daily list cap (`TestLists_Integration_DailyCap`), mutation daily cap (M2 fix) | PASS |
| Quotas: standard vs new-account tier, exhausted, configurable | PASS |
| Idempotency: same-key and new-key replays for every mutation | PASS |
| Invariants: `follows` doc exists iff `b in graph/a.following`, counters equal edges, `blockedBy` mirrors `blocked` (swept after every scenario by `assertGraphInvariants`) | PASS |
| Concurrency: 24-way duplicate Follow (`..._ConcurrentDuplicateFollows`) | PASS |
| Concurrency: 24-way duplicate Block and Mute (`..._ConcurrentDuplicateBlocksAndMutes`) | **FLAKY, see below** |
| Purge crash-resume (T11, T16b) | PASS |
| L9: `UpdateProfile(is_private=true)` rejected; private-account paths unreachable | PASS |
| Flag off: every RPC FEATURE_DISABLED with 0 reads and 0 writes | PASS |
| Wire level (T16b): real Connect stack, error details, auth required | PASS |

### Known flaky test (not hidden)

`TestT16a_Race_ConcurrentDuplicateBlocksAndMutes` (`backend/internal/graph/mutations_integration_test.go:909`).
- **Symptom:** many of the 24 goroutines return `temporarily busy, please retry` (the Firestore emulator's transaction lock
  timeout under 24-way contention on one `graph/{uid}` doc). Assertion fails at line 909.
- **Rate observed:** run 1 (full `make test-int`) passed; run 2 (full suite) passed; a dedicated `-count=8` run failed at
  least one iteration (33.5 s wall clock vs about 3 s when passing, i.e. the retry budget was exhausted); a second
  `-count=8` run passed 8 of 8. Roughly 1 in 10 to 1 in 20 by this small sample.
- **Repro:** start emulators, then `go test -C backend -count=8 -tags=integration -run TestT16a_Race_ConcurrentDuplicateBlocksAndMutes ./internal/graph/`.
- **Assessment:** an emulator lock-contention artifact, not a correctness bug. When it fails it fails with the documented
  retryable ABORTED-style error, never with a wrong counter or a violated invariant. Real Firestore uses optimistic
  contention with server-side retry; the plan's Stage 0 rule is at most about 1 sustained write per second per doc.
  It still violates the flakiness policy (a flaky test is a bug): file to **backend-developer/tester** either to lower the
  goroutine count to about 8, or to have the test tolerate `Unavailable`-class errors as long as the final state is
  consistent. Not quarantined by me because it is in T16a's scope; it is the only known instability.

## 7. Caveats and things not verified

1. **Emulator environment.** During the second full run, port 8085 (Pub/Sub emulator) was held by a foreign `java.exe`
   (another session's emulator), so `make test-int` refused to start. Run 2 used the same `go test` command directly under
   `emulators:exec --only firestore,auth,storage`. No graph test needs Pub/Sub. Run 1 was the real `make test-int` (needs
   `FIREBASE=firebase` on this Windows box, because make cannot execute the `/c/...` path the Makefile derives; a
   Makefile portability defect, not fixed here, owner **production-deployer/backend-developer**).
2. **No `-race` run.** CGO is off on this machine. The 24-way concurrency tests ran without the race detector. CI
   (Linux) should be checked for a `-race` pass before the release readiness gate.
3. **Smoke never ran against a real Cloud Run URL.** Remote mode is written and compiles, but by rule nothing was pointed
   at prod or dev. T23/T24 run it on dev and on the prod `candidate`.
4. **Firestore emulator vs production behavior:** budgets are counted at the repository wrapper, so they are exact for
   our own reads/writes. Transaction contention behavior differs on real Firestore (see the flaky test).
5. No load test (T21, sre-performance) and no security re-test (T20 is a separate report, `docs/reviews/security-review-graph.md`).

## 8. Defects filed

| # | Severity | Owner | Location | Detail |
|---|---|---|---|---|
| D-T17-1 | Low | tester / backend-developer | `backend/internal/graph/mutations_integration_test.go:909` | Flaky 24-way Block/Mute race test; see section 6 |
| D-T17-2 | Info | production-deployer | `Makefile:29` (`FIREBASE :=`) | `command -v firebase` yields a `/c/...` path that GNU make on Windows cannot spawn; use `firebase` (PATH) instead |
| D-T17-3 | Info | architect | `docs/plans/graph.md` (Cost table, GetProfile row) and `proto/dzeroth/graph/v1/graph.proto` comment | Measured GetProfile with block check is 2 reads cold, budget says 3; optional tightening |

No blocker defects.

## 9. Acceptance criteria (T17)

- Given `make ci` and `make test-int`, both green: **met** (run 1 exactly as specified with the `FIREBASE=firebase` override; run 2
  as described in 7.1).
- Given the report, verdict PASS with every RPC's measured reads/writes at or under budget: **met** (section 3).
- Smoke test cleans up after itself so it can be re-run on prod `candidate`: **met** by design (`t.Cleanup` with fresh keys,
  pre-clean at start); re-run on emulators not repeated in the same emulator instance, but the pre-clean plus cleanup make
  the two runs idempotent.

VERDICT: PASS
