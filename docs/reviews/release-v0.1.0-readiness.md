# Release readiness — v0.1.0 (Phase 0: platform + identity, web launch)

Reviewer: production-reviewer agent, review dated 2026-09-28. Read-only: nothing was deployed, applied or changed.
B1 and B2 were closed afterwards (§7 has the evidence).
Scope: the first prod release. The API goes to Cloud Run `api` in `dzeroth-prod`, and the web app to Firebase Hosting
(`dzeroth.com`). **No store submission.**
Release candidate: the code as of `main@c19c112`. Commits after it change docs and `promote-prod.yml` only.
The `v0.1.0` tag is created on the commit that sets the final line to GO. Before tagging, gate P0.3 checks that no code
changed.

Status labels: **PASS**, **FAIL** (blocking), **ACCEPTED** (a risk you sign off in §4), **GATED** (checked after
release-prod stages the new revision under the `candidate` tag; a pass/fail gate in §5), **N/A**.

## 1. Inputs
| Input | Status | Evidence |
|---|---|---|
| Plan in `docs/plans/` with cost rows | ACCEPTED (R-N6) | None exists for this bootstrap release. Substitutes: ADR-0001…0007, `docs/reviews/cost-model.md` §2, the budget comments in `proto/` |
| ADRs for design changes | PASS | ADR-0001…0007 Accepted. ADR-0006 amendments 2026-09-27 (web App Check deferred) and 2026-09-28 (pre-auth IP limit, ClientIP, H1) |
| Test report PASS, incl. budget assertions | PASS (R-N6) | CI run 36369005999 (same code as `c19c112`): `make ci` green, `pkg/platform` 82.3%, golangci-lint 0, 80 Flutter tests; `make test-int` `internal/` 87.7% with `budgettest.Assert` read/write budgets |
| Code review APPROVE | PASS | `docs/reviews/phase0-code-review.md`: all blockers and majors fixed and re-reviewed. PRs #13–#15 spot-checked (§2) |
| Security: no open Critical/High | PASS | `docs/reviews/security-audit-v0.1.0.md`: 0 Critical, H1 fixed; the rest fixed or accepted in §4 |
| Cost: free quotas hold with ≥ 20% headroom | PASS | §3. Prices in `cost-model.md` §7 are unverified (R-N6) |
| No unapproved fixed-cost resource | PASS | No `cost-guard`-forbidden resources; `min_instance_count = 0`, max 3 |
| Green CI on the release commit, image digest | PASS / GATED | CI as above; deploy-dev run 36369902661 green. Digest recorded at P2.1 |
| `terraform plan` for prod | PASS | Run 36340060163: 0 to add, 1 to change (the cosmetic dashboard diff only) |
| rc smoke test; indexes READY; previous revision identified | GATED | Previous revision is `api-00002-fnn` (the `hello` placeholder). §5, §6 |
| Feature flags; rollout plan | N/A / PASS | No flags. Rollout and triggers are in §5–§6 |
| Runbooks; budget alerts | PASS (B1, B2 closed) / PASS | `cost-spike.md` (pinned-traffic procedure), `abuse-spike.md` (new), `rollback.md`, `account-deletion.md`. Budgets ₹500/month per project, 25/50/90/100% plus forecast, email and Pub/Sub |
| Mobile | N/A | Web only. The store path is blocked by M5 (in-app DeleteAccount) |

## 2. Checklist
**Quality: PASS.** CI is green (both jobs), coverage gates are met, and no code-review blockers are open.

**Security: PASS, with M6 ACCEPTED.**
- H1: `requireVerifiedEmailForPassword` → EMAIL_NOT_VERIFIED.
- M1: `PreAuthIPMiddleware` wraps the whole mux before auth.
- M2: `ResolveClientIP`, verified on dev.
- M3: live browser key restricted to prod origins; iOS key bundle-restricted; Android key API-restricted only (R-L-M3).
- L4: live, no localhost in prod.
- 256 KiB request cap.
- govulncheck: 0 affected.
- Firestore rules are deny-all (deployed by release-prod).
- App Check is UNENFORCED, and the API runs in `monitor` (M6).
- WIF is pinned to repo, `refs/tags/v*`, the release/promote workflows and `environment==prod`. No SA keys.

