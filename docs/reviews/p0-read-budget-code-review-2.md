# Code review 2: P0 / T3 read budget (`feat/p0-read-budget` vs `origin/main`)

Scope: `git diff origin/main...HEAD` at `b78d6a9` (35 files; focus on `499dd57`, `ba4dbd5`, `b78d6a9` and the
earlier P0 commits). Checked against ADR-0010 D5 as amended (A1-A7), the Handoff list for T3, the first review
(`p0-read-budget-code-review.md`), CLAUDE.md rules, and reuse-first.

What I ran (on an exported copy, the worktree was not modified except for this file):
- `go vet ./...` and `go vet -tags=integration ./internal/graph ./e2e`: clean.
- `go test -count=1 -shuffle=on ./pkg/platform/... ./internal/apiserver/... ./internal/identity/...`: pass.
- Emulator run (`firebase emulators:exec --project demo-dzeroth-local --only firestore,auth`):
  `./internal/identity` and `./e2e` pass. `./internal/graph` passes except
  `TestFollow_Integration_ConcurrentDuplicateFollows_ExactlyOneEdge`, which failed once in the full-package run
  ("temporarily busy") and passed 3 times in isolation. That test and its code are not part of this diff.
- Mutation checks (details below). `-race` was not run because CGO is disabled on this host.

## Blocker

None.

## Major

**MJ1. No test covers releasing an earlier key's in-flight slot when a later key rejects the call. A regression
would lock users out for the rest of the instance's lifetime.**
`backend/pkg/platform/ratelimit/interceptor.go:208-215`.
When the uid key is reserved and the IP key then rejects the call (CheckHandleAvailability with a spent IP
budget, or a marked uid), the loop releases the uid slot with `Release(key, 0)`. The code is correct today.
But if the release is deleted (mutation `taken.cap.Release(...)` -> no-op), every unit, apiserver and authn test
still passes.
The damage would be serious. `inflight` is never reset, not even at IST midnight (`lock` resets only `count`).
Each leaked slot therefore stays until the instance dies. After 7 leaks on a fresh day, or 1 leak once spent is
over 1,462, every call from that uid gets `read_budget_inflight`. CGNAT users on the sign-up form are exactly the
callers who hit an exhausted IP key again and again.
Fix: add an interceptor test. Spend the IP budget of `procCheck`, call it N times as one uid (all rejected with
`key=ip`), then assert `uidCap.Inflight(uid) == 0` and that a non-exempt call by the same uid at
`spent = 1,999` is still admitted. Add the same case with a transient IP rejection.

**MJ2. The A2 gate's wiring and position in `Build` are untested. Unwiring the primary H1 fix goes unnoticed.**
`backend/internal/apiserver/apiserver.go:153`.
I deleted `authn.VerifiedIdentityInterceptor(profileExempt),` from `Build`. All unit tests still pass, and so do
the e2e tests on the emulator:
- `TestE2E_CreateProfile_UnverifiedPasswordEmail_Rejected` still gets EMAIL_NOT_VERIFIED from identity's
  defence-in-depth check.
- Its GetMe step only asserts `FailedPrecondition`, which `AccountStatusInterceptor` also returns, after 1 read.

`gate_test.go` proves that the interceptor works in isolation. Nothing proves that production runs it, or that
it runs before the rate limiter (the "no limiter key" claim) and before account status (the "0 reads" claim).
Fix, either one:
- (a) An e2e test with `newPasswordIDToken` (unverified), using `PerUserPerMinute = 1`:
  - CheckHandleAvailability returns FAILED_PRECONDITION + `EMAIL_NOT_VERIFIED`. Only the gate produces that on
    this RPC.
  - GetMe called 3 times returns `PROFILE_REQUIRED` every time and never RESOURCE_EXHAUSTED, so the gate runs
    before the limiter. Assert `fs_reads = 0` on the request log line.
- (b) Extract the interceptor slice into a helper, like `rateLimitConfig`, and assert the order in
  `apiserver` tests. (a) is stronger.

## Minor

**m1. One test hangs for 10 min instead of failing when the A1 hold regresses.**
`backend/pkg/platform/ratelimit/readbudget_test.go` `TestReadBudget_InFlightGuardRejectsWithShortRetryAndReleases`.
With the hold removed, the second call is admitted, `rateLimitDetail` calls `t.Fatal`, and the first handler
stays blocked on `<-release`. `httptest.Server.Close` then waits on it and the package hits the 600 s timeout.
I confirmed this with a mutation. CI would report a timeout panic, not the real assertion.
Fix: right after creating `release`, register `t.Cleanup` with a `sync.Once` that closes it (before the server's
cleanup runs), or close it in a `defer`.

