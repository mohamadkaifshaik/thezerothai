# Security re-review: P0 read budget after ADR-0010 D5 A1–A7

- **Scope:** branch `feat/p0-read-budget` at `b78d6a9`, `git diff origin/main...HEAD` (commits 4aac42a, 499dd57,
  ba4dbd5, b78d6a9 on top of the scope of the first review). Read-only on code. Unit tests for the changed packages
  run locally and pass (`go test ./pkg/platform/{ratelimit,authn,cache,config}/... ./internal/{apiserver,identity}/...`;
  `-race` not run, cgo unavailable on the review host).
- **Question:** are the findings of `p0-read-budget-security-review.md` (H1, M1–M4, L1–L6, conditions to close)
  closed by the implementation of ADR-0010 D5 A1–A7, and does the implementation add new issues (verified-identity
  gate bypasses, XFF/IP key spoofing, mark/LRU eviction abuse, charge-only paths, log PII)?
- **Reviewer:** security-auditor. **Date:** 2026-10-01.

## Summary

| Severity | Open | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 0 | H1 closed |
| Medium | 2 | M2 (pending founder acceptance), N1 (new; the M3 intent is not met end to end) |
| Low | 6 | L2 (still open), N2, N3, N4, N5, N6 |

**The public-repo finding is closed.** Unverified password accounts, the only free-to-mint identity, now cost 0
reads and create no limiter keys (A2). Verified callers without a profile are charged to their IP key (A3), and the
per-minute IP limiters key by /64 (A5). Concurrency overshoot is bounded (A1). What remains: a shared-IP onboarding
denial of service (N1), the per-instance-lifetime bound that still needs written founder acceptance (M2), a runbook
that still has the broken query (L2), and Lows.

## Status of the findings of the first review

| ID | Was | Now | Evidence |
|---|---|---|---|
| H1 | High | **Closed** | `authn.VerifiedIdentityInterceptor` is wired right after `IDTokenInterceptor` and before `ratelimit.Interceptor` (`apiserver.go`); predicate `Claims.UnverifiedPassword()`; 0 provider calls asserted in `gate_test.go`. A3 mark + IP charge in `settleReadBudget`; A5 /64 keys in `PreAuthIPMiddleware` and the in-chain `cfg.IP` (`TestA5_PerMinuteIPLimiterKeysBy64`, `TestA5_PreAuthMiddlewareKeysBy64`). ADR-0010 D5 residual restated (table rows 1 and 4). Residual: the T26 precondition (no unverified password account owns a `users` doc) is a deploy-time check, not yet recorded. See N3/N4 for hardening. |
| M1 | Medium | **Closed** | `DailyCap.Reserve` rejects when `inflight > 0 && count + (inflight+1)·M > cap`; `Release` settles in a `defer`. `TestA1_InterceptorConcurrencyBound` races calls at `cap − 1`. The invariant holds for the uid key (M = 269). It does not hold for the IP key when a stale mark routes heavy calls of a profile owner to it (N2). |
| M2 | Medium | **Open (acceptance pending)** | ADR-0010 D5 now states bounds per instance lifetime (2,308 per uid; ≈ 208k/day idle cycling, ≈ 623k ceiling) and pre-designs Option 2c-B behind a trigger. Condition 2 also required founder acceptance in the readiness report: no R1/R2 acceptance is recorded in any `docs/reviews/release-*-readiness.md`. Code comments were not restated: `config.go:109` still says "worst case per account per IST day is 3 × … = 6,804", and `daily_cap.go:21` still says "roughly limit x max-instances". |
| M3 | Medium | **Server side fixed; superseded by N1** | CreateProfile is IP charge-only (`ReadBudgetIPChargeOnly`, `TestA4_CreateProfileIsChargeOnlyOnIP`). But the client only enables Submit after CheckHandleAvailability returns available (`OnboardingState.canSubmit`), and CheckHandleAvailability stays IP-enforced, so the sign-up block the finding described still happens (N1). |
| M4 | Medium | **Closed** | `ResolveClientIP` falls back to the rightmost entry when the chosen one does not parse, and returns no IP when neither does (`TestA5_ResolveClientIPFallsBackToRightmost`); `IPBudgetKey` returns a key and an ok flag, with only canonical `netip` strings (≤ 43 bytes); `http.Server.MaxHeaderBytes = 64 KiB`. The R-N2 relay precondition remains a known, separately tracked gap (N5). |
| L1 | Low | **Closed** | `read_budget_key` (uid or ip), `read_budget_spent` (always uid), `read_budget_ip_spent`, and the `read_budget_inflight` limit name (`TestA7_*`). |
| L2 | Low | **Open** | `abuse-spike.md` still contains the Log Analytics SQL with the `<log view>` placeholder and a `json_payload.limit_name` string comparison (a type error on a JSON column), although the ADR-0010 Handoff says "Logs Explorer filters, not SQL". The R2 churn check (one `uid_hash` rejected on ≥ 3 distinct `labels.instanceId` in an IST day) and the statement that `DEGRADED_MODE=readonly` does not reduce reads are missing. The lever text still says "worst case is x3", which contradicts the per-lifetime bounds in D5. |
| L3 | Low | **Closed** | `cache.LRU.GetOrSet` is used by `DailyCap.lock` and `Limiter.Allow`. |
| L4 | Low | **Closed** | Settlement is deferred in `ratelimit.Interceptor`. |
| L5 | Low | **Closed (recorded)** | ADR-0010 D15 records ≈ 200–250 B/entry and ≈ 20–25 MiB per full LRU. Minor drift: D15 says the negative handle entries share the identity `notFound` LRU, but the code adds a separate `handleFree` LRU (another `cacheCapacity` entries); update the text. |
| L6 | Low | **Closed** | `rateLimitConfig(cfg)` and `profileExemptProcedures()` are shared by `Build` and `guard_test.go`; the guard asserts `ReadBudgetIP` is wired, `Enforce ∪ ChargeOnly == ProfileExempt` with no overlap, and that the charge-only set is exactly the three account operations, each with a `DailyCaps` entry. |

