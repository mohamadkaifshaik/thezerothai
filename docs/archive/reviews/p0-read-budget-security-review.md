# Security review: P0 / T3 read-cost hardening (ADR-0010 D5)

- **Scope:** `git diff 9fdb8bd..9c7a6ea` (commits 2eff995, 6dc3651, 40f7d8d, 9c7a6ea): `ratelimit.DailyCap`
  Reserve/Charge, the read budget in `ratelimit.Interceptor`, `IPBudgetKey`, `check_handle_daily`, the identity
  negative handle cache, `apiserver.rateLimitConfig` and its guard test, and the `abuse-spike.md` query.
- **Question:** is the public-repo finding closed? That finding is read amplification through
  CheckHandleAvailability and GetProfile, multiplied by sybil accounts and by profile-exempt procedures
  (`phase1.md` §P0, ADR-0010 Context).
- **Reviewer:** security-auditor. **Date:** 2026-09-30. Read-only review. No code was changed.
- **Checklist:** `security-checklist` items "Rate limits: per-user daily quotas + per-instance token buckets per uid
  and per IP", "App Check enforced", "Signup friction", and "Budget alerts + degraded mode are part of the abuse
  response (a scraping/spam spike is also a cost spike)".

## Summary

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 1 | H1 |
| Medium | 4 | M1, M2, M3, M4 |
| Low | 6 | L1–L6 |

**What the diff fixes correctly:**
- CheckHandleAvailability now has three bounds: 100 calls per uid per day, 500 reads per IP (or IPv6 /64) per day,
  and the per-uid read budget. A single account can no longer spend 58% of the free reads.
- GetProfile is under the per-uid budget, and a missing handle is negatively cached for 10 s.
- The budget runs before account status, so a rejected call costs 0 reads.
- Reads spent by the account-status interceptor are charged, because the counter comes from the outermost
  `mw.Logging`.
- The guard test enumerates NO_SIDE_EFFECTS procedures mechanically.

**What stays open:**
- **H1.** The "sybil-multipliable" half of the finding is still open. An account without a profile can call any
  non-exempt RPC. Each call costs one read in the account-status check, and that read is charged only to the
  rotating uid, never to the IP.
- **Understated bounds.** The worst-case numbers in ADR-0010 D5 and `config.go` are too low. They ignore concurrent
  in-flight calls (M1) and instance churn (M2).

## STRIDE: read budget (the new control)

| Threat | Where | Status |
|---|---|---|
| **S**poofing the IP key | `ResolveClientIP`: the rightmost X-Forwarded-For entry is appended by the Cloud Run front end. The code steps one entry left only when the rightmost entry is a Google-operated egress IP (not a customer-assignable one). | A spoofed XFF sent straight to `*.run.app` is ignored. The one exception is the known R-N2 gap, relays through Google-run fetchers (M4). |
| **T**ampering with counters | In-memory, per instance. Counters reset on scale-to-zero, a new instance or a new revision. | M2 |
| **R**epudiation | Every request line carries `limit_name`, `read_budget_spent` and `uid_hash`. | L1: a uid rejection and an IP rejection cannot be told apart. |
| **I**nformation disclosure | A rejection returns `metadata.limit` and `retry_after` (time to IST midnight). | No material leak (see Info). |
| **D**enial of service | The IP budget can be exhausted on a shared IPv4 address. LRU key growth. | M3, M4, L5 |
| **E**levation (cost) | Profile-less uid rotation on non-exempt RPCs. Concurrent overshoot. | H1, M1 |

## High

### H1: Profile-less sybil uids bypass the IP budget on every non-exempt RPC. IPv6 rotation bypasses the per-minute IP limiters.

**Evidence:**
- `interceptor.go`: `ReadBudgetIP` is enforced and charged only when the procedure is in `ProfileExempt`
  (Refinement 1).
- `authn.AccountStatusInterceptor` → `identity.getProfileCached`: for a uid with no `users/{uid}` doc, this costs
  1 read (`repo.GetProfile`, counted on NotFound) and then a 10 s per-instance negative cache (`notFoundTTL`).
- The read is charged to the budget of the uid only.
- `PreAuthIPMiddleware` and the in-chain `cfg.IP` limiter both key on the raw address from `ResolveClientIP`. For
  IPv6 that is the full /128, not the /64.
- Password accounts need no verification until CreateProfile (`identity/server.go:30-37`, audit H1). The codebase
  itself notes that they "can be minted by the thousand per hour per IP".

**Exploit (cost amplification):**
1. Mint N email/password Firebase accounts. This costs nothing and needs no email verification. Never call
   CreateProfile.
2. Call any non-exempt RPC (for example `GetMe` or `GetRelationships`), rotating through the uids. Each call returns
   `PROFILE_REQUIRED` after 1 Firestore read.
