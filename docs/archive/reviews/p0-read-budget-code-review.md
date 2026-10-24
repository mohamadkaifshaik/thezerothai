# Code review: P0 / T3 read budget (`9fdb8bd..9c7a6ea`)

Scope: `git diff 9fdb8bd..9c7a6ea` (4 commits: DailyCap Reserve/Charge + read budget + IPv6 /64 key + IST-midnight
retry_after; identity negative handle cache; apiserver wiring + guard test; code-map/runbook). Checked against
ADR-0010 D5, `docs/plans/posts-and-timeline.md` T3, and CLAUDE.md rules.

Verification run on an exported copy of `9c7a6ea`: `go vet` clean (including `-tags=integration ./internal/graph`);
`go test -count=1 -shuffle=on` passes for `pkg/platform/{ratelimit,quota,config}`, `internal/{identity,apiserver}`.
`-race` could not run (CGO disabled on this host). Emulator integration tests (`readbudget_integration_test.go`
and the "existing budget assertions still pass" regression) were **not** run. I confirmed that the guard test
enumerates 10 procedures: GetRelationships, the 5 graph List*, CheckHandleAvailability, GetMe, GetProfile and
GetAccountExport.

## Blocker

None.

## Major

**M1. Concurrent calls can overshoot by much more than one call. The ADR-0010 D5 cost bound does not hold.**
`backend/pkg/platform/ratelimit/interceptor.go:149-153` (Reserve), `:164-172` (Charge),
`backend/pkg/platform/ratelimit/daily_cap.go` `Reserve`/`Charge`.
Reserve only checks `count < limit` and records nothing, so every call in flight when the key is near the cap
passes. D5 says the worst case is 2,000 - 1 + 269 = 2,268 per instance and 6,804 per account per day, but that
only holds if calls run one at a time. The real bound per instance is roughly `limit + sum over procedures of
(per-minute burst x worst-case reads)`. Burst equals the per-minute rate (`ratelimit.go:40`), and Cloud Run
concurrency is 80. A script that waits until spend is about 1,999 and then fans out can use every bucket in
parallel. Today's numbers: graph lists give 20 x ~52 reads and the 60/min default bucket adds more, so roughly
+1.3k. After P1 (timeline 6 x 268, user timeline 30 x ...) it could be several thousand per instance, times 3
instances. That also weakens D5's claim that about 7 sybil accounts would be needed to exhaust the free quota.
`TestReadBudget_OvershootBoundedByOneCall` only tests calls in sequence, so it does not cover this.
Fix, pick one:
- (a) Preferred, and it makes the ADR sentence true. Keep an `inflight` count on `dailyCounter`. `Reserve`
  rejects when `count >= limit`. It also rejects when `inflight > 0 && count + maxCallReads > limit`, so only
  one call can be in flight inside the last `maxCallReads` (269, from config). That transient rejection gets
  a short `retry_after` (1 s), not midnight. `Reserve` increments `inflight`; `Charge` (or a `Release` for
  rejected paths) decrements it.
- (b) Ask the architect to amend D5 with the concurrent bound and re-run the sybil math. Then rename the
  test and fix the "overshoot is bounded by one call" comments in `daily_cap.go` and `interceptor.go`.
Either way, add a unit test that sends N goroutines at `spent = limit - 1` and asserts the bound.

**M2. The read budget can block DeleteAccount, the right-to-delete path, until IST midnight (rule 10).**
`backend/internal/apiserver/ratelimit_config.go:67` wires the budget over every procedure with no enforcement
exemption. A user who hits `read_budget_daily`, whether a heavy legit user (D5 accepts that F > ~1,000 can hit
it) or a victim of M1, cannot call `DeleteAccount` (or `RequestAccountExport`) for up to 24 h. App Store,
Play and DPDP expect in-app deletion to work. D5 says "every procedure", so this needs a one-line architect
decision, not a silent change.
Fix: add a charge-only set, e.g. `Config.ReadBudgetChargeOnly`, containing `DeleteAccount` and
`RequestAccountExport`. These procedures are charged but never rejected. Their reads are small and already
limited by the per-minute bucket. Explain each entry in a comment. The NO_SIDE_EFFECTS guard is not
affected, because neither RPC is NO_SIDE_EFFECTS.

## Minor

**m1. A charge is lost when the handler panics.** `interceptor.go:162-172`. `mw.Recover` sits outside the
rate-limit interceptor, so a panic unwinds past the charge code and the reads already spent are never
charged. Fix: run the charge in a `defer` right after the Reserve loop.

**m2. `DailyCap.lock` has a Get-miss-then-Set race.** `daily_cap.go` `lock`. Two concurrent first accesses to
a key each create a `dailyCounter`, and the second `Set` replaces the first. Any `Charge` applied to the
replaced counter is lost. This pattern already existed in `Allow`, but it now also affects the separate
`Charge` path, and the read budget touches every uid. Fix: extend `cache.LRU` with
`GetOrSet(key, func() V) V`, run under the LRU's own mutex. Reuse it here and in `Limiter.Allow`, and add a
code-map line.

