# Test report: account lifecycle (P8, ADR-0011)

Tickets: T11 (collection guard and residue allowlist), T16 (deletion chain on the emulators), T17 (export privacy and
access), T18 (E2E smoke, Flutter sweep, this report). Date: 2026-10-09. Branch `test/p8-t11-t18-lifecycle` at
`origin/main` f87a615 plus these tests. No production code was changed.

## Verdict: PASS for everything that can be verified without devices or cloud credentials

Two things are explicitly **not verified** and are not claimed:

1. **On-device client delete is not verified.** Re-authentication and Firebase client `User.delete()` for Google, Apple,
   password and web, and Apple token revocation, were not run on any device or browser. They are covered only by Dart
   unit and widget tests with fakes (T13, T14, T15) and remain open in the security review (T20). The server half (the
   `DeleteAccount` RPC, the job, the `REAUTH_REQUIRED` gate) is verified below.
2. **The `candidate` (prod) smoke has not been run.** `backend/e2e/account_smoke_test.go` has a remote mode
   (`E2E_ACCOUNT_BASE_URL` plus two fresh ID tokens). It has never been executed: this environment has no cloud
   credentials and no deployed revision. It belongs to T23.

## What was tested

| Layer | New or extended | Result |
|---|---|---|
| Unit, `make ci` (no emulator) | `apiserver/lifecycle_collections_guard_test.go`: T11 table, Q10 allowlist, source-scanning guard, 6 mutation cases proving the guard fails | PASS |
| Integration, deletion chain (T16) | `apiserver/account_lifecycle_crash_integration_test.go`, `..._reference_integration_test.go`, `..._sweep_integration_test.go` | PASS |
| Integration, export (T17) | `apiserver/account_lifecycle_export_integration_test.go` plus `testdata/account_export_golden.json` | PASS |
| E2E smoke (T18) | `backend/e2e/account_smoke_test.go` (emulator mode) | PASS |
| Flutter | `flutter test` (all 516 tests) and `flutter analyze` | PASS, no issues |
| Existing, re-run | all earlier identity unit and apiserver lifecycle integration tests, graph, posts, timeline | PASS |

Only `internal/apiserver`, `backend/e2e` and docs were touched. `graph/` and `posts/` test files were not edited and no
shared helper package was created. One existing helper was extended in place: `newLifecycleEnvWith` now delegates to
`newLifecycleEnvCfg(t, verifier, mutate)` (`account_lifecycle_integration_test.go:66-80`), so a test can raise limits.

### T11: collection coverage

- `TestLifecycleCollections_EveryCollectionHasARow` parses the non-test Go sources of `backend/internal` and
  `backend/pkg/platform` for string constants named `*Collection`/`*Subcollection` and `.Collection("...")` literals
  and fails, naming the constant and its position, when a collection has no row. Today it finds 10 names (users,
  handles, exports, private, notifications, quotas, idempotency, graph, follows, posts), all with rows.
- Each row maps to a registered deletion step or export section (checked against the real registry built by
  `registerLifecycleModules`), or to a Q10 allowlist entry. Rows for ADR-0003 collections with no code yet (likes,
  reposts, userLikes, media, reports, followRequests) are `pendingEraser`; the test fails the day the code names one
  of them without an Eraser. `admin` and `idempotency` are `notPersonal`.
- `TestLifecycleCollections_GuardCatchesGaps` proves the guard: an unrowed collection, an unregistered step, an
  unregistered section, a pending row that is now written, and a row without a citation or disposition each fail with
  the collection named.
- `TestLifecycleCollections_AllowlistIsCited`: every allowlist entry and row cites an ADR or runbook line; the
  allowlist is pinned to the 5 Q10 entries (a, b, c) so growth is a reviewed change.
- Emulator sweep `sweepResidue`: reads every root collection (an unlisted one fails by name), the deleted uid's
  `users/{uid}` subtree (any survivor is residue, unknown subcollections fail by name) and the subcollection groups,
  and flags any path, id or nested value that contains the uid, minus the allowlist.
  `TestSweepResidue_CatchesWhatItShouldAndOnlyThat` runs it on a private project against hand-made documents (the Q10
  entries pass; 8 kinds of leftover are each reported; an unknown collection and subcollection fail by name).
  `TestRequireInvariants_CatchesCorruption` does the same for the counter and mirror checks.

### T16: deletion chain on the emulators

All scenarios use the production RPCs to seed and the production `JobsHandler`, real posts and graph Erasers, the real
Firestore repo, the Auth emulator and the Storage emulator.