3. Each uid costs at most 1 read per 10 s per instance, which is about 8.6k a day, capped by its own 2,000 budget
   per instance. That is 6,000 reads per uid per day.
4. Nothing ties those uids to an IP budget.

**Resulting bounds:**
- **One IPv4 address:** the only bound is the per-IP per-minute limiters (120/min per instance). That is
  120 × 1,440 × 3 ≈ **518k reads/day, about 10× the free 50k/day**. It needs roughly 90 or more uids (172,800 calls
  per instance ÷ 2,000). At the price implied by ADR-0010 (about $0.06 per 100k), that is about $0.28 per day per
  IPv4, linear in the number of addresses.
- **One IPv6 /64:** the per-minute IP limiters are bypassed by rotating addresses inside the /64. The bound becomes
  uids × 6,000, limited only by Cloud Run throughput (3 × 80 concurrency).
  - 2,400 uids (one day of the Firebase per-IP sign-up throttle) → about **14.4M reads/day, roughly $8–9/day**. That
    is more than the whole $5 budget in one day.
  - uids persist, so the pool grows day over day.
  - Whether the Firebase sign-up throttle keys IPv6 by /128 or by prefix is unverified.
- **None of the abuse-spike levers stop it:**
  - The sign-up kill switch does not affect uids that already exist.
  - Lowering `READ_BUDGET_PER_UID_PER_DAY` does not help against rotation.
  - `DEGRADED_MODE=readonly` does not reduce reads.
  - Disabling accounts one at a time does not scale, because logs carry only `uid_hash`.
  - The only effective lever is dropping max-instances or taking the service down.
- The App Check control on the checklist is monitor-only (phase1 D3), so nothing else fills this gap.

**Why this is in scope:**
- The finding explicitly says the attack is "also sybil-multipliable" through profile-exempt access.
- ADR-0010 D5 says "Profile-less, per IP (or /64): ≈ 1,503 reads/day". That holds for the two exempt procedures
  only.
- For profile-less callers overall, the true figure is about 518k/day per IPv4, and there is no IP bound at all on
  IPv6.
- So the residual statement ("Sybils **with profiles** still multiply…") is inaccurate. Sybils **without** profiles
  multiply too. They are cheaper, because they need no verified email, no handle and no writes.
- This path predates P0 (it was mitigated only by the M1 negative cache). P0 adds nothing to it, but the stated P0
  goal, "no read RPC can be used to push Firestore reads past the free tier", is not met.

**Fix ($0, small):**
1. **Mark profile-less callers.** In `AccountStatusInterceptor`, on the `!exists` branch, record it on the shared
   request info, for example `info.Set("profile_required", true)`.
2. **Charge their reads to the IP.** In `ratelimit.Interceptor`, after `next`, when that flag is set, charge the reads
   to the IP (/64) budget as well. Also mark the uid in a small per-instance "profile-less today" set (a `DailyCap`
   or a boolean LRU; no new limiter type).
3. **Widen the IP pre-check.** Before `next`, apply the IP-budget pre-check on exempt procedures **and** for any uid
   in that set. Callers with a profile never enter the set, so the CGNAT protection from Refinement 1 is kept.
   - Residual after this fix: the first call of each new uid per instance still gets through, at 1 read. That is
     bounded by the sign-up rate, about 2.4k × 3 per IP per day.
4. **Key the per-minute IP limiters by /64.** Key both `PreAuthIPMiddleware` and the in-chain `cfg.IP` limiter by
   `IPBudgetKey(ip)`.
5. **Optional alternative (0 reads).** Set a Firebase custom claim at CreateProfile (Admin SDK, free) and return
   `PROFILE_REQUIRED` without any read when the claim is absent. Existing profiles need a fallback or a backfill.
6. **Correct the docs.** Restate the ADR-0010 D5 residual and the `config.go` comment with the real profile-less
   bound, and add a lever for this pattern to `abuse-spike.md`.

## Medium

### M1: Overshoot is not "bounded by one call": Reserve holds nothing, so concurrent calls all pass

**Evidence:**
- `DailyCap.Reserve` only checks `count < limit`. `Charge` runs after `next`.
- Per-minute buckets start full (`burst = ratePerMinute`): lists 20, default 60, and after T4 the timeline at 6.
- The test `TestReadBudget_OvershootBoundedByOneCall` is serial, so it cannot catch this.

**Exploit:**
1. Bring the uid to 1,999 spent.
2. Fire 20 concurrent ListFollowers calls (102 reads worst each). All 20 pass Reserve.
3. Spend is now about 4,039 on that instance.
4. Later, add 6 concurrent GetHomeTimeline calls (269 each) and 60 GetProfile calls.

