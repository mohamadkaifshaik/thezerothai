# Release readiness — v0.4.0 (prod v0.1.0 → graph + posts/timeline + P8 account lifecycle + modern UI; all new flags off)

Reviewer: `production-reviewer` (read-only), 2026-10-10, against `origin/main` at `07752c4`. Founder decisions and
lead verifications are recorded in sections 3 and 4. **Release name: `v0.4.0`** (never `v0.2.0`; see F2).

Prod serves v0.1.0 on `api-00003-tiw` (100%). `api-00007-8mq`, `api-00004` to `00006` are Terraform-made v0.1.0 revisions
that were never smoke-tested: **never route traffic to them.**

## 1. Verdicts
| Decision | Verdict |
|---|---|
| A. Tag + zero-traffic `candidate` | CONDITIONAL GO after the pre-tag items in section 2 are closed. `promote-prod.yml` reads the verdict file at the tag, so the GO line must be on `main` before tagging. |
| B. Promote 10% → 100% | CONDITIONAL GO: same items plus the P2 candidate gates and the P3 10% watch (section 5). Any failed gate: stop and roll back to `api-00003-tiw`. |
| C. Ramp flags | NO-GO. Per-flag conditions in section 6. |

## 2. Findings and status (updated by the lead, 2026-10-10)
| # | Sev | Class | Finding | Status |
|---|---|---|---|---|
| F1 | High | BLOCKER | Live prod has `FEATURE_GRAPH=allowlist` (2 uids), which the candidate inherits | **Accepted by founder (option a)**; verified, section 3 |
| F2 | High | BLOCKER | Stale `VERDICT: GO` in `release-v0.2.0-readiness.md` (set by instruction, never released) passes the promote gate if tagged `v0.2.0` | **Fixed in this PR** (line now `SUPERSEDED`); tag `v0.4.0` |
| F3 | Med | BLOCKER | P8 code review still `REQUEST CHANGES`; #107 never re-approved | **APPROVE** (addendum appended to `code-review-account-lifecycle.md`); 4 Minor + 2 Nit follow-ups, none blocking |
| F4 | Med | BLOCKER | #110 (modern UI, 18 files) merged unreviewed | **REQUEST CHANGES** (`code-review-modern-ui-110.md`): M1 snackbar action/close contrast is live and must be fixed before web at 100% (3-line theme fix + test); M2 `PostMedia` full-image fallback before the media flag; no blocker |
| F5 | Med | BLOCKER | Ungated client-side account delete (L-5) goes live on web at 100%; web path never verified | **Verified by founder 2026-10-10** on `dzeroth-dev.web.app`: reported "working fine". Which account types were exercised and the Auth/local-DB observations were not itemised in chat; the founder may add detail here |
| F6 | Med | BLOCKER (record) | R4: older alert policies are a fixed monitoring cost with no recorded decision | **Closed.** Decided (ii) prod only; recorded in `cost-model.md` §5 and ADR-0007 amendment; #113 merged; **dev applied 2026-10-10** (3 policies destroyed, post-apply plan clean); read-only prod plan = 0 add/0 change/0 destroy (state moves only) |
| F7 | Med | PRE-FLAG | v0.1.0 acks every `/internal/*` push with 202; rollback to it with `DELETING`/`PENDING` work silently drops it; `rollback.md` was wrong | **Fixed in this PR** (`rollback.md`). Never enable the lifecycle flag while `api-00003-tiw` holds traffic |
| F8 | Low | BLOCKER (procedural) | CI has not run on the final commit (PRs only; #110's head tree is identical to `07752c4`, run passed) | Open: `gh workflow run CI --ref main` after the verdict commit |
| F9 | Low | BLOCKER (one command) | A2 pre-check `check-t26` not run | **Done 2026-10-10: PASS**, section 4 |
| F10 | Med | PRE-FLAG (posts `percent`) | Posts on uses ~116% of free reads at 300 DAU (free quota ends ~258 DAU); fails 20% headroom by design | Open: founder accepts (~$0.14/month at 300 DAU) or applies the `k` lever |
| F11 | Med | PRE-FLAG | `opsctl delete-account` (T12) not built; T22/T23 | T22/T23 doc work merged in #111 (timed drill still open); T12 before lifecycle `percent` |
| F12 | Med | PRE-FLAG (lifecycle `percent`) | R1 export size ceiling/time unmeasured | Open: measure on dev with a large synthetic account |
| F13 | Low | ACCEPTABLE | Error Reporting API not enabled in prod (free to enable; use Logs Explorer `severity>=ERROR`) | Recommended |
| F14 | Med | ACCEPTABLE web-only; BLOCKER for stores | Version `1.0.0+1`, no Crashlytics, no forced upgrade, Android config is dev's, on-device delete + Apple revoke unverified | Do not distribute the AAB/iOS artifacts `release-prod` builds |
| F15 | Low | ACCEPTABLE | HashUID is an unkeyed truncated SHA-256 (Minor 6) | Record in privacy notes; HMAC pepper is a $0 follow-up |
| F16 | Low | CLOSED | `-race` never run locally only; CI runs it on both suites | — |
| F17 | Low | CLOSED + rec. | `buf breaking` vs tag `v0.1.0` exits 0; CI only diffs against `origin/main` | Add a check against the last release tag to the release gate |
| F18 | Low | ACCEPTABLE | `release-prod`/`promote-prod` changed only in pins since v0.1.0; first tag run since | Watch the run |
| F19 | Low | PASS | Web bundle 1.07 MB gzip (v0.1.0 ~0.7 MB), under the 3 MB target | Re-measure from the stage=100 build |
| F20 | Med | PRE-FLAG (posts allowlist) | Posts e2e smoke has no evidence of a run on dev with the flag on; posts P0 test-name closure | Open |

## 3. Founder decisions (2026-10-10, in chat)
- **F1 = (a) Accept.** `graph=allowlist at release` is an accepted release condition. No production Terraform change for
  F1. The allowlist must not be extended to real users while privacy PR #37 remains unresolved (R-P1 in
  `release-v0.2.0-readiness.md`, which still binds).