**Cost: PASS.** §3 is well under the 80% line, there are no fixed-cost resources, budgets are live, and prod runs
max 3 / min 0 / 1 vCPU / 512 MiB / concurrency 80 / 30 s timeout. The degraded-mode switch was drilled on dev (B1).

**Reliability: GATED or PASS.** The rc smoke tests and index readiness are gated in §5. DLQs are configured.
There are no data migrations. Prod `(default)` has delete protection, weekly backups (14-day retention) and
`freeTier: true`.

**Operability: PASS, with R-N1 ACCEPTED.** Runbooks are complete (B1, B2). The Error Reporting API is disabled, so
use the Logs Explorer substitute in §5. The uptime check is green. There are 3 alert policies plus the dashboard.

**Clients: N/A or PASS.**
- The web bundle is about 0.7 MB gzip of our own JS; CanvasKit comes from the gstatic CDN.
- JS and the service worker are `no-cache`.
- Mobile artifacts must not be distributed (R-N11).

**Compliance: PASS.**
- PII is limited to Firebase Auth email.
- `account-deletion.md` covers `users/{uid}`, `handles/`, `graph/{uid}` and the Auth user.
- The privacy policy is live on dev at `/privacy`; on prod it arrives at stage 100 (checked in P5).
- privacy@dzeroth.com forwards through ImprovMX.

## 3. Cost at the Stage 0 target (identity RPCs only)
| Quota | Per DAU/day | At 300 DAU | % of free | Headroom vs the 80% line |
|---|---|---|---|---|
| Firestore reads (50k/day) | 7.3 typical / 20.3 worst | 2.2k / 6.1k | 4.4% / 12.2% | ≥ 85% |
| Firestore writes (20k/day) | 0.17. A launch burst of 300 new profiles is 900 writes | 51 / 900 | 0.3% / 4.5% | ≥ 94% |
| Cloud Run requests (2M/month, shared) | ~7.3, plus the uptime check | ~66k/month plus ~52k per env | ≈ 9% | large |
| Hosting transfer (360 MB/day) | ~0.75 MB per new visitor | ~450 new visitors/day free, then $0.15/GB | — | pay-per-use |
| Cloud Run egress to India | billed from the first byte | cents per month | — | pay-per-use |

## 4. Risk acceptances (sign in §9)
- **M4 — `tf-plan` has `roles/viewer`, and its WIF is pinned to the repo only.** It can read Firestore, Auth users and
  Terraform state (including the cursor HMAC key). With one collaborator and a private repo, that's no access beyond
  the owner's own. **Expires** when a second collaborator is added: then swap in a custom read role and pin
  `job_workflow_ref` to `terraform.yml`.
- **M6 — App Check is monitor-only** (ADR-0006 amendment). The compensating controls:
  - H1 email verification;
  - the M1 pre-auth IP bucket;
  - per-uid and per-IP buckets;
  - Firebase's limit of about 100 sign-ups per hour per IP;
  - max 3 instances;
  - ₹500 budget alerts;
  - `DEGRADED_MODE` (drilled, B1);
  - the sign-up kill switch (drilled, B2).

  Revisit through an ADR when abusive sign-ups show up or revenue covers $8/month.
- **L1 — The default Compute Engine SA has Editor.** Nothing runs as it. Remove it in the next infra PR.
- **L2 — `ci-deploy` has `firebase.viewer`.** It can only be minted by the pinned workflows at `v*` tags in `prod`.
  Narrow it later.
- **L3 — The CSP is Report-Only with no reporting endpoint.** `X-Frame-Options: DENY`, nosniff and Referrer-Policy are
  enforced, and Flutter renders to canvas. Enforce the CSP after a Phase 1 sign-in regression pass.
- **L6 — Dependabot is off, tool versions are unpinned, and there's no osv-scanner.** The tree is clean today. Enable
  within 2 weeks of launch.
- **L7 — Actions are pinned by tag, not SHA.** The WIF pin and a single collaborator bound the risk. SHA-pin within 2 weeks.
- **L8 — No password policy and MFA off.** Accepted **on condition of the 2FA confirmations in §9**. Add a password
  policy (≥ 8 characters) in Phase 1.
- **L9 — The `isPrivate` toggle isn't enforced.** There's nothing to hide in v0.1.0. Enforce or hide it before the graph
  and posts modules ship.
- **R-L-M3 — The Android key has no SHA restriction.** No Android build is distributed.
- **R-N1 — The Error Reporting API is disabled in both projects.** Substitute: a Logs Explorer `severity>=ERROR` query.
  Recommended: enable `clouderrorreporting.googleapis.com` through Terraform.