That gives about 1,999 + 2,040 + 1,614 + 180 ≈ 5.8k per instance, and **≈ 17.5k per account per day** across 3
instances. The documented figure is 6,804. That is 35% of the free quota from one account, and about 3 sybils with
profiles exhaust it instead of 7.

**Fix:** pick one:
- Reserve a pessimistic hold: add the documented worst case of the procedure at Reserve and reconcile at Charge.
- Cap in-flight requests per uid (a 2–4 slot semaphore keyed by uid in the same LRU).
- At minimum, restate the bound as cap − 1 + Σ(burst × worst) and correct the claim in the test.

### M2: The stated worst case ignores instance churn

**Evidence:** counters live in memory. They reset when an instance scales to zero (idle for about 15 min), when a new
instance starts, and on every new revision. During a 10% rollout, two revisions each run up to 3 instances, so there
are 6 counters. `daily_cap.go` acknowledges this, but the ADR-0010 D5 figure "≤ 6,804 per account per IST day" and
the P0 cost line do not.

**Exploit:** at Stage 0 the service is often idle. An attacker spends about 2.3k, pauses about 15 minutes until the
instance scales to zero, and repeats. That is dozens of cycles a night, so **tens of thousands of reads per account
per day** instead of 6.8k. Forcing a scale-up with a concurrency burst adds instances whose counters are fresh and
vanish on scale-down.

**Fix:**
- State the bound honestly: per instance-lifetime, not per day.
- Or persist the counter cheaply. For example, write `quotas/{uid}.reads` only when a uid crosses 50% and 100% of the
  budget, and read it once per uid per instance on first sight. That costs at most 2 writes per heavy uid per day,
  plus 1 read per uid per instance-start.
- Whichever you choose, record the choice in the ADR.

### M3: The IP budget blocks CreateProfile, so one abuser behind a shared IPv4 blocks sign-ups for everyone behind it

**Evidence:** the IP pre-check applies to both exempt procedures, CreateProfile included. The IPv4 key is the full
address, and Indian mobile IPv4 (Airtel, Vi) and campus Wi-Fi are carrier-grade NAT. The budget is 500 reads per IP
per instance per day.

**Exploit:**
1. From a shared NAT address, rotate 5 uids × 100 CheckHandleAvailability calls on distinct free handles.
2. That spends 500 reads.
3. Every real user behind that address now gets `RATE_LIMITED` on CreateProfile until IST midnight, with
   `retry_after` of up to 24 h.

A busy campus reaches the same state organically: about 50 sign-ups × about 10 debounced checks.

**Fix:**
- Make CreateProfile charge-only for the IP key (no pre-check). It is already bounded by `email_verified`, the
  per-uid budget and handle `Create`.
- Enforce the IP pre-check only on CheckHandleAvailability.
- Consider a separate, lower-priority client message.

### M4: IP keys controlled by an attacker feed a DailyCap with no TTL, and unparseable keys are stored raw

**Evidence:**
- `IPBudgetKey` returns unparseable input unchanged.
- `ResolveClientIP` trusts the entry left of a Google-operated egress IP.
- Requests relayed by Google-run fetchers that pass through a client-supplied XFF are the known gap R-N2.
- `DailyCap` has no idle TTL (by design, L1 of the earlier audit), and entries leave only at 100k.
- The HTTP server does not set `MaxHeaderBytes` (Go default 1 MiB). The header limit of the front end is the only
  bound on key length.

**Exploit (the precondition is unverified: it needs a Google fetcher that accepts a custom XFF, `Authorization` and a
POST):**
- A random valid IP per request gives unlimited IP budget. That part is the known R-N2.
- A random long string per request fills the IP DailyCap and both IP Limiters with large keys. 100k keys × several
  KiB exceeds 512 MiB, and the OOM restart resets every in-memory counter (see M2).

**Fix:** in `ResolveClientIP`, if the chosen entry does not parse as an IP, fall back to the rightmost entry, which
the front end appended. Never use a raw string as a key, and cap key length.

## Low

- **L1: uid and IP rejections cannot be told apart.**
  - Both log `limit_name=read_budget_daily`.
  - On an IP rejection, `read_budget_spent` holds the IP spend. Otherwise it holds the uid spend.
  - The runbook heuristic ("many hashes at the cap = farm") will misread an IP-budget event, which shows many
    `uid_hash` values with low spend.
  - **Fix:** log `read_budget_key=uid|ip`, or give the IP rejection its own log `limit_name`. The client metadata
    can stay the same.