**m2. A stale A3 mark keeps a user who has a profile on the IP key for up to 10 min, and makes
`read_budget_over_max` fire falsely.**
`interceptor.go:188-199` and `:279-282`.
A uid marked on instance A that creates its profile on instance B keeps reserving the IP key on A. Its normal
calls read up to 269 docs against the IP hold M = 2. Three things go wrong:
- the IP counter overshoots the 501 bound (the ADR says "every IP-keyed call reads at most 1 doc", which is
  false in this case);
- other users behind the same CGNAT address can be rejected;
- WARN `read_budget_over_max` fires for a legitimate user, and the runbook tells the operator to raise M, which
  is the wrong response.
Firestore spend itself stays bounded by the uid key.
Fix, which needs a one-line architect confirmation because A3 says only CreateProfile unmarks: in
`settleReadBudget`, when a marked-uid call passed account status (`succeeded` and `!ProfileRequired`),
`profileLess.Delete(uid)`. Add a test.

**m3. Review 1 m6 is not fixed.** `backend/internal/identity/negative_handle_cache_test.go:50-62`. If I remove
`c.handleFree.Delete(p.HandleLower)` from `SetProfile`, the identity package still passes. The positive
`handles` map answers first, so the test never looks at the negative entry. Assert
`!svc.cache.GetHandleFree("claimme")` after CreateProfile, and add the ChangeHandle case.

**m4. Stale comments that Handoff item 7 said to fix.**
- `backend/pkg/platform/config/config.go:106-114`: still "6,804 reads" and "~1,503 over 3 instances", framed per
  day. The ADR now says 2,308 and 501 per instance lifetime, with the steady, rollout and idle-cycling
  multipliers.
- `config.go:31-33`: `IPReadBudgetMaxCallReads` says CreateProfile "reads at most 1 doc". CreateProfile is
  IP charge-only (never held) and reads several docs.
- `daily_cap.go:19-22`: "effective ceiling is roughly limit x max-instances".
- `daily_cap_test.go:104`: "overshoot allowed by one call".

**m5. The comment-only proto follow-up that the Handoff says "rides with the T3 PR" is missing.**
- `proto/dzeroth/common/v1/common.proto:61-63` does not list `read_budget_inflight` (1 s, retry once) or
  `account_ops_daily`.
- `identity.proto` does not document `EMAIL_NOT_VERIFIED` on CheckHandleAvailability, the IP enforce and
  charge-only split, or that the account operations are charge-only.
The frontend implements against these comments. Architect owns this; `buf breaking` stays clean because the
change is comments only.

**m6. `docs/runbooks/abuse-spike.md:65-85` departs from the ADR Handoff.**
- It gives a Log Analytics SQL query. The ADR says Log Analytics is not enabled (security L2), so use Logs
  Explorer filters.
- It says "the budget is per instance, so worst case is x3". The bound is per instance lifetime: up to 6
  lifetimes on a rollout day, and up to 270 when an attacker idle-cycles instances.
- It lacks the R2 churn check (one `uid_hash` rejected on 3 or more `labels.instanceId` in an IST day), the lever
  order, and the note that `DEGRADED_MODE=readonly` does not reduce reads.
DoD: a runbook entry is required for every new failure mode.

**m7. The "shipped defaults" regression test does not run the shipped config.**
`backend/internal/graph/readbudget_regression_integration_test.go:25-35` (and `readbudget_integration_test.go:24`)
build `NewDailyCap(2000)` without `WithMaxCallReads`. The A1 hold is therefore off, and so are the account-ops
caps. That test can never catch the hold rejecting a legitimate call.
Fix: export the helper (ADR L6 already calls for "the same exported helper Build uses", e.g.
`apiserver.RateLimitConfig`) and use it here, or at least arm the holds with the `config` constants.

**m8. The client half of A1/A2 is not implemented. It is tracked, but it must land before the gate and the hold
reach users.**
- `app/` has no silent retry on `read_budget_inflight`. A heavy user past 1,462 spent would see errors from
  parallel fetches.
- `onboarding_bloc.dart:197-204` renders CheckHandleAvailability's `EMAIL_NOT_VERIFIED` as "unavailable" plus
  the server message, instead of the verify-email banner.
Both are frontend Handoff items (T17). Record them as release gates in the plan.

**m9. Code-map is incomplete (reuse-first step 5).**
- The `cache.LRU` line (`docs/code-map.md:53`) does not list `GetOrSet`, although review 1 m2 asked for it
  explicitly.
- The ratelimit line still says "apiserver wires two" daily caps. There are now four names.
- The full stop between "never logs an IP directly" and "ADR-0010 D5" (review 1 nit) is still missing.

## Nits
- `TestDailyCap_FirstAccessRace` is weak. With `lock` mutated back to Get-miss-then-Set, it failed 1 run in
  1,000. Add a start barrier (`<-start`) so the 200 goroutines collide. The structure (`GetOrSet`) is what
  actually guarantees the property.
- `config_test.go` `clearEnv` does not clear `ACCOUNT_OPS_CALLS_PER_DAY`, so the defaults test depends on the
  host environment.