- **R-N2 — Per-IP limits can be dodged by requests relayed through Google-run fetchers.** Per-uid limits, the sign-up
  limit, email verification and max-instances still hold.
- **R-N3 — The 5xx alert is a fixed rate, and `/health` touches neither Firestore nor Auth.** Covered by the manual watch
  (P6) in launch week.
- **R-N4 — The first release has no real rollback target** (only the placeholder). Plan in §6.
- **R-N5 — `/` and SPA routes are served with `max-age=3600`.** Small impact because the JS is `no-cache`. Add a `/`
  no-cache rule next release.
- **R-N6 — Process documents are missing** (plan, tester report, SRE cost report, verified prices, `firestore-quota.md`).
  Substituted by §1–§3. The Phase 1 features must follow the full workflow.
- **R-N7 — The pubspec says `1.0.0+1`, not 0.1.0.** Cosmetic; fix next release.
- **R-N8 — CheckHandleAvailability is limited to 10/min per uid**, and it hit the limit during your own testing.
  Watch it; debounce the client or raise the limit to 20/min.
- **R-N9 — The prod Identity Platform config isn't in Terraform.** Changes are made through the admin API and documented.
- **R-N10 — Requests rejected before auth log `xff_hops=0`.** Observability only.
- **R-N11 — The release-prod mobile artifacts use dev's Android config.** Don't distribute them.
- **R-N12 — Profile text is user-generated content, with no report or block tool and no web error telemetry.**
  Removal is by hand. Accepted for a small web launch.

## 5. Promotion procedure (any failed gate means stop and roll back per §6)
**P0 — before tagging**
1. B1 and B2 closed (§7) and §9 signed. Change the final line to GO.
2. Merge that PR.
3. `git diff --stat c19c112 <tag-commit> -- backend app proto firebase firebase.json infra Makefile` must be empty.
4. `git tag v0.1.0 <tag-commit> && git push origin v0.1.0`. This triggers `release-prod.yml`.

**P2 — after release-prod's `build-and-stage` job succeeds**
1. Record the run URL, the image digest and the rc revision name (these go into the P7 addendum).
2. Check traffic: `api-00002-fnn` at 100%, and the new revision at 0% with tag `candidate`.
3. All 7 composite indexes are `READY`, and `cloud.firestore` rules are released.
4. Smoke-test the rc URL (`https://candidate---api-jgr3aiensq-el.a.run.app`):
   - a. `/health` returns 200 `ok` (not the hello HTML), with a cold start under 1.5 s.
   - b. An unauthenticated GetMe returns 401.
   - c. With a prod test account (`accounts:signUp` using the web key and `Referer: https://dzeroth.com/`):
     - GetMe returns PROFILE_REQUIRED;
     - CheckHandleAvailability returns ok;
     - CreateProfile before verifying the email returns EMAIL_NOT_VERIFIED.
   - d. The verification email comes from `noreply@dzeroth.com` and passes DKIM and DMARC.
5. Logs Explorer: 0 entries with `severity>=ERROR` or 5xx for the rc revision.

**P3 — `promote-prod.yml` stage=10.** Watch for 15 minutes: the uptime check stays green and the P2.5 queries stay at 0.

**P4 — `promote-prod.yml` stage=100.** This builds web from the tag, shifts traffic to 100%, runs `/health` and deploys
Hosting.

**P5 — smoke-test `https://dzeroth.com` in a clean browser profile**
1. The page loads; `/privacy` returns 200; www 301-redirects to the apex; `/api/health` returns 200.
2. Email sign-up: the verification email arrives from "dZeroth" <noreply@dzeroth.com>; verify, then create the handle
   and profile, reload, and sign out and back in.
3. Google sign-in (popup) works.
4. Prod logs show `via_hosting=true` and `xff_hops=2`, with no errors.
5. The security headers are present.
6. Delete the smoke accounts (`account-deletion.md`).

**P6 — watch** at +1 h, +24 h, then daily for 7 days:
- `severity>=ERROR` = 0 and the 5xx count;
- Firestore under 2k reads/day at launch;
- instances not pinned at 3;
- budget emails;
- the uptime check;
- the `daily-maintenance` job.

**P7 — addendum.** Commit `docs/reviews/release-v0.1.0-postrelease.md` with the digest, run IDs, rc revision and the
P2–P5 results.