**m3. A zero or negative env value locks everyone out.** `config.go:299-313` plus `NewDailyCap`
(`limit <= 0 -> 1`). If an operator sets `READ_BUDGET_PER_UID_PER_DAY=0` meaning "disable", every uid is
rejected after its first read, which takes down the whole API. Fix: in `config.Load`, return an error when
any of the three new values is `<= 0`, and add a test case. Rule 11: caps are reviewed like logic.

**m4. The new caps are not in Terraform yet (rule 11).** `infra/terraform/envs/{dev,prod}/main.tf` pin
`LIST_CALLS_PER_DAY` and `GRAPH_MUTATIONS_PER_DAY` explicitly, but `READ_BUDGET_PER_UID_PER_DAY`,
`READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY` and `CHECK_HANDLE_CALLS_PER_DAY` exist only as Go defaults. This is
fine if T26 adds them. Track it there so the runbook's "raise the env var" lever matches Terraform and a
`terraform apply` does not drop a value set by hand.

**m5. The client says "try again in a moment" when the reset is at midnight.** This is a behaviour change for
graph daily caps, but nothing breaks: `connect_error_mapper.dart` maps RATE_LIMITED to
`RateLimitedException(retryAfter)` and ignores `metadata.limit`. `graph_error_messages.dart:13-14` and
`app_error_view.dart:31-35` ignore `retryAfter`, and no Dart or Go test asserted the old values (absent
`retry_after`, no `limit`). The new shape matches the contract in `common.proto:61-63`. However, for
`graph_list_daily`, `graph_mutation_daily`, `check_handle_daily` and `read_budget_daily` the user still sees
"a bit too fast, try again in a moment" although the reset is at IST midnight. Fix (frontend, can be T17):
carry `metadata.limit` on `RateLimitedException`, and show a "resets tomorrow" message or the T17 banner
when `retryAfter > 1 min` or the limit ends in `_daily`.

**m6. The test for "CreateProfile clears the negative entry" does not test the clearing.**
`negative_handle_cache_test.go:53-66`. After `CreateProfile`, `SetProfile` fills the positive `handles` map,
and `CheckHandleAvailability` checks that map first. The test would still pass if
`c.handleFree.Delete(p.HandleLower)` were removed from `SetProfile`. Fix: also assert
`!svc.cache.GetHandleFree("claimme")`. Add the same case for `ChangeHandle` to a previously-free handle.

**m7. Rejections by the IP budget and the uid budget look the same.** `interceptor.go:150-152`. Both log
`limit_name=read_budget_daily` and set `metadata.limit=read_budget_daily`. That matches D5, but the runbook's
"sign-up farm vs heavy user" triage then cannot see which key tripped. On an IP rejection,
`read_budget_spent` holds the IP's spend under the same field name as uid spend. Fix: add a log-only field,
`read_budget_key` = `uid` or `ip`, and keep the client-visible metadata as D5 specifies.


## Nits
- The reject path calls `Spent()`, which re-locks and can roll over past midnight. Have `Reserve` return `(ok, spent)`.
- `read_budget_spent` logs whichever key comes first (`i == 0`) instead of naming the key.
- The worst-case call is 269 in `config.go:99` but 268 in the tests and the plan. Use one named constant.
- `docs/code-map.md:30`: the new text is appended to the previous sentence without a full stop.
- The guard test enumerates linked descriptors rather than building the mux. Equivalent in practice; say so in its comment.
- The per-IP per-minute limiter still keys IPv6 by the full address rather than the /64 (pre-existing; for T24).
- For T24's threat model: an attacker with an IPv6 /48 has 65k /64 keys, which multiplies the 500-read IP budget and can churn the 100k-key LRU.

## Checked and fine
- IST rollover: handled lazily in `lock`; `UntilNextDay` is correct and tested, including month end given in UTC.
- Error paths: errors are charged; rejections cost 0 reads and are not charged; account-status interceptor reads are included.
- IPv6 /64 key: v4-mapped addresses are unmapped; the IP is never logged.
- IP scope: the IP budget applies only to the profile-exempt procedures (D5 refinement 1).
- Negative cache vs CreateProfile/ChangeHandle: creation stays transactional so a stale "free" hint cannot produce a duplicate; HANDLE_TAKEN clears the stale entry; cross-instance staleness up to 10 s is accepted by D5.
- Rules 5 and 6: no new queries; everything added costs 0 Firestore reads or writes.
- Reuse-first: `DailyCap` extended, not duplicated; `UntilNextDay` has no existing equivalent; code-map updated.
- Log fields: no PII.

Not run by the reviewer: `-race` (no cgo), the emulator integration tests (the tester ran them; see the test report).

VERDICT: CHANGES REQUESTED
