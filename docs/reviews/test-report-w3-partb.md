# Test report: UI wave W3 Part B (private accounts and follow requests)

Each ticket owns its own section below; keep an edit to your own section. W3-35a owns "W3-35a"; W3-35b owns the section
that follows. (The plan names `docs/reviews/test-report-w3b.md` for W3-35b; the task brief chose this Part B file, so the
plan's file name is stale.)

---

## W3-35b: request lifecycle, races, invariants I-R and I-X, the `privacy_public` job, flag matrix, eraser and export

Tester: tester agent, 2026-10-28. Branch `test/w3-35b-request-lifecycle` on `main@15975e53` (W3-26a, W3-27, W3-28a, W3-28b,
W3-28c, W3-31 and W3-32 merged; W3-26b is in review and not needed here). Design: ADR-0025 D6 to D9, D11, D12 and the W3-28a
and W3-28b implementation notes; runbooks `docs/runbooks/graph.md` sections 7 to 9 and `private-accounts.md`. Test code only:
no production file was edited, and no production seam was added (the one test-only window into the job is
`backend/internal/graph/export_w335b_test.go`, a `_test.go` file).

**VERDICT: PASS** (details and one by-design observation, O-1, below; no production defect found).

### 1. What was run

| Suite | Command | Result |
|---|---|---|
| New and changed Go integration tests, graph and apiserver | `firebase --config <temp 33xxx config> emulators:exec --project demo-dzeroth-local --only firestore,auth,pubsub,storage 'cd backend && go test -tags=integration -count=1 -run W335b ...'` behind `scripts/with-private-tmp.sh` | green |
| The three touched packages, whole, with combined coverage (the `make test-int` command line, restricted to the packages) | `go test -tags=integration -count=1 -coverprofile=cover-w335b.out -coverpkg=./internal/... ./internal/graph/ ./internal/apiserver/ ./internal/identity/` | see section 5 |
| `gofmt -l`, `go vet`, `go vet -tags=integration`, `golangci-lint run` (also with `--build-tags=integration`) on `./internal/graph/... ./internal/apiserver/...` | as written | clean |

Environment notes: `-race` was **not** run (CGO is off on this Windows machine; CI on Linux runs it). All four emulators ran on
a private 33xxx port block through an untracked `--config` copy, deleted before the commit. Pub/Sub's emulator JVM stays alive
after `emulators:exec` on Windows; the leftover PIDs are listed in the hand-back, none was killed.

### 2. Coverage map: ticket bullet to test

Tests marked **new** are in this PR; the others already existed on `main` and are cited, not duplicated.

| Ticket bullet | Test | Status |
|---|---|---|
| D7 Request (cold 4 / warm 3 reads, 3 writes), replay, 500 cap | `TestFollowRequest_Integration_CreateReplayWithdraw`, `_RequestedCapIs500`, `_DriftedRequestDocIsAReplay` | existing |
| D7 Withdraw (1 write, 1 delete), withdraw after the target went public | `TestFollowRequest_Integration_CreateReplayWithdraw`, `_WithdrawAfterTargetWentPublic` | existing |
| D7 Accept, Decline, replay, requester not ACTIVE, requester at 5,000, drift | `TestRespond_Integration_AcceptDeclineReplay`, `_RequesterInactive`, `_RequesterAtCap`, `_DriftIsDropped` | existing |
| D7 Block in either direction | `TestFollowRequest_Integration_BlockClearsRequestsBothWays`, `_BlockRulesComeFirst` | existing |
| Race: follow vs protect | `TestFollow_Integration_ProtectRacingWithFollowIsSerialized` (`follow_race_integration_test.go`, package `graph`: the transaction hook) | existing |
| Race: accept vs withdraw, accept vs block (one instance) | `TestRespond_Integration_Races` | existing |
| Race: **Respond on two instances**: accept+accept, accept+decline, decline+decline, accept+withdraw, decline+withdraw, accept+block, 3 rounds each | `TestW335b_Respond_TwoInstances` (`graph/request_races_integration_test.go`) | **new** |
| Race: the job vs a re-protect, mid-run | `TestPrivacyPublic_Integration_ReprotectedMidRun` (graph: the re-protect lands between pages). The chain test says it cannot interleave a toggle with one delivery (`w328b_privacy_public_integration_test.go` header), so it is not repeated through `apiserver.Build` | existing |
| Race: **the job vs withdraw, Block and a manual accept**, all running at once on one target | `TestW335b_PrivacyPublic_AgainstWithdrawBlockAndManualAccept` | **new** |
| Race: **job redelivery mid-run**: a delivery that stops at the 50-page cap and its redelivery; a crash before and a crash after a page's commit; **two concurrent runs** of 250 pending on two instances | `TestW335b_PrivacyPublic_DeliveryStopsAtThePageCap`, `_CrashBetweenAndAfterPages`, `_ConcurrentRuns` | **new** |
| Job counts, budget, redelivery, at the cap, inactive and gone requesters | `TestPrivacyPublic_Integration_Counts` (0, 1, 100, 101, 250), `_ReprotectedBeforeRun`, `_CapInactiveAndGone`; chain: `TestW328b_PrivacyPublicThroughTheChain` | existing |
| Job: **at-cap requesters re-counted on every rerun** | `TestW335b_PrivacyPublic_AtCapRequestersAreRecountedEveryRun`, `_AtCapRequestersNeverDropOut` (O-1) | **new** |
| Invariants: I-R and I-X in the checker, each with negative self-tests | `invariants_integration_test.go`: `graphInvariantViolations` now loads `followRequests` and `graph.requested`; `TestGraphInvariantChecker_DetectsEveryViolation` has 11 new rows (2 clean, 9 violations) | **extended** |
| Flag matrix, D12, in the ten rollout states | `TestW335b_PrivateAccountsFlagMatrix` (`apiserver/w335b_private_accounts_flag_matrix_integration_test.go`), reusing `w320ModeCases` | **new** |
| Flag matrix, four modes with real requests | `TestW328a_FlagModesNeverStrandAProtectedAccount`, `TestPrivateAccountsContract_FlagOff`, `_AllowlistCohort` | existing |
| Limits: the 4 per day toggle quota, the set cap, the equal-value no-op | `TestPrivacyToggle_Chain`, `TestPrivacyToggle_Cap` (existing); **the corners**: `TestW335b_PrivacyToggleLimits` | existing + **new** |
| Eraser: a requester and a target with requests both ways, through the job chain | `TestW335b_FollowRequestsThroughAccountLifecycle` | **new** |
| Eraser: page boundaries, ghost in a full page, gone between calls, redelivery, concurrent loops | `TestW335b_RequestEraser_PageBoundaries`, `_RequesterGoneBetweenCalls`, `_RedeliveryKeepsOtherRequests`, `_ConcurrentLoops` | **new** |
| Eraser and export basics | `TestRequestEraser_Integration`, `TestExportRequests_Integration` | existing |
| Export golden | `testdata/w335b_follow_requests_export_golden.json` (a section-level golden; the shared `account_export_golden.json` is untouched), plus the export page boundary `TestW335b_ExportRequests_PageBoundaries` | **new** |
| The wiring lists; T11 green | `lifecycle_wiring_test.go` (the step and section lists, `TestFollowRequestsSection`), `lifecycle_collections_guard_test.go` (`followRequests` row; dropping the step or the section is detected), and the runtime residue sweep `requireNoResidue` called for each deleted account in the new lifecycle test | existing + used |
| The identity step removes the protected-set entry | `TestRemoveFromProtectedSet_Integration` (identity, existing) and, through the whole job chain, `TestW335b_FollowRequestsThroughAccountLifecycle` | existing + **new** |

### 3. What the new tests prove

**I-R and I-X in the sweep.** `assertGraphInvariants` runs at the end of every graph scenario; it now also reads `followRequests`
and `graph.requested` and checks I-R in both directions, I-X on the documents and on the arrays (`b` in both `following`
and `requested`), S1 (a request id is `follower_followee`, no self-request) and S2 (no duplicate in `requested`, the 500
cap, `pad-` entries skipped). Nine negative rows prove each rule can fail. The widened sweep added no red to the 89 s graph
integration run: no existing scenario ended in a state the new rules forbid.

**Respond on two instances** (18 rounds). Neither call ever failed; the loser of every pair was a replay. End states: one
edge or none, `followersCount` and `followingCount` read straight from Firestore agree with the edge, at most one
`FollowRequestAccepted` across both instances (exactly one for accept+accept), accept+block never leaves an edge. The counters
are read from Firestore on purpose: the first draft of this test read `followingCount` through the other instance's profile
cache and failed twice; that is the cache TTL, not a defect.

**The job under pressure.** With a page of 1 (test-only window) 60 pending requests reach the 50-page cap: the run returns
`ErrPrivacyPublicMore` (a nack), `followersCount` is exactly 50 and 50 requests are left; the redelivery ends `done` with
`followersCount` exactly 60 and exactly one event per requester; a third delivery is a no-op. A crash before page 3 and a crash
after page 3 committed both converge on `followersCount` 5 and no double edge. The after-commit crash loses exactly that page's
one notification (4 events, not 5), which is the ADR-0025 D8 residual, now pinned by a test. Two simultaneous runs of 250
pending on two instances both end `done`, 250 edges, `followersCount` exactly 250, one event per requester. Withdrawers, a
Block per requester and a manual accept racing one job run: no request left, `followersCount` equals the edges, no blocked
requester follows.

**Flag matrix.** In all ten states, for both sides of the cohort (a fresh user pair and a fresh protected account per state):
`enabled_features` lists `private_accounts` exactly for the callers it is on for; `UpdateProfile(is_private=true)` is refused
as FEATURE_DISABLED `feature=private_accounts` at **exactly 0 reads, 0 writes, 0 deletes** (the account-status read warmed first
with GetMe); `ListFollowRequests` and `RespondToFollowRequest` refuse a public caller **only in mode `off`**, also at 0 / 0 / 0;
an empty allowlist and percent 0 pass. Never gated and checked in every state: Follow of a protected account answers
REQUESTED, the withdraw works, `is_private=false` works (including unprotecting a protected account with the flag off), the
protected owner lists and answers requests, and a stranger gets `author_protected` and no rows from the protected author's
timeline tab. The job, eraser and export are never gated (they read no flag; the lifecycle and job tests above run them
without one).

**Limits.** The no-op is decided before the quota: `is_private` equal to the stored value succeeds with 0 writes at 4 of 4
(public and protected); the other value at 4 of 4 is QUOTA_EXCEEDED `quota=privacy_toggles` with 0 writes and the state
unchanged; an equal-false on a never-protected account is 1 read, 0 writes and does not touch the quota; with the protected
set at its cap an unprotect and an equal-true pass, and a new protect is LIMIT_REACHED with nothing written.

**Eraser.**

| Case | Calls | Reads | Writes | Deletes |
|---|---|---|---|---|
| exactly 500 outgoing | 3 | 502 | 0 | 500 |
| exactly 250 incoming (500 operations in one batch) | 3 | 252 | 250 | 250 |
| 250 incoming, one requester without a graph doc inside the page | 3 | 502 | 249 | 250 |
| 250 incoming, every requester gone | 3 | 502 | 0 | 250 |
| requester's graph doc deleted between two calls | (1 outgoing, then incoming) | 5 | 1 | 3 |
| redelivery after the step finished, from the start and from either phase | - | 2 | 0 | 0 |

A full page costs one extra empty query, as predicted. The purge never recreates a graph doc (`Update`, never `Set`), keeps a
requester's other requests and `requested` entries, deletes both directions of a mutual pair, and two loops on one account
at the same time (300 incoming of which 6 ghosts, 120 outgoing) both finish with a clean end state. "Graph doc gone mid-page"
cannot be interleaved inside one batch without a production seam, so it is approximated by a ghost inside a full 250 page and
by a graph doc deleted between two calls; this is a documented approximation. Through the real job chain: the export of an
account with requests both ways matches the section golden and is newest first; another account's export names no request it
is not a party to; deleting a requester, then a protected target with requests both ways, then the second protected account
leaves no request naming them, no `requested` entry of a survivor naming them, the queue the target had joined clean, the
protected-set entries gone, and the T11 residue sweep empty. Export page boundary: exactly 500 and 501 requests each way, every
row once, newest first, none lost at the page edge (reads 2,002 and 2,004: the request docs, the empty re-query at exactly
500, and one lookup per counterpart that has no profile).

### 4. Budgets measured (all within the documented ceilings)

| RPC or step | Measured | Ceiling |
|---|---|---|
| `UpdateProfile(is_private=true)` refused by the flag, warm | 0 / 0 / 0 | 0 reads, 0 writes (D12) |
| `ListFollowRequests`, `RespondToFollowRequest` refused by the flag, warm | 0 / 0 / 0 | 0 (D12) |
| `UpdateProfile` equal value (public, quota 0) | 1 read, 0 writes | no writes (D8) |
| `UpdateProfile` equal value at 4 of 4 (public or protected) | 1 read, 0 writes | no writes (D8) |
| `UpdateProfile` different value at 4 of 4 (QUOTA_EXCEEDED) | 3 reads, 0 writes | no writes (D8) |
| `privacy_public`, rerun with 3 requesters at the cap | 7 reads (1 + 3 x 2), 0 writes, 0 deletes, identical on every rerun | D8 per request 2 reads |
| `privacy_public` stopped at the page cap (page 1, 51 stuck requests) | 150 reads, 0 writes per delivery | see O-1 |

### 5. Coverage

Measured the `make test-int` way (`-tags=integration -coverprofile -coverpkg=./internal/...`), restricted to the three packages
this ticket touches (their unit tests are not in this run, so these are integration-only figures and a lower bound). Per-package
statement coverage computed from the merged profile:

| Package | Statement coverage |
|---|---|
| `internal/graph` | 92.1% |
| `internal/apiserver` | 95.3% |
| `internal/identity` | 93.1% |

The three packages passed whole on the emulators (graph 151 s, apiserver 127 s, identity 48 s, run in parallel as `./...` does).
The ticket's gate (`internal/` combined at least 70%) is the full `make test-int` figure; this ticket adds tests only, so it can
only raise it. The full-module figure was not re-measured here.

### 6. Defects and observations

No production defect. Nothing was marked as a known failure with `t.Skip`.

- **O-1 (informational, Low at Stage 0): a request whose requester is at the 5,000 following cap never drops out of the
  `privacy_public` query.** The job re-reads it on every delivery (7 reads for 3 stuck requests, no writes, stable) and
  finishes `done` at the production page of 100. Only when the first 5,000 requests of a target are all stuck does a run end
  `ErrPrivacyPublicMore` (a nack) on every redelivery until the owner declines them, because the 50-page cap is reached
  without progress. `TestW335b_PrivacyPublic_AtCapRequestersNeverDropOut` models it at a page of 1 (51 stuck requests): two
  deliveries, both nack at 150 reads and 0 writes. It needs more than 5,000 stuck requests and each stuck requester follows
  5,000 accounts, so it is not reachable at Stage 0; it is recorded so nobody is surprised by a nack storm that only Decline
  ends. Recommendation for the owner, not a change request: if it is ever reached, ack with a log line when a whole delivery
  accepted nothing.
- **O-2 (by design, not a defect): contention answers a retryable error.** In a first draft of the job-chaos test, ten Blocks
  fired by one account in the same millisecond while the job ran made 5 of the 10 answer "temporarily busy, please retry"
  (the Block transactions all write the blocker's graph doc). The test now sends the Blocks one after another; the shipped
  behaviour (a retryable error, the client retries) is the documented ABORTED mapping.
- **O-3 (by design, from ADR-0025 D7, not observed in the 18 rounds): withdraw is two blind batches.** A withdraw that races an
  accept can run its edge batch before the edge exists and its request batch after the request is gone, so it answers NONE
  while the accept's edge stands. The ADR accepts this ("a second failure is NONE"); the invariants hold either way (the sweep
  passed in every round).
- **O-4 (documented, now pinned by a test): a process crash after a job page commits and before its events are emitted loses
  that page's accept notifications** (ADR-0025 D8, the W3-28b note). The edges and counters are exact.

### 7. Reuse report

- Reused: `newWired`, `newInstance`, `acceptRecorder`, `pendingTo`, `runJob`, `seedRequest`, `runRequestPurge`, `measured`,
  `runConcurrently` (graph); `newW320Chain`, `w320ModeCases`, `w320Warm`, `w320AssertNothing`, `w320Disabled`, `w328Request`,
  `w328List`, `w328Respond`, `newLifecycleEnvCfg`, `exportOf`, `normalizeExport`, `requireNoResidue`, `ptoggleStored` (apiserver).
- Extended: `graphInvariantViolations` and `loadGraphState` (I-R, I-X, S1, S2 for requests); `w320DrawGates` gained
  `w320DrawGatesFor(names)` (the old function calls it, behaviour unchanged).
- Created: `graph/export_w335b_test.go` (a test-only setter for the job's page size, so the 50-page cap is reachable with 60
  requests instead of 5,001; no production file changed), `request_races_integration_test.go`,
  `purge_requests_edges_integration_test.go`, and the four `w335b_*` apiserver files. Nothing existing fit these cases.
- Catalog: no shared production helper was added, so `docs/code-map.md` is unchanged.

### 8. Reproduce

```sh
export GOWORK=off
# an untracked copy of firebase.graph-loadtest.json with all six ports in 33xxx, then:
bash scripts/with-private-tmp.sh firebase --config <copy>.json emulators:exec --project demo-dzeroth-local \
  --only firestore,auth,pubsub,storage 'cd backend && go test -tags=integration -count=1 -run W335b ./internal/graph/ ./internal/apiserver/'
# rewrite the section golden:  ... -run W335b_FollowRequests ./internal/apiserver/ -update-golden
```

VERDICT: PASS
