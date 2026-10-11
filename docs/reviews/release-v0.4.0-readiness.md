# Release readiness — v0.4.0 (prod v0.1.0 → graph + posts/timeline + P8 account lifecycle + modern UI; all new flags off)

Reviewer: `production-reviewer` (read-only). First run 2026-10-10 against `07752c4`, second run against `13b62ff` (NO-GO on paperwork only). **This re-run: 2026-10-11 against `origin/main` at `f2a7c17`** (`f2a7c1751633698508acaddb72c94a69db274104`). Founder decisions and lead verifications are recorded in sections 3 and 4. **Release name: `v0.4.0`** (never `v0.2.0`; see F2).

Prod serves v0.1.0 on `api-00003-tiw` (100%). `api-00007-8mq` and `api-00004` to `00006` are v0.1.0 revisions made by Terraform and never smoke-tested: **never route traffic to them.**

## 1. Verdicts
| Decision | Verdict |
|---|---|
| A. Tag + zero-traffic `candidate` | **GO**, once the pre-tag actions in §8 are done. The GO line must be on `main` before tagging. |
| B. Promote 10% → 100% | **GO**, only if the P2 candidate gates pass and the P3 10% watch (§5) is clean. Any failed gate: stop and roll back to `api-00003-tiw`. The founder dispatching `promote-prod.yml` is the human approval. |
| C. Ramp flags | NO-GO. Per-flag conditions are in §6 (unchanged). |

## 2. Findings and status (re-verified 2026-10-11 at `f2a7c17`)
| # | Sev | Class | Finding | Status at f2a7c17 | Evidence |
|---|---|---|---|---|---|
| F1 | High | BLOCKER | Live prod has `FEATURE_GRAPH=allowlist` (2 uids), which the candidate inherits | ✅ Accepted by founder (option a) | §3; live template re-read 2026-10-11: graph=allowlist, 2 uids, percent 0 |
| F2 | High | BLOCKER | Stale `VERDICT: GO` in `release-v0.2.0-readiness.md` | ✅ Fixed | Last line of v0.2.0 file is `VERDICT: SUPERSEDED …`. Exact `VERDICT: GO` exists only in v0.1.0 (tag already used). v0.3.0 is `PENDING` |
| F3 | Med | BLOCKER | P8 code review was REQUEST CHANGES | ✅ APPROVE | `code-review-account-lifecycle.md:103` `VERDICT: APPROVE` |
| F4 | Med | BLOCKER | #110 merged without review | ✅ Closed for release | Fix verified (see note below this table); M2 accepted as dormant in §7; record in §7 "F4 record" |
| F5 | Med | BLOCKER | Ungated web client delete (L-5) | ✅ Founder-verified on dev 2026-10-10; L-5 accepted 2026-10-08 | §2/§7. The founder's report did not say which account types were tested (accepted) |
| F6 | Med | BLOCKER (record) | R4 alert policies are a fixed monitoring cost | ✅ Closed | #113 (`109676b`); `cost-model.md` §5; ADR-0007 amendment; dev applied; prod plan 0/0/0 |
| F7 | Med | PRE-FLAG | Rollback to v0.1.0 drops `/internal/*` work | ✅ Fixed (`rollback.md`); flag rule in release notes | `docs/releases/v0.4.0.md` "Server flags" and "Operations" |
| F8 | Low | Procedural | CI never ran on the final `main` commit | ✅ **Met by tree identity** (not a blocker). `workflow_dispatch` on `main` is a recommended pre-tag action | Tree of `f2a7c17` = tree of PR #117 head `ff76a334`; CI run 38056698291: `make ci` ✅, `make test-int` ✅. `ci.yml` triggers only on `pull_request`/`workflow_dispatch` |
| F9 | Low | BLOCKER | `check-t26` | ✅ PASS | §4 |
| F10 | Med | PRE-FLAG (posts `percent`) | Posts reads ~116% of free quota at 300 DAU | Open, does not block (posts off) | §6 |
| F11 | Med | PRE-FLAG | T12 `opsctl delete-account` not built; T23 timed drill | Open, does not block (lifecycle off) | §6 |
| F12 | Med | PRE-FLAG | R1 export size ceiling not measured | Open, does not block (lifecycle off) | §6 |
| F13 | Low | ACCEPTABLE | Error Reporting API not enabled in prod | ✅ Accepted (*delegated*) for this release. **Not required for GO.** Enabling it is a recommended pre-tag action (free, but a prod change: founder OK) | `gcloud services list --enabled` 2026-10-11: still disabled at review time. The substitute is the Logs Explorer `severity>=ERROR` query in P2.5/P3 |
| F14 | Med | Web-only acceptable; BLOCKER for stores | Mobile: version `1.0.0+1`, no Crashlytics, no forced upgrade, Android config is dev's | ✅ Accepted (*delegated*): web-only, AAB/IPA not distributed | §7; release notes "Not distributed" |
| F15 | Low | ACCEPTABLE | HashUID is an unkeyed truncated SHA-256 | ✅ Accepted (*delegated*); HMAC pepper follow-up | §7; release notes "Known limits" |
| F16 | Low | CLOSED | `-race` | — | CI runs it |
| F17 | Low | CLOSED + rec. | `buf breaking` vs `v0.1.0` exits 0 | Recommendation stands (add a check against the last release tag to the gate) | — |
| F18 | Low | ACCEPTABLE | First tag run of the re-pinned release/promote workflows | ✅ Accepted (*delegated*); `release-prod` only stages at 0% | §7. No `.github` change since `07752c4` |
| F19 | Low | PASS | Web bundle 1.07 MB gzip | Re-measure at stage=100 | — |
| F20 | Med | PRE-FLAG (posts allowlist) | Posts e2e smoke not run on dev with the flag on | Open, does not block (posts off) | §6 |
| F21 | Low | BLOCKER (paperwork) | No release notes | ✅ `docs/releases/v0.4.0.md` | Checked against live prod: flag table matches the template; 9 indexes READY; rollback command uses `--to-revisions=api-00003-tiw=100` |
| F22 | Low | NEW, non-blocking | `code-review-modern-ui-110.md` still ends `VERDICT: REQUEST CHANGES`; nobody re-reviewed #114 | Accepted by this reviewer (see F4 note) | Recommend a one-line code-reviewer addendum after release |