- **F6 = (ii) Prod only.** Keep the three existing alert policies enabled in prod; disable them in dev through Terraform
  (separate PR; dev apply is plan-then-OK). Record the remaining cost in `cost-model.md` §5 and ADR-0007 (done here).
- **Execution boundaries:** read-only checks on prod are allowed, no prod change without explicit approval; the release
  stays blocked until the gates are satisfied and the production-reviewer issues `VERDICT: GO`; percentage rollout stays
  blocked until T26/T27/T28/S3/S4 are complete.
- F5 (web client-delete check) was completed by the founder on 2026-10-10 (see section 2).

## 4. Lead verifications (read-only, 2026-10-10)
- **F1 precondition (allowlist are the smoke accounts):** live service template has `FEATURE_GRAPH=allowlist`,
  `FEATURE_GRAPH_PERCENT=0`, 2 allowlisted uids. Identity Toolkit lookup: both uids exist, both are **password**
  accounts with **verified** email and a smoke-account email, neither disabled. Match to the v0.2.0 smoke accounts
  (smoke-a, smoke-b): yes by email pattern; uids not recorded here.
- **F9 `check-t26` against `dzeroth-prod`:** `total=4 allowed=4 not_allowed=0 not_allowed_with_users_doc=0
  firestore_reads=0`, `T26: PASS`. No existing v0.1.0 user is locked out by the A2 verification rule.
- **R4 pricing:** the Cloud Observability pricing examples page gives $0.35 per metric reference per month and $0.50
  per million points returned (alerting). Uptime-check executions: $0.30 per 1,000 after 1M free per project (from a
  search summary of the pricing pages). A search summary also says alerting is not charged before 2027-09-01 and that
  uptime/billing/quota-metric policies are free; I could not read that on the primary page, so it is **unconfirmed** and
  the cost-model figure stays the conservative upper bound (about $1.45 to $1.60/month for prod, including C4).