- `TestA1_InterceptorConcurrencyBound` polls with `time.Sleep(time.Millisecond)`. It is bounded, but the
  testing-strategy skill asks for an `eventually` helper.
- `rejectReadBudget` calls `Inflight()`, which takes the lock again. `Reserve` could return the in-flight count
  alongside `spent`.
- `daily_cap_test.go` still uses the literals 268 and 269 instead of `config.ReadBudgetMaxCallReads`.
- The A2 predicate is a denylist (`password && !verified`). Sign-in providers are configured in the console,
  not in Terraform, so if anonymous or another free-to-mint provider is ever enabled, the gate lets it through.
  An allowlist (`google.com`, `apple.com`, verified `password`) would fail closed. That needs the anonymous-token
  e2e tests to switch helpers. Security-auditor's call.

## Review 1 items: verified
| Item | Status | Evidence |
|---|---|---|
| M1 concurrency overshoot | **Fixed** | `daily_cap.go:108` implements A1 exactly (`count >= cap`, or `inflight > 0 && count + (inflight+1)*M > cap`). Mutations to no hold, the review's weaker `count + M > cap`, and `inflight*M` are each caught (`SingleFlightNearCap`, `InvariantAtAnyConcurrency`, `ConcurrentReserveAtLimitMinusOne`, `A1_InterceptorConcurrencyBound`). |
| M2 right-to-delete blocked | **Fixed** | A6: `ReadBudgetChargeOnly` = DeleteAccount, RequestAccountExport, GetAccountExport, bounded by `account_ops_daily`. The guard asserts the exact set and the DailyCaps entry; `TestAccountOps_21stCall...` passes over the budget. A marked uid's IP key inherits charge-only too. |
| m1 charge lost on panic | **Fixed** | Settles in a `defer`. The panic test catches the leaked-slot mutation. |
| m2 Get-miss-then-Set | **Fixed in code** | `cache.LRU.GetOrSet` is used by `DailyCap.lock` and `Limiter.Allow`. The test is weak and the code-map line is missing (see Nits, m9). |
| m3 zero or negative env | **Fixed** | `config.Load` rejects values `<= 0` for all four keys; tested. |
| m4 Terraform | **Fixed** | Dev and prod pin all four values. |
| m5 client midnight copy | Open (frontend, T17) | See m8. |
| m6 negative-cache test | **Not fixed** | See m3. |
| m7 which key tripped | **Fixed** | `read_budget_key` is log-only and asserted not to be client-visible. |

## ADR-0010 D5 conformance
- A1: matches, including the 1 s `read_budget_inflight`, WARN `read_budget_over_max`, and the constants 269 and 2.
- A2: the interceptor matches (0 reads, EMAIL_NOT_VERIFIED on exempt procedures, PROFILE_REQUIRED elsewhere,
  `gate=email_unverified`) and sits right after `IDTokenInterceptor`. The wiring is untested (MJ2). The T26
  precondition (no unverified password account owns a `users` doc) is still an open deploy step.
- A3: matches the ADR. Stale-mark gap in m2.
- A4, A5, A6: match, including `MaxHeaderBytes = 64 KiB` and the /64 key on both per-minute IP limiters.
- A7: fields match the table.

## Cost and rules
- 0 Firestore ops added. The negative handle cache and the gate remove reads. No new GCP resource, nothing for
  `cost-guard`. Memory: three LRUs of up to 100k keys each (uid budget, IP budget, `profileLess`), a few tens
  of MiB worst case, inside 512 MiB.
- Logging: new fields ride the existing request line; one WARN appears only on anomaly; no IP or raw uid is
  logged (asserted).
- Rules 5, 6, 10, 11: satisfied (rule 10 via A6; rule 11 via config and Terraform pins). No proto or wire
  changes.
- Reuse-first: `DailyCap`, `cache.LRU` and `quota` were extended, not duplicated. I found no existing equivalent
  of `IPBudgetKey`, `UntilNextDay` or `GetOrSet`. Code-map gaps in m9.

## Mutation results
| Mutation | Caught? |
|---|---|
| No A1 hold | yes (and one test hangs, m1) |
| Review's weaker hold (`count + M > cap`) | yes |
| `inflight*M` instead of `(inflight+1)*M` | yes |
| `Release` doesn't decrement `inflight` | yes |
| Rejection path doesn't release earlier keys | **no** (MJ1) |
| A3 mark never read / never cleared / IP charge removed | yes |
| Over-max WARN removed | yes |
| Gate removed from `Build` | **no**, unit and e2e (MJ2) |
| `SetProfile` doesn't clear `handleFree` | **no** (m3) |
| `DailyCap.lock` back to Get-then-Set | caught about 1 run in 1,000 |

VERDICT: CHANGES REQUESTED. Adding the tests for MJ1 and MJ2 is enough to clear the Majors; no production code
has to change. The Minors can follow in the same PR or be tracked.