## 6. Rollback triggers and plan
**Triggers (any one):**
- P2 or P5 failures;
- any 5xx on smoke calls, or a 5xx ratio > 2% with at least 50 requests in any 15-minute window;
- warm p95 over twice the dev baseline (GetMe 270 ms, CheckHandleAvailability 85 ms, CreateProfile 500 ms), or a cold
  start over 3 s;
- any `severity>=ERROR` you can't explain;
- the uptime alert;
- in week 1, Firestore over 10k reads/day or 5k writes/day;
- any budget alert;
- signs of abuse (`abuse-spike.md`).

**Before 100%:** `update-traffic api --to-revisions=api-00002-fnn=100`. No client depends on it yet; fix forward with
v0.1.1.

**After 100%**, use the lightest option that works:
1. **Abuse or cost:** `DEGRADED_MODE=readonly` with the pinned-traffic procedure, and/or the sign-up kill switch.
2. **Functional bug:** fix forward with v0.1.1.
3. **Severe incident:** `firebase hosting:disable --project dzeroth-prod`, then route the API to the placeholder.

Hosting rollback is impossible for this release because there is no earlier Hosting release. Firestore needs no
rollback. Never detach billing without your explicit decision.

## 7. Blocking items
- **B1 — Degraded-mode switch: CLOSED 2026-09-28.**
  - Runbook: `docs/runbooks/cost-spike.md` now uses the pinned-traffic procedure (check the template image, update,
    `latestCreatedRevisionName`, `update-traffic --to-revisions`, then reverse).
  - Drill on `dzeroth-dev`, with traffic pinned to `api-00015-dfn=100`:
    1. `--update-env-vars DEGRADED_MODE=readonly` created `api-00016-kpf` at **0%**, which confirmed that the old
       procedure would have silently done nothing.
    2. After `update-traffic --to-revisions=api-00016-kpf=100`, CreateProfile (verified test user) returned
       `unavailable` / "the service is temporarily read-only, please try again shortly" / `ERROR_REASON_DEGRADED_MODE`,
       while GetMe returned `failed_precondition` / `ERROR_REASON_PROFILE_REQUIRED`, so reads were unaffected.
    3. Restored: `DEGRADED_MODE=off`, `update-traffic --to-latest`, now `api-00017-7xq` at 100%. The test user was deleted.
- **B2 — `docs/runbooks/abuse-spike.md`: CLOSED 2026-09-28.**
  - It covers detection, the sign-up kill switch, disabling accounts, read-only mode, tightening rate limits, the hard
    stop and ADR triggers.
  - Kill switch drilled on `dzeroth-dev` through `PATCH …/admin/v2/projects/dzeroth-dev/config?updateMask=client.permissions.disabledUserSignup`:
    1. With `true`, `accounts:signUp` with the web key returned `ADMIN_ONLY_OPERATION`.
    2. With `false`, sign-up succeeded.
    3. Test users were deleted, and the flag is back to off.
- **B3 — Founder sign-off: CLOSED 2026-09-28** (§9).

Also done: `promote-prod.yml` now requires a line that is exactly `VERDICT: GO` (`grep -qx`), so this NO-GO file
can't pass the gate by accident.
Recommended, not blocking: R-N1 (enable Error Reporting) and the R-N5 cache rule.

## 8. Release notes — v0.1.0
First public release of dZeroth (web, https://dzeroth.com).
- Sign up with email and password (email verification required before creating a profile) or with Google.
- Pick a unique handle (availability checked live) and a display name; view and edit your profile.
- Privacy policy at `/privacy`. Data requests go to privacy@dzeroth.com and are handled within 30 days.
- Platform: Go Connect-RPC API on Cloud Run (asia-south1), Firestore, Firebase Hosting, rate limits, email-verification gate.
- Known limits: no posts, follows or media yet; account deletion by email only; no mobile apps.

## 9. Sign-off (required)
I accept the risks in §4 and confirm that the B1 and B2 evidence is recorded in §7.
- [x] 2FA is enabled on GitHub account `mohamadkaifshaik`.
- [x] 2FA is enabled on the Google account that is Owner of `dzeroth-prod`.

Approved by: Kaif Mohamad Shaik (founder), in chat: "I accept the §4 risks, 2FA is on for both"  Date: 2026-09-28

VERDICT: GO