- **Crash at every side effect** (`TestAccountLifecycle_RichAccountCrashAtEverySideEffect`): a rich account (2 posts,
  a post by another user mentioning it, 2 followees, 2 followers, one user it blocks, one that blocks it, one it
  mutes, a handle, a quota doc, a READY export with its object) is deleted by a second `Lifecycle` over the same
  emulators whose repo, Auth, object store, publisher and Erasers panic after the n-th side effect (the handler turns
  the panic into a 500, as for a killed instance). A clean run records 33 side effects over 10 deliveries (Auth
  disable, each step call, each checkpoint save and continuation publish, the object delete, export docs, private
  docs, handle, quotas, Auth delete, `users/{uid}`). Each of the 33 is killed in turn on a fresh account: **33/33
  PASS**, exactly one death each, final state (every counterpart's counters and graph arrays by role) identical to the
  clean run, ADR-0011 Q1 order intact, nothing after the `users/{uid}` delete, export object deleted before its doc.
- **Concurrent deliveries** (`TestAccountLifecycle_RichAccountConcurrentDeliveries`): 3 racing deliveries of the same
  message, 2 rounds, through the production chain; same end state as a serial run. The older
  `TestAccountLifecycle_ConcurrentDeliveries` (4 racers, exact counters) still passes.
- **Sweep and invariants after every scenario**: 0 references outside the Q10 allowlist for the deleted uid; for the
  cohort, `followersCount`/`followingCount`/`postsCount` equal the edges and posts, `graph.following` mirrors the
  edges, `blocked[]`/`blockedBy[]` mirror each other, no dangling edge, post or `blockedBy` entry. Observed and
  allowlisted residue: the blocker's `blocked[]` still lists the deleted uid (Q10 b), the mention post's `mentionIds`
  (Q10 c), idempotency records (Q10 a).
- **Reference account** (`TestAccountLifecycle_ReferenceAccountBudgets`, P 300, O 100, I 100, E 1) measured from the
  same `account_job` and request log lines production emits:

| RPC / job | Measured | Budget | Verdict |
|---|---|---|---|
| DeleteAccount (sync) | 1 R, 1 W | <= 2 R, 1 W | PASS |
| `account-delete` job (1 delivery, past the gate) | 509 R, 300 W, 505 D | plan AC <= 509 R + job state, <= 300 W + checkpoints, <= 505 D; ADR formula 510 + D R | PASS (equal to the plan numbers; the 509 R includes the 1 job-state read) |
| RequestAccountExport | 2 W (existing wire test: <= 3 R incl. interceptor) | 2 W | PASS |
| `account-export` job | 703 R, 2 W, 0 D, 51,771 bytes, 4 sections | 703 R, 2 W (lease claim + status, L-4) | PASS (equal) |
| GetAccountExport | 1 R, 0 W | <= 2 R cold, 0 W | PASS |

### T17: export privacy and access

- **Golden** (`TestAccountLifecycle_ExportContentsGolden`, `testdata/account_export_golden.json`): the whole export of an
  account with a followee, a follower, a blocked user, a muted user and a blocker, plus an unrelated user who blocks
  and mutes others, with ASCII, emoji, CJK, accented and RTL posts and a mention. Uids, handles, emails, post ids and
  times are normalized. Regenerate with `go test -tags=integration ./internal/apiserver -run ExportContentsGolden
  -update-golden`.
- **Privacy greps on the raw bytes**: no blocker uid, handle or email (ADR-0008 D12), no unrelated user's uid, handle
  or email, no email of a followed, blocked or muted user, no `blockedBy`, `status`, `snapshotVersion`,
  `deletionJob`, `handleLower`, `passwordHash` or `passwordSalt`. The subject's own blocked and muted users appear (by
  design: their own data).
- **IDOR, byte-identical NOT_FOUND, expiry, replay budgets, degraded mode**: already covered by
  `TestAccountLifecycle_ExportWireContract` and `..._DegradedAndFlagOff`; re-run green.
- **Quota rollover** (`..._ExportQuotaRollover`): a second export the same IST day is `RESOURCE_EXHAUSTED` with
  `retry_after` in (0, 24 h]; with `quotas/{uid}.day` set to yesterday the next export is accepted and the counter
  resets to 1; the one after is rejected again. The server reads the real clock, so a stale day stands in for
  midnight; the exact IST instant is `quota.TestTodayAt_ISTBoundary`.
- **Export while DELETING** (`..._ExportWhileDeleting`): a PENDING export whose owner starts deleting is acked and
  FAILED with no object; the DELETING caller gets `ACCOUNT_RESTRICTED` from both `RequestAccountExport` and
  `GetAccountExport`; the deletion then removes the FAILED doc and the sweep is clean.
- **Flag off** (`..._FlagOffRPCs`): all three RPCs answer `FAILED_PRECONDITION` / `FEATURE_DISABLED` with 0 writes; the
  account stays ACTIVE.
- `account_ops_daily` at 21 calls: `TestAccountOps_21stCallIsRateLimitedEvenOverTheReadBudget` (guard_test.go), unchanged.

### T18: E2E smoke, Flutter, gates

- `TestE2E_AccountLifecycleSmoke` (emulator mode): profile, mutual follow, post, export request, READY, object content,
  `DeleteAccount`, jobs to completion, then residue (post NOT_FOUND, the other account's counters back to 0, no
  Firestore docs keyed by the uid, no object, the token no longer works). About 14 RPCs, in the plan's budget for
  the smoke (~30 R, ~15 W, ~15 D).