## STRIDE: the amended controls

| Threat | Where | Status |
|---|---|---|
| **S**poofing identity class | A2 gate trusts `firebase.sign_in_provider` and `email_verified` from a signature-verified ID token. Only `password && !email_verified` is blocked. | Sound for the enabled providers. The denylist shape is fragile (N3). |
| **S**poofing the IP key | `ResolveClientIP` + `IPBudgetKey`. | Direct and Hosting paths are not spoofable. R-N2 relays can choose a valid IP (N5). |
| **T**ampering with counters | Per-instance memory; A1 hold; A3 mark. | Churn accepted pending sign-off (M2). A stale mark misroutes charges (N2). |
| **R**epudiation | A7 fields on every request line; WARN `read_budget_over_max`. | Adequate. |
| **I**nformation disclosure | New log fields and client metadata. | No IP, email or token logged. No new client-visible state (Info). |
| **D**enial of service | IP key enforced on CheckHandleAvailability and on marked uids behind a shared IPv4. | N1 (Medium), N2. |
| **E**levation (cost) | Charge-only paths; gate ordering. | Bounded today (N6 is forward-looking). Wiring order untested (N4). |

## New findings

### N1 (Medium): one verified account behind a shared IPv4 still blocks sign-up for everyone behind it

**Evidence:**
- `ReadBudgetIPEnforce` = {CheckHandleAvailability}: the IP key (500 per instance per IST day, full IPv4 address)
  rejects it with `retry_after` to IST midnight.
- `ReadBudgetIPChargeOnly` = {CreateProfile}: never rejected, but **charged** to the same IP key.
- Client: `OnboardingState.canSubmit` requires `handleCheckStatus == available`. On any `AppException` from
  CheckHandleAvailability the bloc sets `unavailable` with the error message (`onboarding_bloc.dart`,
  `_onHandleChanged`). So while CheckHandleAvailability is rate-limited the user can never press Submit, and A4
  (CreateProfile is never rejected by the IP key) does not help.
- Marked uid: the second non-exempt call of a new user on the same instance within 10 min (for example GetMe after an
  app restart) reserves the IP key. If it is spent, GetMe returns `RATE_LIMITED`, not `PROFILE_REQUIRED`, and
  `_loadMe` shows the error state instead of the create-profile screen.

**Exploit (availability; cheaper than the first review assumed):**
1. From an Airtel/Vi carrier-grade NAT address or a campus NAT, one verified account without a profile (Google
   sign-in is enough) calls CreateProfile repeatedly with a taken handle. Each call reads 1–2 docs, charged to its uid
   budget (2,000) **and** to the IP key, and is never rejected by the IP key. About 250–500 calls (well inside 60/min
   and the uid budget) push the IP key past 500 on that instance. Repeating per instance (3 instances) covers the
   service. Five verified uids × 100 CheckHandleAvailability calls also works.
2. Every new user behind that address now gets an error on every keystroke in the handle field until IST midnight and
   cannot submit the form. A busy campus reaches the same state organically.
- Not a cost issue: every read is also bounded by the uid budget of the caller.

