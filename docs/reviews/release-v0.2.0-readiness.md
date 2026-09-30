# Release readiness — v0.2.0 (social graph: follow, block, mute, lists; flag off, then allowlist)

Inputs prepared by the production-deployer agent, 2026-09-30 (ticket T24, `docs/plans/graph.md`). **This is an input
package, not a verdict.** The `production-reviewer` runs the `production-readiness` checklist over it and owns the final
line. Nothing was tagged, applied, deployed or changed. Evidence below comes from git, `gh` and read-only
`gcloud ... describe/list` calls on 2026-09-30. Where a claim came from the caller and I could not re-verify it, it is
labelled **(reported)**.

Scope: the API (identity changes plus the new `GraphService`) goes to Cloud Run `api` in `dzeroth-prod` as a
`--no-traffic --tag candidate` revision, then 10%, then 100%. The web bundle goes to Firebase Hosting at `stage=100`. The
graph itself stays behind `FEATURE_GRAPH`: prod serves it to **the 2 throwaway smoke accounts smoke-a and smoke-b only** (`allowlist`; updated 2026-09-30, see §4.0 scope statement; older text below that says "founder + 2 smoke" predates it).
The `percent` and `on` stages are T25 and need their own addendum (§4, §7). **No store submission.**

Release candidate: `main` at or after `ee48c19`.
- Last backend change: `c558c9c` (#36, graph log fields).
- Since then: #38 (`859166a`, one test file) and #31 (`d397c70`, Terraform env vars, dev and prod) plus docs.
  `git diff --stat c558c9c ee48c19 -- backend app proto firebase infra Makefile` is 5 files: 4 Terraform env files and
  `mutations_integration_test.go`.
- Diff against v0.1.0: `git diff --stat v0.1.0 ee48c19 -- backend app proto firebase firebase.json infra .github Makefile`
  is 142 files, +18106/-598. That is the whole graph slice, so P0.3 compares against the final release commit instead
  (§5).

Status labels as in v0.1.0: **PASS**, **FAIL** (blocking), **ACCEPTED** (a risk you sign off in §4), **GATED** (checked
after `release-prod` stages the revision; pass/fail gate in §5), **N/A**, **OPEN** (input missing, see §7).
The verdict is the last line of this file and is `PENDING` until the reviewer changes it.

## 1. Inputs
| Input | Status | Evidence |
|---|---|---|
| Plan with cost rows | PASS | `docs/plans/graph.md` (T1–T30, per-RPC budget table, abuse bounds, rollout plan, rollback triggers). Its Follow, Mute and slice-total numbers are superseded by ADR-0008 amendments, noted in the plan |
| ADRs | PASS | `docs/adr/0008-social-graph.md`, Accepted. D1 (private accounts deferred, founder 2026-09-28) and D12 (export contents, founder 2026-09-28). **Amendment 2026-09-30** (#28): A1 Mute checks the target's graph doc exists, A2 cold/warm budgets, A3 `_` reserved in uids. **Amendment 2026-09-30 (2)** (#35): Follow plans at 4 reads, Unfollow logs 1 read, `directory.Forget` kept (founder), with B2 reopen criteria |
| Test report | PASS (caveats) | `docs/reviews/test-report-graph.md` (#34): `VERDICT: PASS`. `make ci` green (Flutter 143 tests), `make test-int` 722 then 723 PASS, `internal/` coverage 89.4% (gate 70%), every measured RPC at or under budget, visibility matrix and invariant sweeps pass. Caveats in §4 (flaky test, no `-race` on Windows, smoke not yet run on cloud) |
| CI on the release commit | PASS at PR head / **GATED at tag** | CI runs on PRs only (`ci.yml` `on: pull_request`). Latest code-bearing PR head: `6a945fe` (#38), run 36673550097, both jobs success. The Linux log shows `go test -race` in **both** `make ci` and `make test-int`, which closes the test report's "no -race" caveat for that head. Run `gh workflow run CI --ref main` on the final release commit (it has `workflow_dispatch`) and record the run ID before tagging |
| Code review | PASS (B2 resolved) | `docs/reviews/graph-code-review.md` (#44), `VERDICT: APPROVE` for `FEATURE_GRAPH=allowlist`, no blocker. S1 (`quotas/{uid}` deletion) and S2 (runbook claim) fixed in #42/#41; S3 and S4 are before T25 `percent` (§4.0). The reviewer did not run `-race` or the emulator integration tests, and nothing was run against dev or prod (per the review) |
| Security review | PASS (conditional, see below) | `docs/reviews/security-review-graph.md` (#24): 0 Critical, 0 High, 4 Medium, 9 Low. Current status in the table below |
| Cost report | PASS | `docs/reviews/cost-report-v0.2.0.md` (#33) and `docs/reviews/cost-model.md`: identity + graph at 300 DAU is 6.1k reads/day (12.2% of quota), 0.93k writes (4.6%), 30 deletes. Emulator load numbers in `docs/reviews/loadtest-graph.md` (#32). Section 3 |
| No unapproved fixed-cost resource | PASS | #31 adds env vars only. Cost report states `cost-guard` clean (0 forbidden resources). `api` stays min 0, max 3, 1 vCPU, 512 Mi, concurrency 80 (checked live on `api-00004-5b2`) |
| Terraform prod | PASS **(reported)** | Prod env-var apply done 2026-09-30: 0 added, 2 changed, 0 destroyed. Consistent with live state: `api-00004-5b2` was created 2026-09-30T06:17:47Z with the graph env vars and `FEATURE_GRAPH=off`. The plan/apply run ID was not supplied |
| Rollback target identified | PASS | `api-00003-tiw` (v0.1.0, image `sha256:74fe11b1...`) is at 100% with the `candidate` tag. Section 6 |
| L9 (v0.1.0): `isPrivate` not enforced | PASS **(reported)** | Code: `UpdateProfile(is_private=true)` is rejected with VALIDATION (T6; `TestT16b` covers it, test report section 6). Prod data: `count(users where isPrivate == true)` = **0**, read-only check 2026-09-30 (reported; not re-run here) |
| Firestore indexes | GATED | All 7 composite indexes READY on prod and dev today. `graph.blockedBy` is index-exempt in `firestore.indexes.json` but the exemption is **not yet on prod** (prod field overrides for `graph`: following, blocked, muted, requested). `release-prod` deploys `firestore:rules,firestore:indexes` before the revision. P2.3 checks it |
| Dev validation | PASS **(reported)** | Dev applied; feature flag `graph=on` (verified: `FEATURE_GRAPH=on` on the live dev revision); T17 smoke passed on dev; T22 deletion drill passed (below). Dev now serves `api-00037-52x` (the one you named, `api-00035-znb`, is older; docs-only merges since redeployed dev). No artifact for the dev smoke run is in the repo, so attach its output at P7 |
| Runbooks | PASS (docs defect fixed) | `account-deletion.md` (#30, drill record #40), `graph.md` (#30, log fields #39), `abuse-spike.md` section 5a (#30), `cost-spike.md`, `rollback.md`. The T27 "self-clean" claim is corrected in `graph.md` (#41) and `account-deletion.md` (#42, lines 85-88); #42 also deletes `quotas/{uid}` (line 79). The drill (#40) did not check `quotas/{uid}`: re-verify on the next drill (§4.0 S1) |
| Feature flags and rollout plan | PASS | Section 5 and 6. Prod default `off` (verified live). Config fails fast on invalid values (`flags.go`) |
| Privacy policy | **OPEN** (B4) | Draft PR #37 (`app/web/privacy.html`) is **not merged and not published**. See §4 R-P1 |
| Mobile | N/A | Web only. `release-prod` still builds AAB/iOS artifacts from the tag; do not distribute (v0.1.0 R-N11) |

### Security findings: status on `origin/main` (verified in code, 2026-09-30)
| ID | Sev | Status | Where (PR) and evidence |
|---|---|---|---|
| M1 page tokens leak hidden uids | Medium | **FIXED** (#27) | `pkg/platform/cursor/cursor.go`: AES-256-GCM, key from HKDF of `CURSOR_HMAC_KEY`, bound to caller/list/target, 24 h TTL (`TTL`). Old tokens are rejected as VALIDATION. `security_fixes_integration_test.go` |
| M2 replay amplification | Medium | **FIXED** (#27) | `apiserver.go`: `graph_mutation_daily` DailyCap on all 6 mutations; `GRAPH_MUTATIONS_PER_DAY` default 500 (also set on prod `api-00004-5b2`) |
| M3 GetProfile serves non-ACTIVE | Medium | **FIXED** (#27) | `identity/service.go`: non-ACTIVE and caller != owner returns the missing-user NOT_FOUND. `identity/security_fixes_test.go` |
| M4 deletion runbook bypasses purge | Medium | **FIXED as a runbook, drilled** (#30, #40) | `account-deletion.md`: Step 0 DELETING + `updatedAt` + 120 s, `opsctl purge-graph`, then delete `users`/`handles`/Auth; `export-graph` in 3a. Drill 2026-09-30 on `dzeroth-dev`: PASS, 3 min 47 s (target < 10 min). Residue check clean except `A.muted[]` still naming the deleted uid (see T27 below) |
| L1 daily caps reset after 24 h | Low | **FIXED** (#27) | `ratelimit/daily_cap.go`: no idle TTL; IST midnight is the only reset |
| L2 Mute accepts nonexistent ids; lazy clean-up | Low | **OPEN** | Decided in ADR A1 (#28). Fix = T26 (Mute existence) and T27 (lazy clean-up); **neither built**. `Mute` in `repo_firestore.go` has no existence check |
| L3 reserved ids `__x__` cause 500s | Low | **FIXED for `__x__`** (#27); `_` rule OPEN | `reservedDocID` in `identity/validate.go`. `userIDRe` is still `^[A-Za-z0-9_-]{1,128}$`. ADR A3 `_` reservation = T28, not built |
| L4 raw uids in ERROR logs | Low | **FIXED** (#27) | `logger.RedactErr` around graph error chains (`follows_list.go`, `lists.go`) |
| L5 Block/purge race leaves dangling entry | Low | **OPEN** | Backlog. Block does not check ACTIVE; Unblock still updates the target graph unconditionally |
| L6 opsctl hardening | Low | **PARTLY** | 6b handled in the runbook (Step 0 sets `updatedAt`). Still open: `--skip-start-gate` needs no extra confirmation, no target banner, no SA-key refusal, dry-run prints `blocked_by` |
| L7 page-size lever for other users' lists | Low | **OPEN** | No `GRAPH_OTHER_LIST_MAX_PAGE_SIZE` in code or Terraform |
| L8 log fields | Low | **PARTLY** (#36, #39) | Emitted on the request line: `graph_op`, `outcome`, `txn_attempts`, `graph_cache_hit`, `edges_removed`, `feature_disabled` (`internal/graph/observe.go`). **Not emitted:** `rows_filtered`, `hydration_misses`, `lazy_removed`, purge fields, and the ErrorReason `reason` on the request line, so `QUOTA_EXCEEDED` is still heuristic |
| L9 (security) Block/Mute behind the Follow flag | Low | **OPEN** | `checkFlag` guards every RPC. Harmless at `allowlist` (testers only) |
| D1 (Unfollow Aborted) | n/a | **FIXED** (#27, #29) | Bounded retry with backoff; exhausted retry is UNAVAILABLE, not INTERNAL (runbook `graph.md` section 3) |
| I1–I9 | Info | Accepted per review | I5 to I8 listed in §4 |

Security verdict in the review: "CONDITIONAL: releasable once M3 and M4 are fixed and the M1/M2 allowlist-stage
acceptances are signed." M1, M2, M3 are now fixed (no acceptance needed). M4 is fixed. The review's own condition for
**`percent`** additionally needs M2, L1, L3 fixed (done for `__x__`) and, from the ADR follow-ups, T26 and T28 (§7).

## 2. Checklist (`production-readiness`)
**Quality: GATED / one OPEN.** `make ci` and `make test-int` are green with `-race` on Linux CI at `6a945fe`. Tag-commit CI
run is required (§5 P0). Code-review record is missing (B2).

**Security: PASS with acceptances in §4.**
- 0 Critical, 0 High open. The four Mediums are fixed (table above).
- `govulncheck ./...` is a step in `ci.yml` (job passed on run 36673550097). `osv-scanner` is not in CI (carried v0.1.0 L6).
- Firestore rules are deny-all and released by `release-prod`. `blockedBy` never appears in a proto field, a response or
  the export (test report section 6: serialized-JSON grep PASS).
- App Check is `monitor` (carried M6). WIF is pinned to repo, `refs/tags/v*`, the two workflows and `environment==prod`.
  No SA keys.

**Cost: PASS.** Section 3. No new fixed-cost resource. Budget alerts (₹500/month per project) unchanged. Caps unchanged:
max 3, min 0, concurrency 80, 512 Mi. New caps are env vars in Terraform: `QUOTA_BLOCKS_PER_DAY` 200,
`QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY` 50, `LIST_CALLS_PER_DAY` 100, `GRAPH_MUTATIONS_PER_DAY` 500,
`RATE_LIMIT_GRAPH_FOLLOW_PER_MIN` 30, `RATE_LIMIT_GRAPH_BLOCK_PER_MIN` 20, `RATE_LIMIT_GRAPH_LIST_PER_MIN` 20,
`RATE_LIMIT_CHECK_HANDLE_PER_MIN` 20 (closes R-N8). Cost impact of these caps: bounded by the cost report's abuse table,
worst case about 1.6k writes/day per abusive account, list scrape up to 61% of the daily read quota, all at the
allowlist stage limited to 3 accounts. Degraded-mode switch was drilled on dev in v0.1.0 (B1); unchanged code path.
Graph mutations are rejected in `readonly` (test report section 6).

**Reliability: GATED.** Indexes and the `candidate` smoke are §5 P2. Data change is expand-only (`blockedBy` missing on
old docs reads as empty; old code ignores it). No backfill. Pub/Sub and DLQ unchanged. Rollback target is the
identical v0.1.0 image (§6).

**Operability: PASS with R-N1 carried.** Error Reporting API is still disabled; the Logs Explorer `severity>=ERROR` query
is the substitute (P2.5, P6). Runbooks exist (see the docs defect in §1). Release notes in §8. Flags default OFF in prod
(verified live: `FEATURE_GRAPH=off`, `FEATURE_GRAPH_ALLOWLIST` empty, `FEATURE_GRAPH_PERCENT=0`). Rollout plan with triggers
is §5 and §6.

**Clients: GATED.** Web only. Graph UI is hidden unless `GetMe.enabled_features` contains `graph` (T12, widget tests). Web
bundle size for the v0.2.0 build has not been measured (plan estimated about +150 KB); check in the `promote-prod`
stage-100 build log (P4). v0.1.0 baseline was about 0.7 MB gzip of own JS.

**Compliance: OPEN.** Delete and export now cover `graph/{uid}`, `follows/*` and the counters through `opsctl`
(runbook, drilled). The one exception is other users' `muted[]` residue (§4 R-2). The privacy policy update is a draft
(R-P1). UGC "block" now exists, which partly closes v0.1.0 R-N12; a report flow does not.

## 3. Cost at the Stage 0 target (identity + graph, from `cost-report-v0.2.0.md`)
| Quota | Per DAU/day | At 300 DAU | % of free | vs the 80% line |
|---|---|---|---|---|
| Firestore reads (50k/day) | 20.4 (identity 7.3 + graph 13.1) | 6.1k | 12.2% | 15.3% of the line |
| Firestore writes (20k/day) | 3.1 | 0.93k | 4.6% | 5.8% |
| Firestore deletes (20k/day) | 0.1 | 30 | 0.15% | 0.2% |
| Cloud Run requests (2M/month, shared) | ~11.3 | ~102k/month plus uptime/CI | ~8% | large |

- Sensitivities all pass: every graph cache cold gives 7.5k reads/day (15%); identity at its documented worst gives 10.0k (20%).
- Follow plans at 4 reads (measured 3.96 to 3.98, emulator k6); Unfollow logs 1; lists 30.5 (midpoint of 20.2 warm and 41 cold).
- Reads run out at about 2,450 DAU for identity + graph. The whole-product model (with unreleased likes, notifications,
  timeline rows) crosses the 80% line at about 210 DAU. That is unchanged by v0.2.0's gate and remains an open finding in
  `cost-model.md` section 3.
- **Not measured:** everything above is emulator-measured or planning values. There are no real cloud p95 or cold-start numbers for v0.2.0;
  P2 and P6 supply the first ones. `cost-model.md` prices are unverified upper bounds (carried R-N6).
- **Stale text:** `cost-model.md` section 9 and `cost-report-v0.2.0.md` "Dashboard notes" say no code emits `graph_op` yet.
  #36 changed that after they were written. Update at T25.
- Launch-burst note: allowlist only, so the plan's 30k-write burst risk does not apply until `percent`.

## 4. Risk acceptances needing human sign-off (sign in §9)

### 4.0 Decision table (production-deployer, 2026-09-30; a recommendation, the founder signs in §9)
Criteria applied exactly as set by the founder: **ACCEPT** only if the risk is clearly understood, bounded, and has a
documented mitigation plus an owner or a follow-up date. Any acceptance involving unresolved privacy, security,
data-loss or uncontrolled production-exposure risk is **DEFER** (not accepted for that scope; work or a trigger is named)
or **REJECT** (not acceptable as an acceptance at all). Where a decision is scoped, the scope is part of the decision.

**Scope statement (binding on every ACCEPT below).** `FEATURE_GRAPH=allowlist` with **only the throwaway smoke accounts
`smoke-a` and `smoke-b`**. No real user, and not the founder's personal prod account, is added to the allowlist until
#37 is merged and published (R-P1). Every "allowlist only" acceptance stops being an acceptance the moment the allowlist
grows or the mode becomes `percent`. T27 (muted[] residue), T26 (Mute existence), T28 (reserved `_` uid) and the code-review
follow-ups S3 and S4 (`docs/reviews/graph-code-review.md`) **block T25 `percent`; they do not block `allowlist` with
trusted smoke accounts.**

Owners: **F** founder, **BE** backend-developer, **PD** production-deployer, **SEC** security-auditor, **ARCH** architect,
**T** tester. Dates are proposed targets unless marked "hard". "Sec-L6" is the security-review opsctl item; "v0.1.0 L6/L7"
are the Dependabot and Actions-pinning items (the letters collide).

| Item | Risk | Decision | Rationale (evidence) | Mitigation | Owner | Follow-up date / trigger |
|---|---|---|---|---|---|---|
| R-1 (T26: Mute has no existence check; sec-L2, ADR-0008 A1) | Junk uids in the caller's own `muted[]`, cap 2,000, about 258 KB per graph doc | **ACCEPT** (allowlist only) | Bounded by the cap and by the caller's own doc; no other user affected. Confirmed unbuilt: `graph-code-review.md` N6 | 2 allowlisted accounts; `graph_mutation_daily` cap 500 (#27) | BE (T26) | Ship before T25 `percent` |
| R-2 (T27: `muted[]`/`blocked[]` residue of a deleted uid in other users' docs) | Right-to-delete gap (CLAUDE.md rule 10): a deleted account's pseudonymous uid persists in others' arrays; confirmed by the drill 2026-09-30 (`account-deletion.md` drill table) | **ACCEPT for smoke-a/smoke-b only, as a BOUNDED TEMPORARY risk (target 2026-10-31, founder-approved 2026-10-01). DEFER for any real user, `percent`, in-app deletion and store submission** | It is a privacy residue, so it cannot be accepted for real users. Smoke data is synthetic and the accounts are deleted after the watch. Condition (b) is **met**: #41 and #42 merged; `account-deletion.md` lines 85-88 now say T27 is not built. Condition (c) is **not met**: privacy draft #37 is unmerged | Runbook wording fixed; smoke accounts interact only with each other; purge per runbook | BE (T27), F (#37 Q3 wording) | **Follow-up date 2026-10-31 (approved, bounded; not an indefinite acceptance).** T27 must ship before `percent`, before in-app deletion and before store submission, and before any real user is allowlisted. Owner: backend-developer, ticket T27 (`docs/plans/graph.md`) |
| R-3 (T28: `_` still a legal uid character; ADR A3, sec-I2) | Edge id `{a}_{b}` collides only for uids containing `_` | **ACCEPT** (allowlist only) | Bounded: Firebase-issued uids do not contain `_` (ADR A3). The one-off `auth:export` count on dev and prod has **not been run: unverified** that no existing uid has `_` | Allowlist is 2 known uids; confirm neither contains `_` when their uids are recorded | BE (T28), PD (count) | Run the count and ship T28 before T25 `percent` |
| R-4a (sec-L5: Block/purge race leaves a dangling `blocked[]` entry) | Dangling uid in an array, never shown | **ACCEPT** | Bounded, same class as R-2 (T27 clears it); purge is founder-run and rare | Runbook Step 0 gate (DELETING + 120 s) | BE | Backlog; fold into T27 |
| R-4b (sec-L6: opsctl `--skip-start-gate` needs no extra confirmation, no target banner, dry-run prints `blocked_by`) | Data-loss risk from a destructive operator tool | **DEFER** | I will not recommend accepting an unhardened destructive path. Bounded to the founder as sole operator, and the runbook's 6b part is handled | Use only on smoke accounts; never pass `--skip-start-gate`; check `--project` before running; keep dry-run output private | BE | Harden before opsctl touches any real user's data or before `percent`. Target 2026-10-31 |
| R-4c (sec-L7: no page-size lever for other users' lists) | During a scraping incident the only lever is a code change plus deploy | **ACCEPT** (allowlist only) | 2 trusted accounts cannot scrape; `LIST_CALLS_PER_DAY` 100 caps reads (`cost-report-v0.2.0.md`) | `LIST_CALLS_PER_DAY`; `FEATURE_GRAPH=off` kill switch | BE | Before T25 `percent` |
| R-5 (sec-L8 partly open: no `reason`, `rows_filtered`, `hydration_misses`, purge fields) | Monitoring blind spots; `QUOTA_EXCEEDED` found by heuristic query | **ACCEPT** (allowlist only) | Documented: `internal/graph/observe.go` emits `graph_op`, `outcome`, `txn_attempts`, `graph_cache_hit`, `edges_removed`, `feature_disabled`; heuristic query in §5 P6 | Heuristic query; 2-account volume | BE | Before T25 `percent` |
| R-6 (sec-L9: Block/Mute behind the Follow flag) | A flag-on user could follow a flag-off user who cannot block | **ACCEPT at allowlist. REJECT for `percent`** | With a 2-smoke allowlist no real user is reachable (`checkFlag` on every RPC). At `percent` it is uncontrolled exposure of real users | Allowlist scope | BE, ARCH (decide) | Decide and fix before T25 `percent` |
| R-7 (ADR D9 residual: `CheckHandleAvailability` "taken" vs `GetProfile` NOT_FOUND) | A block can be inferred by probing | **ACCEPT for allowlist. DEFER for real users** | Review recommends ACCEPT on condition M3 is fixed; it is (#27, `identity/service.go:188-190` per the code review). It is a privacy inference, so real-user acceptance waits on #37 Q4 and copy that never promises a block is secret | M3 fix; ADR-0008 D9 | F (#37 Q4), ARCH | Before any real user is allowlisted |
| R-8 (D8 staleness, D2 overflow, I5, I6, I7, I8) | D8 up to 60 s cache staleness (Follow reads fresh in its txn); D2 needs 10,000 blockers of one account; I5 export lists own blocked entries; I6 mutual block has no UI unblock path; I7 Follow NOT_FOUND timing; I8 blocker's last-seen profile stays in the blocked user's local cache | **ACCEPT** (allowlist only) | Each is bounded and documented in `security-review-graph.md`; fail-closed paths tested (`test-report-graph.md`). I8 is a small privacy leak to the blocked user's own device; with 2 smoke accounts there is no third party | Allowlist scope | SEC | Re-review I5, I6, I8 before any real user or `percent` |
| R-9 (test caveats: flaky `TestT16a`, one post-fix CI pass; remote smoke never run on prod; no Flutter integration harness; Windows `Makefile FIREBASE :=`) | Residual test weakness; code review S3 adds that #38 weakened the race test so it can pass without exercising concurrency | **ACCEPT** (allowlist only); **S3 blocks `percent`** | Understood: `graph-code-review.md` S3; CI run 36673550097 passed once after #38. The prod smoke (P2.5) is the compensating check. The Makefile defect is local only | P2.5 smoke with invariant checks | T (S3) | S3 before T25 `percent` |
| R-10 (Follow costs 4 reads, not 3; `directory.Forget` kept) | About +1.1 reads/DAU | **ACCEPT** | Cost only and bounded; ADR-0008 amendment 2 (#35), founder decision; 12.2% of read quota at 300 DAU (`cost-report-v0.2.0.md`) | ADR reopen criteria B2 | ARCH | Reopen on B2 criteria only |
| S1 (code review: `quotas/{uid}` had no deletion path) | Right-to-delete gap for the quota doc | **ACCEPT as covered by the runbook, with re-verification pending** | Runbook fixed in #42: `account-deletion.md` line 79 deletes `quotas/$UID_`. **Not yet proven by a drill:** the T22 drill (#40) did not check it (drill table says so). Treat as unverified until then | Step 2 deletes it | PD, SEC | **Re-verify on the next deletion drill and in the smoke-account cleanup (P2.9 and when smoke-a/smoke-b are deleted).** ADR-0003 delete-path note still open (ARCH) |
| S2 (code review: runbook claimed a T27 clean-up) | Wrong operator guidance | **RESOLVED** | #41 (`graph.md`) and #42 (`account-deletion.md`) are merged on main | n/a | PD | Closed; the residual is R-2 |
| S3, S4 (code-review follow-ups) | S3: weak race test. S4: Unfollow retry has no jitter and a cancelled context maps to INTERNAL plus an ERROR line | **DEFER** (not an acceptance) | `graph-code-review.md`: "before T25 `percent`"; APPROVE for `allowlist` with no blocker | Small blast radius at 2 accounts | T (S3), BE (S4) | Before T25 `percent` |
| R-P1 (privacy policy #37 unpublished) | Live `/privacy` does not describe the graph: unresolved privacy exposure | **DEFER / REJECT for any real user until #37 is resolved and published. ACCEPT only for smoke-a/smoke-b, and it must stay so** | #37 is OPEN (`gh pr view 37`, 2026-09-30) with its questions unanswered. Smoke accounts are throwaway and interact only with each other, so no third party's data is processed | Allowlist = smoke-a + smoke-b only. Founder's personal account is not allowlisted. No one else is added | F (answer Q1-Q7, merge), PD (Hosting deploy) | Hard gate: #37 merged and published before any real user is allowlisted or `percent`. No date: founder decision |
| R-P2 (candidate staged with the wrong flag) | Candidate would run `off`, smoke cannot pass | **RESOLVED (option 1). Reported, unverified by me** | Reported by the caller: prod Terraform now has `FEATURE_GRAPH=allowlist` with only smoke-a and smoke-b, revision `api-00005-9df` at 0% traffic, applied 2026-09-30; `api-00003-tiw` still serves 100%. I did not re-check live (no cloud access in this task), and the tfvars carrying the allowlist are not in the repo (`infra/terraform/envs/prod` has only the variable definitions) | Verify at P2.2 (traffic) and P2.7 (`feature_flags` startup log shows `allowlist`) | PD | At P2 after tagging; record the real revision |
| R-P3 (`promote-prod` run is the approval; no second reviewer on GitHub Free) | Anyone with push access can tag and promote | **ACCEPT** | Bounded: single collaborator, WIF pinned to repo, tag pattern, two workflow files, environment `prod` (`release-rollout` skill). Depends on the two 2FA confirmations in §9 | 2FA; `VERDICT: GO` file check in the workflow | F | Revisit with an ADR before a second collaborator is added |
| R-P4 (rollback to v0.1.0 code re-opens block hiding and `is_private`) | Old code ignores blocks in `GetProfile` and accepts `is_private=true` again (unenforced privacy) | **ACCEPT** (allowlist only) | Only 2 smoke accounts have graph data; prod `isPrivate==true` count 0 (reported, not re-run) | §6 order: flag off before traffic rollback | PD | If a rollback ever happens with real users on the flag, treat as DEFER and re-check the `isPrivate` count |
| v0.1.0 M4 (tf-plan `roles/viewer`; WIF pinned to repo only) | Read access by a plan identity | **ACCEPT** | Carried; single collaborator | Documented in v0.1.0 §4 | F | Expires when a second collaborator is added |
| v0.1.0 M6 (App Check monitor-only) | Scripted abuse of the API is not blocked | **ACCEPT for allowlist. DEFER for `percent`** | Compensating controls in `release-v0.1.0-readiness.md` §4 plus new graph caps; the graph is invisible to non-allowlisted users. At `percent` it is uncontrolled exposure | Per-user quotas, rate limits, max 3 instances | SEC, PD | Decide App Check enforcement before T25 `percent` |
| v0.1.0 L1 (default Compute SA has Editor) | Standing over-privileged identity | **DEFER** | Nothing runs as it (v0.1.0 §4), but removal was promised for "the next infra PR" and I cannot verify it happened: unverified | Nothing runs as it | PD | Remove the role in the next infra PR (needs founder OK); target 2026-10-12 |
| v0.1.0 L2, L3 (`ci-deploy` `firebase.viewer`; CSP Report-Only) | Narrow read role; CSP not enforced | **ACCEPT** | L2 is mintable only by the pinned workflows at `v*` tags in `prod`; L3 has other headers in place (v0.1.0 §4) | As stated | PD | Enforce CSP before `percent` (proposed) |
| v0.1.0 L8 (no password policy, MFA off) | Account takeover | **ACCEPT only with the two 2FA confirmations in §9; otherwise REJECT** | Condition carried from v0.1.0; the confirmations are unchecked | Founder 2FA on GitHub and the Owner Google account | F | Confirm at sign-off |
| v0.1.0 L6 (Dependabot off, no osv-scanner) | Unpatched dependencies, no automated scan | **REJECTED as an acceptance. Not renewed. PARTIALLY CLOSED 2026-10-01** | The v0.1.0 acceptance expires **2026-10-12** and must not be renewed. Dependabot is done (#45, `.github/dependabot.yml`). Remaining: pin `govulncheck`, `firebase-tools`, `ko` and `gcloud` to exact versions; add `osv-scanner`; enable the repo setting "require full-length SHA pinning" | Remaining work tracked in issue #46; `govulncheck` in `ci.yml` meanwhile | PD | **HARD deadline 2026-10-12, not renewed** (issue #46) |
| v0.1.0 L7 (Actions pinned by tag, not SHA) | Supply-chain risk in CI that holds prod WIF | **CLOSED by #45 (2026-10-01)** | All GitHub Actions are SHA-pinned (#45 merged). `deploy-dev` passed on the pinned workflows (run 36682278696, main `71972bf`). **`release-prod` and `promote-prod` pinned paths are untested until the tag** | WIF pin to repo, tag ref, workflow file and environment | PD | Verify at the tag (P2, P3); the remaining hardening is under L6 / issue #46 |
| R-N1 (Error Reporting API disabled) | Errors visible only via a Logs Explorer query | **ACCEPT** | Substitute query in §5 P2.8 and P6; 0 cost | Manual watch | PD | Enable the API before `percent` (needs founder OK) |
| R-N3 (5xx alert is a fixed rate; `/health` touches neither Firestore nor Auth) | Silent partial outage | **ACCEPT** | Covered by the manual 7-day watch (§5 P6) | Manual watch, uptime check | SEC, PD | Revisit at `percent` |
| R-N5, R-N7, R-N9 (`/` cache rule; pubspec `1.0.0+1`; prod Identity Platform config not in Terraform) | Cosmetic or config drift | **ACCEPT** | Bounded, documented in v0.1.0 §4 | Admin-API changes documented | PD | N9 with the next infra PR |
| R-N11 (mobile artifacts use dev's Android config) | Wrong Firebase project in mobile builds | **ACCEPT with a hard condition** | Web-only release; no store submission | Do not distribute the AAB/iOS artifacts | F | Before any store submission |
| R-N12 (UGC: block exists, no report tool) | Store-policy and abuse-handling gap | **ACCEPT for allowlist. DEFER for real users and store submission** | No UGC beyond profile text in v0.2.0 and 2 accounts | Allowlist scope | BE, frontend | Before any store submission or `percent` |

The founder signs in §9; the boxes there stay unchecked. Nothing in this table is a GO.

### 4.2 Founder decisions recorded 2026-09-30 / 2026-10-01
Recorded by the production-deployer at the founder's instruction. These are decisions, not sign-offs: the §9 boxes stay
unchecked and only the `production-reviewer` may change the verdict line.

1. **Release decisions (approved).**
   - Prod Terraform apply is done (2026-09-30): `FEATURE_GRAPH=allowlist` for smoke-a and smoke-b only; revision `api-00005-9df` at 0% traffic; `api-00003-tiw` serves 100% (reported, not re-verified here; verify at P2.2 and P2.7).
   - Tagging `v0.2.0` is **approved in principle but BLOCKED** until (a) both 2FA confirmations in §9 are completed by the designated human reviewers and (b) the `production-reviewer` has written the verdict. Once both confirmations are done, the production-reviewer issues the final verdict.
   - `promote-prod.yml` requires an exact line `VERDICT: GO` (`grep -qx`) in this file at the tagged commit. Therefore the tag must be pushed **only after the verdict is recorded on `main`**. Tagging first would make promotion fail.
   - 2FA confirmations: PENDING - to be completed by the designated human reviewers (not by the assistant).
2. **Privacy #37 blocks ANY real-user allowlisting.** smoke-a and smoke-b remain the only allowlisted accounts. The allowlist must not expand until the outstanding privacy decisions (#37 Q1 to Q7) are resolved and the published policy matches the implementation.
3. **Dependabot PRs #47 to #55 (and any new routine ones) are HELD until after v0.2.0.** Not merged during the release window. A security triage of them is in progress for critical/high or release-blocking issues; escalate immediately if any is found. Triage result: **pending**. The pinned Actions from #45 are merged and `deploy-dev` passed on them (run 36682278696, main `71972bf`). The `release-prod` and `promote-prod` pinned paths are **untested until the tag**.
4. **T27 (lazy `muted[]` clean-up), target 2026-10-31: APPROVED as a BOUNDED TEMPORARY risk**, not an indefinite acceptance. Owner backend-developer (ticket T27), follow-up date 2026-10-31. R-2 remains ACCEPT for smoke accounts only. T27 must ship before `percent`, before in-app deletion and before store submission. `percent` rollout stays **BLOCKED** on T26, T27, T28, S3 and S4.
5. **L6 remaining work** is tracked in issue #46 with a **HARD deadline of 2026-10-12, not renewed**. L6 is partially closed (Dependabot done in #45). Remaining: pin govulncheck, firebase-tools, ko and gcloud to exact versions; add osv-scanner; enable the repo setting "require full-length SHA pinning". L7 is closed by #45.

### 4.1 Background detail
The founder accepts or rejects each item. "Expires" says when it stops being acceptable. Items marked *Recommend reject*
are the ones I would not sign without a fix. Where this detail and the table in 4.0 differ, the table wins.

**Graph-specific**
- **R-1 — T26 not built: Mute does not check the target exists (security L2, ADR A1).** Accepts: junk uids (up to 128
  chars) in the caller's own `muted[]`, cap 2,000, about 258 KB worst case per graph doc. Reachable only by the 3
  allowlisted accounts. **Expires:** blocks T25 `percent`.
- **R-2 — T27 not built: other users' `muted[]` (and dangling `blocked[]`) keep the uid of a deleted account.** The drill
  confirmed the residue (`A.muted[]` still named C). It is a pseudonymous uid, not an email or handle, and is never shown.
  The runbooks (`graph.md` section 4, `account-deletion.md` lines 84-86, and privacy draft #37) currently *say the opposite
  or promise a clean-up*. Accepting means: (a) you accept the residue for now, (b) you approve merging #41 and fixing the
  `account-deletion.md` wording, (c) the privacy wording matches. **Expires:** blocks the account-lifecycle (in-app
  deletion) plan and any store submission; not a `percent` blocker. *Recommend accept with (b) and (c) as conditions.*
- **R-3 — T28 not built: `_` is still a legal uid character (ADR A3, security I2).** Edge ids `{a}_{b}` could collide only for
  uids containing `_`. Firebase-issued uids never contain `_`. The one-off `firebase auth:export` count on dev and prod
  (expected 0) is part of T28 and has **not** been run. **Expires:** blocks `percent`.
- **R-4 — Security L5, L6 (except 6b), L7 open.** L5 dangling `blocked[]` after a purge race; L6 opsctl gate bypass without a
  second confirmation and no target banner (founder-only tool); L7 no page-size lever for other users' lists (a
  code change plus deploy instead of an env update during a scraping incident). **Expires:** L7 before `percent`; L5, L6
  backlog.
- **R-5 — Security L8 partly open.** No `reason` on the request line, and no `rows_filtered`, `hydration_misses`,
  `lazy_removed` or purge fields (log fields shipped in #36: `graph_op`, `outcome`, `txn_attempts`, `graph_cache_hit`,
  `edges_removed`, `feature_disabled`). Consequence: `QUOTA_EXCEEDED` spikes are found by the heuristic query in §5 P6, and hydration and filter
  cost cannot be split out per RPC. **Expires:** before `percent` (rollout monitoring uses `feature_disabled` and `outcome`, which exist).
- **R-6 — Security L9: Block, Unblock, Mute, Unmute are behind the same flag as Follow.** At `allowlist` no other user can
  reach a tester, so no one is followed without a way to block. **Expires:** the first `percent` stage (a flag-on user could follow a flag-off user
  who cannot block). *Recommend fixing before `percent`, not before v0.2.0.*
- **R-7 — ADR-0008 D9 residual: `CheckHandleAvailability` says "taken" while `GetProfile` says NOT_FOUND.** The security
  review recommends ACCEPT on condition that M3 is fixed (**it is**) and that product copy never promises a block is secret.
  The privacy draft (#37, Q4) touches this. Already recorded in ADR-0008 D9; the review asks for it in this section too.
- **R-8 — Accepted residuals from the review:** D8 staleness (up to 60 s on other instances; Follow reads fresh in its
  transaction so no edge can be created), D2 overflow (needs 10,000 blockers of one account; fail-closed paths tested),
  I5 (export lists the subject's own blocked entries), I6 (mutual block leaves no UI path to unblock), I7 (Follow NOT_FOUND
  timing), I8 (blocker's last-seen profile stays in the blocked user's local cache until sign-out).
- **R-9 — Test caveats.**
  - `TestT16a_Race_ConcurrentDuplicateBlocksAndMutes` was flaky on the emulator (roughly 1 in 10 to 20 before de-flake).
    PR #38 (`6a945fe`, "realistic contention and sequential replay") changed the test; CI run 36673550097 passed once after
    it. There is no larger post-fix sample.
  - CI run `f9ae82e` (an earlier de-flake attempt) failed, before #38.
  - The remote-mode graph smoke has never run against a cloud URL except on dev (reported). Its first prod run is P2.
  - Flutter: no golden or `integration_test` harness (outside T17).
  - Test-report D-T17-2 (`Makefile` `FIREBASE :=` on Windows) is unfixed. It affects local runs only.
- **R-10 — Follow costs 4 reads, not the plan's 3 (ADR amendment 2), because `directory.Forget` is kept (founder decision).**
  Cost, about 1.1 reads/DAU. Reopens on the B2 criteria only.

**Process and release**
- **R-P1 — Privacy policy update (#37) is a draft, unpublished.** Prod's live `/privacy` does not describe the graph.
  Allowlist is smoke-a and smoke-b only (the earlier "founder + 2 smoke" wording is superseded), so no third party's data is processed *as long as they only follow and block
  each other*. **Condition to accept:** during `allowlist` the three accounts interact only with one another, and #37 is merged and
  published (Hosting deploy) **before any real user is added to the allowlist and before `percent`**. Open questions in #37
  (Q1 Draft marker and timing, Q2 runbook now fixed, Q3 muted residue wording, Q4 block-inference sentence, Q5 timestamps,
  Q7 logged-out visibility) need your answers. Alternative: merge #37 before tagging so `stage=100` ships it with the
  web bundle; that describes a feature that only 3 accounts can use.
- **R-P2 — Candidate is staged with the wrong flag unless you choose a procedure (B1).** Plan says `candidate` runs
  `FEATURE_GRAPH=allowlist`. `release-prod.yml` runs `gcloud run deploy --image ... --no-traffic --tag=candidate` with no env
  flags, so the new revision **inherits the service template env**, which today is `FEATURE_GRAPH=off`, empty allowlist. Two ways
  to get allowlist on the candidate; both need your OK:
  1. *(recommended)* Before tagging, create the smoke accounts, then apply the prod Terraform variables
     `feature_graph = "allowlist"` and `feature_graph_allowlist = "<uid1>,<uid2>,<uid3>"` (plan first, then OK). This creates a
     template revision that gets no traffic (traffic and image are `ignore_changes`; `api-00003-tiw` keeps 100%). `release-prod`
     then inherits it. Terraform stays the source of truth, so no drift.
  2. After `release-prod`, run the drilled pinned-traffic update on the `candidate` revision with
     `--update-env-vars FEATURE_GRAPH=allowlist,FEATURE_GRAPH_ALLOWLIST=...`, keeping the tag, then reconcile Terraform later.
     This creates a second revision behind the tag (same image), and `promote-prod` still passes its image-tag check,
     but Terraform will show drift until reconciled.
  Also decide who is the third allowlisted uid: the founder's existing prod account.
- **R-P3 — `promote-prod` is the approval.** No second reviewer on GitHub Free (carried from v0.1.0). Unchanged.
- **R-P4 — Rolling back to v0.1.0 code re-opens two gaps for graph data that already exists:** `GetProfile` no longer
  applies block hiding (old code has no `BlockChecker`), and `UpdateProfile(is_private=true)` is accepted again. Data is
  untouched, and at `allowlist` only 3 accounts have graph data. Turn the flag off first (§6).

**Carried from v0.1.0 (§4 there), still open**
- **M4 (tf-plan `roles/viewer`, WIF pinned to repo only)** expires when a second collaborator is added.
- **M6 App Check monitor-only** with the compensating controls listed in v0.1.0 §4. The graph adds its own caps, listed in §2 Cost.
- **L1, L2, L3, L8** (default Compute SA Editor; `ci-deploy` `firebase.viewer`; CSP Report-Only; no password policy and MFA off).
  L8's condition is the two 2FA confirmations in §9.
- **L6 (Dependabot off, no osv-scanner) and L7 (Actions pinned by tag)** were accepted for 2 weeks after launch. Launch was
  2026-09-28, so **they expire 2026-10-12**. Update 2026-10-01: L7 is closed and Dependabot is done (#45); the rest of L6 is issue #46, hard deadline 2026-10-12 (§4.2 item 5).
- **R-N1** Error Reporting API disabled (Logs Explorer substitute). **R-N3** 5xx alert is a fixed rate and `/health` touches
  neither Firestore nor Auth. **R-N5** `/` cache rule. **R-N7** `app/pubspec.yaml` is still `1.0.0+1` (cosmetic).
  **R-N9** prod Identity Platform config is not in Terraform. **R-N11** mobile artifacts use dev's Android config. **R-N12**
  UGC: block exists now, no report tool.
- **v0.1.0 L9 is closed by this release** (reject + 0 private users), not carried.

## 5. Promotion procedure (any failed gate means stop and roll back per §6)
**P0 — before tagging**
1. Close B1 to B4 in §7. Sign §9 (both 2FA confirmations by the designated human reviewers). The reviewer changes the last line to `VERDICT: GO`. **Ordering (founder decision 2026-10-01):** `promote-prod.yml` requires an exact `VERDICT: GO` line at the tagged commit, so the verdict must be recorded on `main` **before** `v0.2.0` is pushed (steps 2 to 6 below).
2. Merge #41 (docs), decide #37 (R-P1), and merge the reviewer's GO PR.
3. Create the 2 prod smoke accounts (verified email; step P2.4a). Record their uids. Apply the allowlist (R-P2 option 1).
4. Run `gh workflow run CI --ref main` on the final commit and record the run ID (all jobs green).
5. `git diff --stat ee48c19 <tag-commit> -- backend app proto firebase firebase.json infra Makefile` must show only what you approved (today: nothing beyond the 5 files listed at the top, which are already in `ee48c19`).
6. `git tag v0.2.0 <tag-commit> && git push origin v0.2.0`. This triggers `release-prod.yml`.

**P2 — after `release-prod`'s `build-and-stage` succeeds** (candidate URL from the run log; v0.1.0's was
`https://candidate---api-jgr3aiensq-el.a.run.app`)
1. Record the run URL, the image digest (`ko` output) and the candidate revision name for the P7 addendum. Expect the
   next revision name after `api-00004-5b2`.
2. Traffic: `gcloud run services describe api --project=dzeroth-prod --region=asia-south1 --format='yaml(status.traffic)'`
   shows `api-00003-tiw` at 100% and the new revision at 0% with tag `candidate`. (Before the release, `candidate` points at
   `api-00003-tiw`; it moves at deploy.)
3. Indexes and rules: 7 composite indexes `READY` (`gcloud firestore indexes composite list --project=dzeroth-prod`), and
   `gcloud firestore indexes fields list --project=dzeroth-prod --filter="name~graph"` shows 5 overrides including `blockedBy` (0 indexes).
4. Identity checks on the candidate URL (same as v0.1.0):
   - a. `/health` 200 `ok`, cold start under 1.5 s.
   - b. Unauthenticated GetMe returns 401.
   - c. Sign-in with the prod **web** key. **The key is referrer-restricted** (found on dev; prod's allows
     `https://dzeroth.com/`), so REST sign-in needs a Referer header:
     ```bash
     curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=$WEB_KEY" \
       -H 'Content-Type: application/json' -H 'Referer: https://dzeroth.com/' \
       -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\",\"returnSecureToken\":true}"    # -> idToken (do not echo it)
     ```
   - d. A **new** unverified account: GetMe returns PROFILE_REQUIRED; CheckHandleAvailability ok; CreateProfile returns
     EMAIL_NOT_VERIFIED. Delete it afterwards.
   - e. The verification email comes from noreply@dzeroth.com and passes DKIM/DMARC.
5. Graph smoke on the candidate with **allowlisted** accounts A and B (both need verified emails and profiles; set
   `emailVerified` through the Identity Toolkit admin API with the founder's login, as in the deletion runbook's REST style, or
   verify from the emailed link):
   ```bash
   cd backend
   E2E_GRAPH_BASE_URL="<candidate url>" E2E_GRAPH_ID_TOKEN_A="$TOK_A" E2E_GRAPH_ID_TOKEN_B="$TOK_B" \
     GOWORK=off go test -tags=integration -count=1 -run TestE2E_GraphSmoke_FollowListBlockUnblock ./e2e/
   ```
   Base URL is the direct Cloud Run candidate URL, with no `/api` prefix (that prefix exists only behind Hosting). Tokens
   last 1 h. Remote mode resolves uid and handle from GetMe and polls up to 90 s for the 60 s graph cache on a peer
   instance. About 17 requests, 15 reads, 12 writes. It cleans up (Unblock, Unfollow with fresh keys) and is re-runnable.
   Expected: PASS.
6. Non-allowlisted account C (verified email and a profile; without a profile the call stops at PROFILE_REQUIRED before the
   flag check): call `GraphService/GetRelationships`, `Follow` and `ListFollowers` on the candidate. Each must return
   FAILED_PRECONDITION with reason `ERROR_REASON_FEATURE_DISABLED` and log `feature_disabled=true`, 0 reads.
   `IdentityService/GetMe` for C must not list `graph` in `enabled_features`; for A and B it must.
7. Startup log on the candidate shows `feature_flags` with graph mode `allowlist` (`jsonPayload.message="feature_flags"`).
8. Logs Explorer for the candidate revision, from the deploy time: 0 entries with `severity>=ERROR`, 0 with
   `httpRequest.status>=500`:
   ```
   resource.type="cloud_run_revision" AND resource.labels.service_name="api"
   AND resource.labels.revision_name="<candidate>" AND (severity>=ERROR OR httpRequest.status>=500)
   ```
   Expected WARNINGs: Cloud Run request logs for the deliberate 4xx calls only.
9. Clean up smoke state: `opsctl purge-graph` (Step 0 gate applies) and the deletion runbook for the throwaway account C;
   keep A and B for P6 and delete them after the 24 h watch.

**P3 — `promote-prod.yml` stage=10** (run from the `v0.2.0` tag ref). Watch 15 minutes. Uptime green, P2.8 stays 0, warm p95 not over
twice baseline. Re-run P2.5 once against the 10% traffic (the main URL) to confirm both revisions behave.

**P4 — `promote-prod.yml` stage=100** (**ask the founder first**). Builds web from the tag, shifts to 100%, `/health`, deploys Hosting. Record the web bundle size from the build log (target < 3 MB;
v0.1.0 about 0.7 MB gzip own JS). After it: `api-<new>` at 100%, `api-00003-tiw` still present (rollback target).

**P5 — smoke `https://dzeroth.com` in a clean browser profile**
1. Page loads, `/privacy` 200, www 301 to apex, `/api/health` 200. Whether `/privacy` shows the new text depends on R-P1.
2. Sign in as a non-allowlisted account: **no** graph UI anywhere (no Follow button, no followers/following links, no
   "Blocked accounts" or "Muted accounts" in Settings). Direct navigation to `/settings/blocked` redirects to `/settings`.
3. Sign in as allowlisted A: Follow/Following, block and mute menu, followers/following list, Settings entries all appear.
4. Email sign-up and Google sign-in still work (regression of v0.1.0 P5).
5. Prod logs show `via_hosting=true`, `xff_hops=2`, 0 errors. Security headers present.

**P6 — watch at +1 h, +24 h, then daily for 7 days** (plus the v0.1.0 items: budget emails, uptime check, `daily-maintenance`).
Base filter: `B = resource.type="cloud_run_revision" AND resource.labels.service_name="api"`.
- Errors and 5xx: `B AND severity>=ERROR` expect 0; `B AND httpRequest.status>=500` expect 0. Use `--freshness=1h` / `24h` with
  `gcloud logging read '<filter>' --project=dzeroth-prod`.
- **Graph reads and writes by operation** (works without Log Analytics; counts and sums over the window):
  ```bash
  gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND jsonPayload.graph_op:*' \
    --project=dzeroth-prod --freshness=24h --format=json |
  jq 'group_by(.jsonPayload.graph_op) | map({graph_op: .[0].jsonPayload.graph_op, calls: length,
      fs_reads: (map(.jsonPayload.fs_reads // 0) | add), fs_writes: (map(.jsonPayload.fs_writes // 0) | add),
      fs_deletes: (map(.jsonPayload.fs_deletes // 0) | add)})'
  ```
  Logs Explorer form: `B AND jsonPayload.graph_op!=""`, then group by `graph_op`. Compare with the budget: Follow at most 4 R / 5 W, Unfollow 3 W / 1 D,
  Block 3 R / 5 W / 2 D, lists at most 102 R. Expect a handful of calls only (3 accounts).
- **`feature_disabled` count:** `B AND jsonPayload.feature_disabled=true`. Expect only the smoke account C's calls. Anything else means
  a real client is calling graph RPCs while the flag is off for it (UI leak). Cross-check `jsonPayload.outcome="rejected:feature_disabled"`.
- Contention and rejections: `B AND jsonPayload.message="graph_txn_contention"`; `B AND jsonPayload.code="unavailable" AND jsonPayload.rpc:"GraphService/"`;
  `B AND jsonPayload.limit_name="graph_list_daily"`; `B AND jsonPayload.limit_name="graph_mutation_daily"`;
  `B AND jsonPayload.message="blockedby_cap_reached"` (must be 0).
- `QUOTA_EXCEEDED` (heuristic, R-5): `B AND jsonPayload.code="resource_exhausted" AND jsonPayload.fs_reads>0 AND NOT jsonPayload.limit_name:*`.
- Firestore usage (console, Usage tab): under 2k reads/day and under 1k writes/day at launch; instances not pinned at 3; the
  `Firestore reads > 40k` alert quiet.
- Latency: request-log `latency_ms` for `GraphService` and for `GetMe`/`GetProfile` (baselines from v0.1.0: GetMe 270 ms, CheckHandleAvailability 85 ms, CreateProfile 500 ms; graph
  targets from the plan: Follow < 500 ms, GetRelationships < 150 ms, lists < 400 ms). There is no cloud baseline for graph
  RPCs yet; P2 and the first watch create it.
- Record: results at +1 h and +24 h go into `docs/reviews/release-v0.2.0-postrelease.md` (P7).

**P7 — addendum.** Commit `docs/reviews/release-v0.2.0-postrelease.md`: digest, run IDs (release-prod, both promotes, CI on the tag commit), candidate
revision, the dev smoke output, P2 to P6 results, and the allowlist procedure used (R-P2).

## 6. Rollback triggers and plan
**Rollback target: `api-00003-tiw`** (v0.1.0). Serving at 100% now, tag `candidate`, image
`asia-south1-docker.pkg.dev/dzeroth-prod/api/api@sha256:74fe11b1e1ccb673cc994580c90c7cafa2d19af8ce7005891c3a4bf567f66270`,
created 2026-09-28T03:40:50Z. `api-00004-5b2` (created 2026-09-30T06:17:47Z by the Terraform env-var apply) has the graph env vars and
`FEATURE_GRAPH=off` with the **same image**; it is `Retired` (no traffic, not the rollback target). Record the real target
again at P2.2, because a new revision may have been created by R-P2 option 1 before the tag.

**Triggers (any one):**
- P2 or P5 failure; any 5xx on smoke calls; a 5xx ratio over 2% with at least 50 requests in any 15-minute window;
- warm p95 over twice the dev baseline on any graph RPC or on GetProfile/GetMe, or cold start over 3 s;
- any `severity>=ERROR` you can't explain;
- Firestore over 15k reads/day or 5k writes/day in week 1 (plan) — the v0.1.0 stricter figure is 10k reads/day, use the lower until 100 real users exist;
- over 20 `QUOTA_EXCEEDED quota=follows` per day, or `graph_list_daily` rejections from more than 3 uids (abuse: `abuse-spike.md` 5a);
- a counter/edge invariant violation found by the smoke test;
- `feature_disabled=true` from a uid that is not the smoke account (UI leak);
- any budget alert or the uptime alert.

**Actions, lightest first** (each is instant except the env update, which needs the pinned-traffic procedure of `cost-spike.md`):
1. **Graph problem only:** `FEATURE_GRAPH=off` (pinned-traffic env update, then reconcile Terraform). Data stays; `blockedBy` is expand-only and older code ignores it.
2. Tighten quotas or caps by env (`QUOTA_FOLLOWS_PER_DAY`, `LIST_CALLS_PER_DAY`, ...).
3. **Before 100% traffic:** `gcloud run services update-traffic api --project=dzeroth-prod --region=asia-south1 --to-revisions=api-00003-tiw=100`. Do not run stage 100.
4. **After 100%:** the same command (seconds). Then Hosting: web is one release back, so `firebase hosting:clone` from the v0.1.0 release (or the console's previous release); v0.1.0's web has no graph UI, so a flag
   flip is enough if the API is healthy. Always `--to-revisions`, never `--to-latest`.
5. `DEGRADED_MODE=readonly` with the pinned-traffic procedure for abuse or cost.
6. Severe incident: `firebase hosting:disable --project dzeroth-prod`, then route the API to the previous revision. Never detach billing without your explicit decision.

Firestore rules and indexes: the new `blockedBy` exemption and unchanged composite indexes need no rollback. See R-P4 for what rolling back to v0.1.0 code loses.

## 7. Blocking items (for the reviewer and the founder)
Status as of 2026-09-30 after merging `origin/main` (`5df9305`).
- **B1 — Candidate flag procedure (R-P2): RESOLVED (reported).** Option 1 done: prod Terraform has `FEATURE_GRAPH=allowlist` with only smoke-a and smoke-b (no founder personal account, no real user); revision `api-00005-9df` at 0% traffic, applied 2026-09-30; `api-00003-tiw` serves 100%. Evidence is the caller's report only: I made no cloud calls, and the tfvars are not in the repo. Verify at P2.2 and P2.7. The plan/apply run ID is still not recorded.
- **B2 — Code review record: RESOLVED.** `docs/reviews/graph-code-review.md` (#44): APPROVE, 0 blockers, S1 and S2 fixed (#42, #41). S3 and S4 open, before `percent` only.
- **B3 — Prod smoke accounts: partly resolved, unverified.** The allowlist names smoke-a and smoke-b (reported), so the accounts exist or their uids are known. Still to confirm at P2.5: verified emails and profiles, a non-allowlisted account C, and that neither uid contains `_` (R-3). Their uids may be recorded in this document.
- **B4 — Privacy policy #37 (R-P1): OPEN. Waiver REJECTED by the founder (chat, 2026-09-30).** #37 is still OPEN. The proposed waiver ("B4 is not a blocker for `allowlist` with only the two smoke accounts") was rejected. B4 stays a blocker for real-user allowlisting and `percent`. The two existing smoke accounts (smoke-a, smoke-b) may remain allowlisted for controlled testing; the founder said this must not be treated as a waiver of the privacy requirement. Founder answers Q1-Q7 and the legal items in #37 remain outstanding.
- **B5 — Docs defect (R-2): RESOLVED.** #41 and #42 merged; `account-deletion.md` lines 85-88 now say the residue persists until T27.
- **New — B6 — Founder sign-off and both 2FA confirmations (§9) are unchecked: OPEN.** PENDING - to be completed by the designated human reviewers (not by the assistant). Needed before the reviewer can write GO; tagging `v0.2.0` is BLOCKED on it (§4.2).
- **New — B7 — CI run on the tag commit** (`gh workflow run CI --ref main`) not yet run (§5 P0.4). GATED.
- **Blocks T25 `percent` (not `allowlist` with trusted smoke accounts):** T26 (Mute existence), T27 (`muted[]` residue), T28 (`_` uid rule, plus the `auth:export` count), T29 (proto comments/skill, lands with T26), code-review S3 (race test) and S4 (retry jitter, cancel mapping), sec-L7 (page-size lever), sec-L9 decision, the L8 fields, opsctl hardening (R-4b), M6 App Check decision. T27 also blocks in-app account deletion. T30 is parked.
- **Expiring, not renewable:** v0.1.0 L6 is **partially closed** (Dependabot done in #45; exact-version pins for govulncheck/firebase-tools/ko/gcloud, `osv-scanner` and the "require full-length SHA pinning" repo setting remain, issue #46). **HARD deadline 2026-10-12, not renewed.** L7 is **closed by #45**.
- **Follow-ups (docs, not edited here):** update `cost-model.md` section 9 and the `cost-report-v0.2.0.md` "Dashboard notes" (they say no code emits `graph_op`; #36 changed that); ADR-0003 delete-path note for `quotas/{uid}` (S1); re-check `quotas/{uid}` on the next deletion drill and on the smoke-account cleanup; the "founder + 2 smoke accounts" wording is now corrected to "smoke-a and smoke-b only" (2026-10-01, also in `docs/plans/graph.md`; the allowlist does not contain the founder's account). Release notes §8 wording fixed too.
- **Recommended, not blocking:** enable `clouderrorreporting.googleapis.com` (R-N1); pubspec version (R-N7); remove default Compute SA Editor (v0.1.0 L1).

## 8. Release notes — v0.2.0
Social graph for dZeroth (web, https://dzeroth.com). **Not visible to users yet:** the feature is off in production and enabled
for two internal test accounts only. It turns on for everyone in later steps.
- Follow and unfollow accounts; see followers and following counts and lists (public accounts).
- Block an account: it can no longer follow you or see your profile, and follows between you are removed both ways. Blocks and mutes are not
  disclosed to the other account. Mute an account silently. Settings lists your blocked and muted accounts.
- `GetMe` now reports which features are enabled for you. Private accounts are not available yet: turning on "private" is rejected (closes v0.1.0 L9). Handle-availability checks allow 20 per minute (was 10).
- Operations: per-user quotas and rate limits for graph actions, a kill switch (`FEATURE_GRAPH`), delete/export tooling (`opsctl`) and new runbooks.
- Known limits: no posts or timeline yet, so following changes nothing you see beyond counts and lists; no follow notifications; no report tool; account deletion and export are still by email
  (privacy@dzeroth.com); no mobile apps; a deleted account's id may linger in other users' muted lists (R-2).

## 9. Sign-off (required)
I accept or reject each item in §4, and confirm the §7 blockers are closed or explicitly waived.
- [x] R-1  [x] R-2 (with conditions b and c; bounded to 2026-10-31)  [x] R-3  [x] R-4  [x] R-5  [x] R-6  [x] R-7  [x] R-8  [x] R-9  [x] R-10
- [x] R-P1 (privacy condition)  [x] R-P2 (option chosen: Terraform apply first, option 1, as answered by the founder in chat)  [x] R-P3  [x] R-P4
- [x] Carried v0.1.0 items per §4.0 (v0.1.0 L6 partially closed, remainder in issue #46 with hard date 2026-10-12, not renewed; L7 closed by #45)

**Founder sign-off of the §4 risk decisions (recorded by the assistant from chat, 2026-09-30):** "I accept the §4 risk decisions as recorded in readiness PR #43, including R-1 through R-10, R-P1 through R-P4, and the recorded carried-item decisions. Use this statement as my explicit sign-off for the §4 risk acceptance. Do not alter the risk decisions or their mitigations." The boxes above record exactly that statement. The decisions and mitigations in §4 are unchanged, including every DEFER and REJECT and the scoping of each ACCEPT to `allowlist` with only smoke-a and smoke-b. This statement does **not** address the §7 blockers (B1 to B4, B6, B7): those are not waived by it.
- [x] 2FA is still enabled on GitHub account `mohamadkaifshaik`. Confirmed by the account owner (founder) in chat, 2026-09-30: "Yes 2FA is still enabled on both Google and github." Recorded here by the assistant from that statement; the assistant did not check the account setting itself.
- [x] 2FA is still enabled on the Google account that is Owner of `dzeroth-prod`. Confirmed by the account owner (founder) in chat, 2026-09-30, same statement. Recorded by the assistant from that statement; not independently checked.

The §9 boxes above are recorded only from the founder's own chat statements quoted next to them (the two 2FA confirmations and the §4 risk sign-off); the assistant recorded them and did not verify the account settings itself. The repository names no separate "designated reviewers"; the 2FA lines are account-setting confirmations by the account owner (v0.1.0 precedent: recorded from chat on 2026-09-28). The §7 blockers are not covered by these statements and remain as listed in §7.

Approved by: Kaif Mohamad Shaik (founder), in chat, for the §4 risk decisions and the two 2FA confirmations only (§7 blockers not waived)  Date: 2026-09-30

VERDICT: PENDING