**F4 verification:** the #114 diff (`81594fe`) adds exactly the fix the review prescribed: `actionTextColor: colorScheme.primary` and `closeIconColor: colorScheme.onSurfaceVariant`. The new `app_theme_test.dart` checks ≥4.5:1 for the action and ≥3:1 for the icon in both themes. PR CI run 38054560861 is green.

**Code drift since the reviewed commit `07752c4`, checked at `f2a7c17`:** only `app_theme.dart` and its test (#114), plus `infra/terraform/{envs/dev,envs/prod,modules/monitoring}` (#113, prod plan 0/0/0). No change to `backend`, `proto`, `firebase`, `.github` or `Makefile`.

## 3. Founder decisions (2026-10-10, in chat)
- **F1 = (a) Accept.** `graph=allowlist at release` is an accepted release condition. No production Terraform change for F1. The allowlist must not be extended to real users while privacy PR #37 remains unresolved (R-P1 in `release-v0.2.0-readiness.md`, which still binds).
- **F6 = (ii) Prod only.** Keep the three existing alert policies enabled in prod; disable them in dev through Terraform (done, #113, dev applied). The remaining cost is recorded in `cost-model.md` §5 and ADR-0007.
- **Execution boundaries:** read-only checks on prod are allowed, no prod change without explicit approval. The release stays blocked until the gates are met and the production-reviewer issues `VERDICT: GO`. Percentage rollout stays blocked until T26/T27/T28/S3/S4 are complete.
- **Delegation (2026-10-10):** "if you need decisions from me you have authorization to choose what is best for this product". The F13/F14/F15/F18 acceptances in §7 were made by the lead under this delegation. The founder can reverse any of them.
- F5 (web client-delete check) was completed by the founder on 2026-10-10.

## 4. Lead verifications (read-only, 2026-10-10) and reviewer re-checks (2026-10-11)
- **F1 precondition:** both allowlisted uids exist, are **password** accounts with **verified** smoke-account emails, and neither is disabled. They match smoke-a and smoke-b by email pattern.
- **F9 `check-t26` against `dzeroth-prod`:** `total=4 allowed=4 not_allowed=0 not_allowed_with_users_doc=0 firestore_reads=0`, `T26: PASS`.
- **R4 pricing:** the conservative upper bound stays at about $1.45 to $1.60/month for prod, including C4. The "alerting not charged before 2027-09-01" claim is still unconfirmed.
- **Reviewer re-checks, 2026-10-11:**
  - Prod traffic: `api-00003-tiw` 100%. The `candidate` tag currently sits on `api-00003-tiw`; `release-prod` moves it to the new revision. `latestCreatedRevisionName=api-00007-8mq` (0%).
  - Composite indexes: 9 READY.
  - Flags: posts=off (0 allowlist, 0%), lifecycle=off (0 allowlist, 0%), graph=allowlist (2 uids, 0%), `DEGRADED_MODE=off`.
  - The Error Reporting API is not enabled.
- **Reviews at `f2a7c17`:**
  - Security, 0 Critical / 0 High open: `security-review-account-lifecycle.md` (M-1..M-3 fixed), `security-review-posts-timeline.md`, `security-review-graph.md`.
  - Tests, PASS: `test-report-{account-lifecycle,posts-timeline,graph}.md`.
  - Code reviews, APPROVE: `code-review-posts-timeline.md`, `graph-code-review.md`, `code-review-account-lifecycle.md`.

## 5. Commands (P0 before tag; P2 to P5 after)
```
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"
P="--project=dzeroth-prod --region=asia-south1"
```
**P0 (before tagging):** do the §8 pre-tag actions. Then check that `git diff --stat 07752c4 <tag-commit> -- backend app proto firebase firebase.json infra .github Makefile` shows only #113 and #114. Then `git tag v0.4.0 <tag-commit> && git push origin v0.4.0`. `<tag-commit>` is the merge commit of the PR that carries this file with `VERDICT: GO`. Record the run ID and the `ko` digest.

**P2 (after `build-and-stage`, stop on any failure):**
1. `"$G" run services describe api $P --format='yaml(status.traffic)'`: `api-00003-tiw` at 100%, and a new revision (not `api-00004`..`00007`) at 0% tagged `candidate`.
2. Flags on the candidate: posts off, lifecycle off, graph `allowlist` (2 smoke uids, accepted). The startup `feature_flags` log line matches.
3. `"$G" firestore indexes composite list --project=dzeroth-prod`: 9 READY.
4. Smoke `https://candidate---api-jgr3aiensq-el.a.run.app`:
   - `/health` returns 200 with cold start < 1.5 s.
   - Unauthenticated GetMe returns 401.
   - GetMe/GetProfile work for an existing v0.1.0 profile.
   - For a non-allowlisted account with a profile, `CreatePost`, `GetHomeTimeline`, `DeleteAccount` and `RequestAccountExport` each return FAILED_PRECONDITION `FEATURE_DISABLED` at 0 reads.
   - A new verified throwaway account: CreateProfile succeeds, then delete it with the manual runbook.
   - A new unverified account gets EMAIL_NOT_VERIFIED.
   - Graph smoke `TestE2E_GraphSmoke_FollowListBlockUnblock` passes with the 2 smoke accounts.
5. Candidate logs: `resource.labels.revision_name="<rc>" AND (severity>=ERROR OR httpRequest.status>=500)` returns 0. This is also the F13 substitute.

**P3 (`promote-prod.yml` from the tag, stage=10), watch 15 minutes:**
- 5xx < 2% with at least 50 requests.
- p95 < 2× the v0.1.0 baseline (GetMe 270 ms).
- 0 unexplained ERROR.
- Uptime check green.

**P4 (stage=100):** ask the founder first. Record the web bundle size.

**P5:**
- `dzeroth.com` loads in a clean profile; sign-up and Google sign-in work; `/privacy` and `/api/health` return 200.
- After the next 03:00 IST run, the `account_job backstop outcome=ok` line shows `fs_reads` around 2.
- 7 days of ERROR/5xx = 0 and Firestore < 10k reads/day.
- Write `docs/reviews/release-v0.4.0-postrelease.md`.

**Rollback:**
- Cloud Run: `"$G" run services update-traffic api $P --to-revisions=api-00003-tiw=100`. Always `--to-revisions`, never `--to-latest`.
- Web: Firebase Hosting rollback to the v0.1.0 release.
- Once any lifecycle flag has been on, follow `docs/runbooks/rollback.md` (flag off first, never roll back to v0.1.0 with `DELETING`/`PENDING` jobs).

## 6. Flag-ramp prerequisites (verdict C, unchanged)
- **Lifecycle:**
  - Before any flag: new revision at 100% and `api-00003-tiw` at 0%; T23 timed drill plus one in-app deletion with 0 residue; the founder's own uid verified end to end on web.
  - Before `percent`: T12, T22, R1 (F11, F12).
- **Posts:** F20 before allowlist; F10 before `percent`.
- **Graph:**
  - Before any real user is allowlisted: privacy #37 resolved and published.
  - Before `percent`: T26, T27, T28, S3, S4, sec-L7/L9, opsctl hardening, and the App Check decision (`release-v0.2.0-readiness.md` section 7).
- **Media:** F4 M2 (`PostMedia` thumbnail-only in lists) must land before `FEATURE_MEDIA`/`kPostsSubFeatureMedia`.

## 7. Risks accepted
The founder delegated product decisions to the lead on 2026-10-10. Items marked *delegated* were accepted by the lead under that delegation and can be reversed by the founder at any time. The founder's own `promote-prod.yml` dispatch is the final human approval for this release.

| Risk | Status |
|---|---|
| F1(a) graph allowlist (2 smoke accounts) at release | Accepted by founder 2026-10-10 |
| F6 R4 monitoring fixed cost, prod only | Accepted by founder 2026-10-10 |
| L-5 ungated web client delete (goes live in prod) | Accepted 2026-10-08; web path founder-verified on dev 2026-10-10 (details not itemised) |
| F4 M2 `PostMedia` full-image fallback | Dormant (backend returns no media); fix in the P4 slice; **must land before `FEATURE_MEDIA` is on** |
| F14 web-only; AAB/IPA not distributed; mobile gaps | Accepted (*delegated*) 2026-10-10. Re-open before any store submission |
| F15 HashUID unkeyed truncated SHA-256 in logs | Accepted (*delegated*) 2026-10-10. Follow-up: HMAC pepper ($0), record in privacy notes |
| F18 first tag run of the re-pinned release/promote workflows | Accepted (*delegated*) 2026-10-10. Mitigation: `release-prod` only stages at 0%; watch the run |
| F13 Error Reporting API disabled in prod | Accepted (*delegated*) 2026-10-10 for this release. Substitute: Logs Explorer `severity>=ERROR`. Enabling it is free but is a prod change: pending a quick founder OK |
| F22 #110 review file not updated to APPROVE after #114 | Accepted by production-reviewer 2026-10-11: the fix matches the prescription exactly, is tested, and CI is green |
| R-2 / R-P1 (graph privacy residue, #37) | Smoke accounts only; R-2 target 2026-10-31; no real user allowlisted |

### F4 record (#110)
`code-review-modern-ui-110.md` M1 (snackbar contrast) is fixed in #114 (`81594fe`). `app_theme_test.dart` passes (action 4.5:1, icon 3:1, both themes) and PR CI run 38054560861 is green. Production-reviewer re-checked the diff on 2026-10-11: it matches the review's prescribed fix. M2 is deferred until `kPostsSubFeatureMedia`/`FEATURE_MEDIA`; the P4 slice carries the fix. Minors m1-m4 and the nits are post-release follow-ups.

### Release notes (F21)
`docs/releases/v0.4.0.md`. Its flag table, index count and rollback command were checked against live prod on 2026-10-11.

## 8. Re-run result (2026-10-11, `f2a7c17`)

**Previous blockers, re-verified:**
- F13, F14, F15 and F18 are accepted in writing (delegated, §7).
- F21 release notes exist and are accurate.
- The F4 record is present and verified.
- F8 is met by tree identity: `f2a7c17` has the same tree as PR #117 head `ff76a334`, and CI run 38056698291 passed `make ci` and `make test-int`.

No new blocker was found.

**Checklist status:**
- Quality ✅ (CI green on the release tree; test reports PASS; code reviews APPROVE or closed per F4/F22).
- Security ✅ (0 Critical / 0 High open).
- Cost ✅ (flags off: no new read load; R4 accepted; no new fixed-cost resource).
- Reliability ✅ (9 indexes READY; rollback revision `api-00003-tiw` identified; candidate smoke is gate P2).
- Operability ✅ (runbooks and release notes present; flags off; rollback triggers in P3; Error Reporting substituted per F13).
- Clients ✅ (web-only, accepted per F14; bundle 1.07 MB).
- Compliance ✅ (P8 delete/export present behind a flag; L-5 accepted; graph privacy bound to smoke accounts).

**Remaining pre-tag actions:**
1. **Required:** Deploy-dev run 38106206242 on `f2a7c17` must finish green. It was in progress at review time; if it fails, this GO is void until it is re-checked.
2. **Required:** merge the PR that commits this file. Its CI must be green, and the change must be limited to `docs/`. Tag `v0.4.0` on that merge commit and nothing later. Run the P0 drift check (only #113/#114 vs `07752c4`).
3. **Recommended, not required for GO (F8):** `gh workflow run CI --ref main` on the tag commit as belt-and-braces. The release tree already has a green full CI run by tree identity.
4. **Recommended, not required for GO (F13):** enable `clouderrorreporting.googleapis.com` in `dzeroth-prod` after founder OK. It is free, but it is a prod change. Until then, P2.5/P3 use the Logs Explorer `severity>=ERROR` query.
5. **Post-release, non-blocking:**
   - Code-reviewer addendum on `code-review-modern-ui-110.md` (F22).
   - Add `buf breaking` against the last release tag to the gate (F17).
   - Founder may ratify or reverse the delegated acceptances in §7.

VERDICT: GO