**Why IP enforcement on CheckHandleAvailability is no longer needed:** it existed to bound unverified sybils. A2 now
answers those with 0 reads. Verified callers are each held to `check_handle_daily` (100 calls) and to their uid
budget, and the negative handle cache makes repeated probes of the same handle 0 reads.

**Fix ($0; the first option is the smallest):**
- Move CheckHandleAvailability to `ReadBudgetIPChargeOnly`. The IP key then only measures on the exempt procedures,
  the guard test check `Enforce ∪ ChargeOnly == ProfileExempt` still holds (`ReadBudgetIPEnforce` may be empty), and
  enforcement stays only for marked uids.
- Or, in the client: treat `RATE_LIMITED` on CheckHandleAvailability as unknown and allow Submit (the server-side
  `handles` transaction is authoritative), and on GetMe `RATE_LIMITED` with `limit=read_budget_daily`, retry after
  `retry_after` instead of showing the error state.
- Either way, add a test: with the IP key spent by another uid, a new verified uid can still complete
  CheckHandleAvailability → CreateProfile.

### N2 (Low): a stale profile-less mark routes heavy calls of a profile owner to the IP key with a hold of 2

**Evidence:** the mark is per instance with a 10 min TTL, and only a successful CreateProfile **on the same instance**
clears it (`settleReadBudget`). There is no session affinity, so the GetMe of a new user (instance A, marks) and the
CreateProfile (instance B, clears B only) commonly land on different instances. For up to 10 min every non-exempt call
of that user on A reserves and is charged to the IP key, including GetHomeTimeline (up to 269 reads) and graph lists.
`IPReadBudgetMaxCallReads = 2` assumes every IP-keyed call reads at most 1 doc, so the A1 IP invariant (≤ 501 per
lifetime) does not hold: concurrently admitted calls can overshoot by k × 269, and WARN `read_budget_over_max` fires on
legitimate traffic. Behind a busy NAT this also drains the shared IP key (feeding N1), and the brand-new user gets
`RATE_LIMITED` (10 min) on instance A right after sign-up. Cost is unaffected (the uid budget still binds).

**Fix:** in `settleReadBudget`, when the IP key was taken only because of the mark (`dailyRetry > 0`) and the call did
**not** set `ProfileRequired` (it passed account status, so the caller has a profile), settle the IP key with
`Release(ipKey, 0)` instead of the reads, and `profileLess.Delete(uid)`. Test: a marked uid whose call passes account
status is unmarked and not charged to the IP key.

### N3 (Low): the verified-identity gate is a denylist on the sign-in provider

**Evidence:** `UnverifiedPassword()` blocks only `sign_in_provider == "password" && !email_verified`. Every other value
passes: `anonymous`, `phone`, `github.com`, `facebook.com`, `custom`, or a future SAML/OIDC provider. Firebase Auth
providers are set in the console (there is no `google_identity_platform_config` in Terraform); anonymous sign-up being
off is recorded only by a manual check (`security-audit-v0.1.0.md`, `cloud-bootstrap.md`); and the e2e suite mints
anonymous users (`backend/e2e/identity_smoke_test.go`, `newAnonymousIDToken`). Enabling anonymous auth in a project is
one console click and would silently reopen H1 at full scale (free uids, 1 read each per 10 s per instance, no IP
bound until marked).

**Fix:** make the gate an allowlist that fails closed: pass `google.com`, `apple.com`, and `password` with
`email_verified`; answer everything else like an unverified password account. Allow `anonymous` only when
`FIREBASE_AUTH_EMULATOR_HOST` is set (or move e2e to verified emulator password users). Optionally manage the Auth
provider config in Terraform so drift shows in `plan`.

### N4 (Low): nothing tests that `Build` places the gate before the rate limiter

**Evidence:** `gate_test.go` builds its own chain, and the guard test inspects `rateLimitConfig`, not the interceptor
order in `Build`. Moving `VerifiedIdentityInterceptor` after `ratelimit.Interceptor` or `AccountStatusInterceptor`, or
dropping it, compiles and passes CI while reopening H1 (limiter keys and a 1-read account-status lookup per minted uid).

**Fix:** a `Build`-level test (with fakes, like the existing wire tests) that calls a non-exempt RPC with an unverified
password token and asserts FAILED_PRECONDITION + PROFILE_REQUIRED, 0 account-status lookups and
`gate=email_unverified`; or export the interceptor slice from a helper and assert its order.

### N5 (Low, tracked with R-N2): IP-key framing through Google-run relays