- Every new screen has widget tests: `test/features/account/presentation/delete_account_screen_test.dart` and
  `data_export_screen_test.dart`, plus cubit and repository tests.

## Coverage and gates

| Gate | Result |
|---|---|
| `make ci` (gofmt, vet, unit with `-shuffle=on`, buf lint, golangci-lint, flutter analyze and test) | PASS, exit 0; `pkg/platform` coverage 88.0% (gate 70%) |
| Emulator suite, all packages with `-tags=integration` and `-coverpkg=./internal/...` (the `make test-int` command) | PASS; combined `internal/` coverage **92.8%** (gate 70%) |
| `golangci-lint run --build-tags=integration` on `internal/apiserver` and `e2e` | 0 issues |
| Lowest-covered lifecycle functions | `Lifecycle.publish` 75%, `decodeExport`, `SaveJobState`, `SetExportStatus`, `DeleteQuotas` 75% (error branches) |

`-race` was **not** run: `CGO_ENABLED=0` on this machine, so the Makefile drops the flag. CI runs it where CGO is on;
the new tests use no shared mutable state beyond mutex-guarded helpers, but that is unproven here.

## Limits of these tests (read before relying on PASS)

- **Auth in the crash chain is REST, not the Admin SDK.** `TestAuthAdminConfinement` (ADR-0011 C2) forbids building the
  SDK client outside `apiserver.go`, and identity's not-found classifier is unexported. The fault-injection chain
  therefore talks to the Auth emulator's REST API and treats an already-deleted user as success itself. The real SDK's
  not-found handling is still covered by `TestAccountLifecycle_AuthUserAlreadyGone`.
- **One step call per delivery in the crash matrix** (work budget and start gate set to 1 ns through `LifecycleDeps`),
  so every boundary is a crash point. Packing several steps into one 20 s slice is covered by the reference-account run
  (whole job in one delivery) and the identity unit tests, not by the matrix.
- **Signed download URLs** cannot be minted on the emulators; the READY object is read from the bucket. The signer
  is covered by unit tests only, and a real signed download is a T23 dev-drill item.
- **Graph and posts invariants are restated**, not reused: their checkers are unexported in `_test.go` files of
  packages this ticket may not touch. If either module's invariants change, `requireInvariants` needs the same change.
- **`notifications`** is named in code (`identity.UnreadNotificationCount`) but nothing writes it yet. Its row is
  `pendingEraser`/read-only; the P6 slice must register an Eraser, and the sweep and guard will fail until it does.
- Time-based paths (IST midnight, 7-day expiry, 15-minute URL TTL) use stale stored days or the unit tests' fake clock,
  not a faked server clock.

## Defects

None open against production code. Notes for the owning agents (test hygiene, not behaviour):

- `backend/internal/apiserver/account_lifecycle_integration_test.go:89` loads `cfg` with `config.Load()` without the
  per-test `JobsTopic` and `ExportBucket`, so `e.cfg.JobsTopic`/`e.cfg.ExportBucket` do not name the topic and bucket
  the chain actually uses. `account_lifecycle_audit_integration_test.go:197,238` and
  `account_lifecycle_integration_test.go:472` copy them into second chains. Harmless today (none of those chains
  publishes or writes an object) but a trap for the next test; the new code uses `e.bucket.BucketName()`. Owner:
  backend-developer, low priority.

## Orphan processes (not killed)

`firebase emulators:exec` left its Pub/Sub emulator running after my first run:

| PID | Port | Command | Origin |
|---|---|---|---|
| 532 | 127.0.0.1:8085 | `cloud-pubsub-emulator-0.8.36-all.jar --host=127.0.0.1 --port=8085` | orphaned by this session (parent gone) |
| 36440 | 127.0.0.1:28085 (+ 52150) | same jar, `--port=28085` | not started by this session; another session's emulator run |

All later runs reused PID 532 by starting `emulators:exec --only firestore,auth,storage` with
`PUBSUB_EMULATOR_HOST=127.0.0.1:8085`, because the default Pub/Sub port was taken. Stop 532 with
`taskkill /PID 532 /F` when no run needs it.

## Repro

```
# unit + guards (no emulator)
cd backend && GOWORK=off go test -count=1 -shuffle=on ./internal/apiserver/ -run TestLifecycleCollections
# everything, as make test-int does (needs ports free, or reuse a running Pub/Sub emulator)
GOWORK=off npx -y firebase-tools@latest emulators:exec --project demo-dzeroth-local \
  --only firestore,auth,pubsub,storage \
  'cd backend && go test -tags=integration -coverprofile=cover-internal.out -coverpkg=./internal/... ./...'
# the crash matrix alone
... -run TestAccountLifecycle_RichAccountCrashAtEverySideEffect -v ./internal/apiserver/
# the budgets (grep BUDGET)
... -run TestAccountLifecycle_ReferenceAccountBudgets -v ./internal/apiserver/
```