- **L2: the runbook query will not run as written.**
  - Log Analytics is not enabled on any log bucket in Terraform (no `google_logging_project_bucket_config`), and
    click-ops is forbidden.
  - `<log view>` is a placeholder.
  - `json_payload` has the JSON type, so `json_payload.limit_name = "read_budget_daily"` is a type error, and
    `GROUP BY` on a JSON value is not allowed.
  - **Fix:** enable analytics on `_Default` in Terraform (free) and use:

        SELECT JSON_VALUE(json_payload.uid_hash) AS uid_hash, COUNT(*) AS rejections,
               MAX(LAX_INT64(json_payload.read_budget_spent)) AS max_spent
        FROM `dzeroth-prod.global._Default._AllLogs`
        WHERE resource.type = "cloud_run_revision"
          AND JSON_VALUE(json_payload.limit_name) = "read_budget_daily"
          AND timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY)
        GROUP BY uid_hash ORDER BY rejections DESC

    Also give the Logs Explorer filter that the rest of the runbook uses:
    `resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.limit_name="read_budget_daily"`.
  - The lever in the runbook ("raise or lower the env var") does not address uid rotation (see H1).
- **L3: race on a new key in `DailyCap.lock`.** It does `Get` miss → new counter → `Set`. Two concurrent first
  requests create two counters, and the charges on the losing counter are orphaned. **Fix:** get-or-create under a
  lock.
- **L4: the charge is skipped on a panic.** It is not deferred, and `mw.Recover` sits outside the rate limiter, so a
  panic after reads skips it. **Fix:** `defer` the charge.
- **L5: the memory estimate is understated.**
  - T3 says 100k keys × 64 B ≈ 6 MiB. The realistic figure is about 200–250 B per entry (key, counter, list element,
    map), which is about 20–25 MiB per full DailyCap.
  - With five DailyCaps and four 100k-key Limiters, the worst case is about 150–200 MiB of the 512 MiB instance.
    That is acceptable now that keys are bounded (`ValidUID` ≤ 128 characters, IP keys parse; M4 aside), but it
    should be recorded.
- **L6: the guard test does not check the IP budget wiring.**
  - It builds the config with `profileExempt = nil`, so it proves nothing about the IP budget.
  - It does not assert that `ReadBudgetIP` is non-nil and scoped to CreateProfile and CheckHandleAvailability as
    wired by `Build`.
  - **Fix:** build `profileExempt` in one exported helper that both use, and assert it.

## Info (checked, no finding)

- **Rejection leakage:**
  - A read-budget rejection happens before account status, so a suspended or deleting account sees `RATE_LIMITED`,
    not `ACCOUNT_RESTRICTED`. That leaks no state.
  - `retry_after` (time to IST midnight) is public information.
  - `metadata.limit` reveals only which class of limiter fired.
  - `read_budget_spent` goes to logs only, never to the client.
  - The negative handle cache changes latency only for handle existence, which CheckHandleAvailability already
    exposes by design.
- **Negative handle cache:**
  - CreateProfile and ChangeHandle stay transactional (`handles` Create), so a stale "free" cannot produce a
    duplicate handle.
  - `SetProfile` clears the entry.
  - Staleness across instances is at most 10 s, and only affects UX.
- **RPC ordering:** the uid budget cannot be dodged by ordering.
  - The pre-check runs after the per-minute buckets and before degraded mode and account status.
  - The charge covers every read in the chain, on success and on error, including transaction retries.
  - The IP budget can be dodged by choosing a non-exempt RPC (H1).
- **Client IP on Cloud Run and Hosting:**
  - A direct call to `*.run.app` uses the entry the front end appended, so a spoofed XFF is ignored.
  - Through Hosting, the code steps one entry left to the entry Hosting appended (egress observed live, recorded in
    `google_egress.go`).
  - IPv4-mapped IPv6 is normalized.
  - An empty XFF (local only) disables the IP key.
- **uid keys:** `ValidUID` bounds the caller uid to at most 128 characters of `[A-Za-z0-9-]`.

## Conditions to close

1. **H1:** fixed as described, with tests: a profile-less uid rotating on a non-exempt RPC is charged to its /64, and
   the per-minute IP limiters are keyed by /64. Also restate the ADR-0010 D5 residual accurately.
2. **M1 and M2:** fixed, or restated in ADR-0010 D5 and `config.go` with the true bounds (concurrent bursts,
   per instance-lifetime), with founder risk acceptance recorded in the readiness report.
3. **M3:** CreateProfile is charge-only on the IP key, or the founder accepts the risk.
4. **L2:** the runbook query corrected, with Log Analytics enabled in Terraform or the query replaced by a Logs
   Explorer filter.
5. M4 and L1, L3–L6 are tracked. They are not gating on their own.

The original single-account amplification through CheckHandleAvailability and GetProfile **is** fixed. The sybil
half of the finding is not.

VERDICT: NOT CLOSED