**Evidence:** after A5, a spoofed but **valid** IP left of a Google egress entry is still used (only unparseable
entries fall back). If a Google-run fetcher exists that forwards a client-supplied X-Forwarded-For, `Authorization` and
a POST (unverified, R-N2), an attacker can name the carrier NAT address of a victim as the key: drain its
CheckHandleAvailability IP budget (N1) and its 120/min pre-auth bucket, so a whole carrier address sees 429s. Cost
impact is nil (uid budgets bind). **Fix:** keep R-N2 in the tracker; the N1 fix removes most of the value; keep the
Google-egress allowlist limited to the observed Hosting egress.

### N6 (Low, forward-looking): charge-only account operations and their future async work

**Evidence:** DeleteAccount, RequestAccountExport and GetAccountExport are Unimplemented stubs today (1 read each in the
account-status interceptor, bounded by `account_ops_daily` = 20 per uid per instance). When the ADR-0003 jobs land,
each RequestAccountExport or DeleteAccount call will enqueue a Pub/Sub job whose traversal reads are spent on
`/internal/*`, outside any user budget. At 20 calls × 3 instances (× lifetimes, M2), one verified account could trigger
dozens of full traversals a day. **Fix (when implemented):** at most one pending export and one pending deletion per
uid (deterministic job doc id; a replay returns the existing job), and attribute the job reads to the uid in the cost
report. Add this to the Phase 1 plan acceptance criteria.

## Info (checked, no finding)

- **Gate correctness:** claims come only from the verified token (Admin SDK); a user cannot set `email_verified` or
  custom claims without admin credentials. Google and Apple always assert verified emails. A stale token right after
  verification only affects UX (the client forces a refresh). Rejected calls cost 0 reads and create no limiter or mark
  keys; they still pass `PreAuthIPMiddleware` (per /64), so request floods stay bounded by it and by max-instances.
- **Mark and LRU eviction:** filling `profileLess`, a `DailyCap` or the in-chain limiters to 100k keys needs 100k
  distinct verified uids (or /64s reached through verified calls). A mark only adds IP enforcement, so evicting one
  gains nothing beyond the uid budget. The pre-auth limiter can be churned with a free routed IPv6 /48 (65k /64s), but
  eviction only hands out a fresh per-minute burst. An evicted `DailyCap` counter with calls in flight is safe:
  `Release` on the new counter charges and never drives `inflight` negative.
- **Charge-only paths:** `ReadBudgetChargeOnly` is exactly the three account operations, each with `account_ops_daily`
  (guard-tested; `TestAccountOps_21stCallIsRateLimitedEvenOverTheReadBudget`). CreateProfile is the only IP charge-only
  procedure and stays bounded by the uid budget and the `handles` transaction. A marked uid on a charge-only procedure
  is not IP-enforced (correct).
- **A1 bound for the uid key:** M = 269 matches the largest documented cold ceiling; calls above it WARN. Transaction
  retries are counted by `budget.Counter` and stay far below M for the graph mutations.
- **Log PII:** the new fields are `gate`, `read_budget_key`, `read_budget_spent`, `read_budget_ip_spent`,
  `read_budget_inflight`, `profile_required`, and a WARN with `uid_hash`, `rpc` and counts. No IP address, IP key,
  email, token or request body is logged. `uid_hash` is an unsalted, truncated SHA-256 (pre-existing; disclosed as a
  pseudonym in `app/web/privacy.html`).
- **Config:** `config.Load` rejects values ≤ 0 for the four new env vars; dev and prod Terraform set them to the code
  defaults.
- **Negative handle cache:** unchanged from the first review; `ChangeHandle` and `CreateProfile` on `HANDLE_TAKEN` also
  invalidate the hint.

## Conditions to close

1. **N1:** make CheckHandleAvailability IP charge-only (or fix the client as described), with a test that a spent IP
   key does not stop a new verified user from completing sign-up. Medium, so not a release blocker by the
   Critical/High rule, but it should ship with this branch: the M3 condition was meant to remove exactly this.
2. **M2:** the founder copies the ADR-0010 D5 R1/R2 acceptance, dated, into the release readiness report before the
   T27 `percent` step. Update the comments at `config.go:109` and `daily_cap.go:21` to the per-lifetime bound.
3. **L2:** replace the SQL in `abuse-spike.md` with Logs Explorer filters, add the R2 `labels.instanceId` check and the
   note that `DEGRADED_MODE=readonly` does not reduce reads, and drop "worst case is x3".
4. **H1 deploy precondition (T26):** record the count of password accounts with `emailVerified=false` that own a
   `users` doc (expected 0; the count only, never uids) before the A2 gate reaches prod.
5. N2–N6 tracked. N3 and N4 are cheap and recommended in the same PR.

VERDICT: CLOSED (0 Critical / 0 High open). The read-amplification finding, including its sybil half, is fixed.
Open: M2 (pending founder acceptance), N1 (Medium), L2 and five new Lows.