## 5. Commands (P0 before tag; P2 to P5 after)
```
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"
P="--project=dzeroth-prod --region=asia-south1"
```
**P0 (before tagging, all required):** F2 and F7 docs PR merged; F3 and F4 reviews APPROVE; F5 web check recorded here;
F6 dev gating PR merged and applied (optional for the tag, required for the record to be true); F8 CI run on `main`
after the verdict commit; reviewer re-run flips the last line to GO and it is merged; then
`git diff --stat 07752c4 <tag-commit> -- backend app proto firebase firebase.json infra .github Makefile` is empty (or
only reviewed changes); `git tag v0.4.0 <tag-commit> && git push origin v0.4.0`. Record the run ID and `ko` digest.

**P2 (after `build-and-stage`, stop on any failure):**
1. `"$G" run services describe api $P --format='yaml(status.traffic)'`: `api-00003-tiw` 100%, new revision 0% tagged `candidate`.
2. Flags on the candidate: posts off, lifecycle off, graph `allowlist` (2 smoke uids, accepted). Startup `feature_flags` log line matches.
3. `"$G" firestore indexes composite list --project=dzeroth-prod`: 9 READY.
4. Smoke `https://candidate---api-jgr3aiensq-el.a.run.app`: `/health` 200 with cold start < 1.5 s; unauthenticated GetMe
   401; an existing v0.1.0 profile GetMe/GetProfile OK; for a non-allowlisted account with a profile,
   `CreatePost`, `GetHomeTimeline`, `DeleteAccount`, `RequestAccountExport` each return FAILED_PRECONDITION
   `FEATURE_DISABLED` at 0 reads; a new verified throwaway account: CreateProfile succeeds (exercises M2 under prod IAM),
   then delete it with the manual runbook; a new unverified account: EMAIL_NOT_VERIFIED; graph smoke
   `TestE2E_GraphSmoke_FollowListBlockUnblock` with the 2 smoke accounts.
5. Candidate logs: `resource.labels.revision_name="<rc>" AND (severity>=ERROR OR httpRequest.status>=500)` returns 0.

**P3 (`promote-prod.yml` from the tag, stage=10), watch 15 minutes:** 5xx < 2% with at least 50 requests; p95 < 2x the
v0.1.0 baseline (GetMe 270 ms); 0 unexplained ERROR; uptime check green.
**P4 (stage=100):** ask the founder first. Record the web bundle size.
**P5:** `dzeroth.com` loads in a clean profile; sign-up and Google sign-in work; `/privacy` and `/api/health` 200; after
the next 03:00 IST run the `account_job backstop outcome=ok` line shows `fs_reads` around 2; 7 days of ERROR/5xx = 0 and
Firestore < 10k reads/day; write `docs/reviews/release-v0.4.0-postrelease.md`.

**Rollback:** `"$G" run services update-traffic api $P --to-revisions=api-00003-tiw=100` (always `--to-revisions`, never
`--to-latest`). Web: Firebase Hosting rollback to the v0.1.0 release. Once any lifecycle flag has been on, follow
`docs/runbooks/rollback.md` (flag off first, never roll back to v0.1.0 with `DELETING`/`PENDING` jobs).

## 6. Flag-ramp prerequisites (verdict C)
- **Lifecycle:** new revision at 100% and `api-00003-tiw` at 0%; `rollback.md` fixed (done); T23 timed drill + one
  in-app deletion with 0 residue; the founder's own uid verified end to end on web; before `percent`: T12, T22, R1.
- **Posts:** F20 before allowlist; F10 before `percent`.
- **Graph:** privacy #37 resolved and published before any real user is allowlisted; before `percent`: T26, T27, T28,
  S3, S4, sec-L7/L9, opsctl hardening, App Check decision (`release-v0.2.0-readiness.md` section 7).

## 7. Risks to accept (founder sign-off)
| Risk | Status |
|---|---|
| F1(a) graph allowlist (2 smoke accounts) at release | Accepted 2026-10-10 |
| F6 R4 monitoring fixed cost, prod only | Accepted 2026-10-10 |
| F13 Error Reporting API disabled | Open |
| F15 HashUID unkeyed | Open |
| F18 first tag run of re-pinned workflows | Open |
| L-5 ungated web client delete (accepted 2026-10-08; restated, goes live in prod) | Accepted; web path verified on dev by the founder 2026-10-10 (details not itemised) |

VERDICT: NO-GO
