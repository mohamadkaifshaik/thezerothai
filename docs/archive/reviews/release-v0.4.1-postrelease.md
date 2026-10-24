# Post-release record — v0.4.1 (2026-10-21)

**Released:** dZeroth v0.4.1, live at https://dzeroth.com (all times UTC, 2026-10-21). Hotfix: v0.4.0 rebuilt with Go 1.26.10, no
other change. Readiness: `release-v0.4.1-readiness.md` (VERDICT: GO).

**Why.** GO-2026-6809 (Go stdlib `crypto/x509`, found in go1.26.9, fixed in go1.26.10) is reachable under go1.26.9 via
`internal/posts/purge.go:143` `ExportUser` → `x509.Certificate.Verify`. Prod ran v0.4.0 (revision `api-00010-zah`, image
`sha256:c1a5e07ea12f9c20332f5e201bf345d4ab6c941460cdaee3f7220005da46c133`, built with go1.26.9). `main` was 209 commits ahead of
v0.4.0 and was deliberately not released.

## What was released
| Item | Value |
|---|---|
| Tag | `v0.4.1` → `d806cfe509e085f87ffb327f1bd676716cecaeb0`, which is **not on `main`**. It is tag `v0.4.0` (`b4a77a7`) + `e67de15` + `d806cfe` |
| `e67de15` | `go-version` 1.26.9 → 1.26.10 in `release-prod.yml` and in the two `setup-go` steps of `ci.yml`, plus `ci.yml` `pull_request.branches` `[main, "release/**"]` |
| `d806cfe` | the readiness review |
| Code diff | `git diff v0.4.0 v0.4.1` restricted to `backend app proto firebase firebase.json infra Makefile` is **empty** |
| Branches | `release/v0.4.1` and `release/v0.4.0-base` are kept as release lineage |
| Preparation PR | #204 was closed unmerged on purpose (see Deviations) |
| `main` | already pins go 1.26.10 since #200 (`b6b5a1a`) |
| release-prod | run 39559222475, tag pushed 07:02 by the founder |
| Image | `api:v0.4.1@sha256:c5b98dc06677cc7d7fd8fd86ef601f0e779f55257c53f2dd44b36f589ac0889a`, published 07:04 |
| Revisions | the new revision is `api-00013-qov` (traffic tag `candidate`, 0% at first); the previous one is `api-00010-zah` (v0.4.0) |
| promote-prod stage 10 | dispatched 07:16:48, run 39560872436: success, 90% `api-00010-zah` / 10% `api-00013-qov` |
| promote-prod stage 100 | dispatched 07:34:30 on the founder's instruction, run 39562941051: finished 07:37, every step successful (web bundle built from the tag, 100% traffic shifted, `/health` smoke, Hosting deployed) |

## Gates (readiness §5)
- **P2** (all pass except P2.6, which was skipped, see Deviations):
  - P2.1: the build log shows go1.26.10 and the published digest above.
  - P2.2: traffic before promotion: `api-00013-qov` 0% tagged `candidate`, `api-00010-zah` 100%.
  - P2.3: container config diff against `api-00010-zah` is empty except the image.
  - P2.4: base image digest annotation `sha256:52dcfbabb7457ea47c82f6e13af8c8a4a1d9f7b0145142b3ecab20f2b888411d` equals the recorded v0.4.0 base.
  - P2.5: 9 composite indexes READY and 4 `expireAt` TTLs ACTIVE.
  - P2.6: authenticated smoke on the candidate: **SKIPPED** at release time, **VERIFIED afterwards** on 2026-10-21 (see Deviations).
  - P2.7: candidate logs 0 errors / 0 5xx, and 0 lines containing x509, certificate or tls.
  - Extra: `/health` 200 three times on the candidate; unauthenticated GetMe 401, identical to the live service.
- **P3** (stage 10, canary 07:17-07:33):
  - `api-00013-qov`: 9 requests, 0 5xx, 0 ERROR, 0 x509/certificate/tls log lines.
  - `api-00010-zah`: 48 requests, 0 5xx.
  - Uptime check: 287 probes from 6 locations, 0 failed.
  - Firestore: 9 composite indexes READY and 4 `expireAt` TTLs ACTIVE throughout.
- **Final state, checked 07:37-07:40:**
  - Cloud Run `api` is ready at 100% `api-00013-qov` (image `sha256:c5b98dc06677cc7d7fd8fd86ef601f0e779f55257c53f2dd44b36f589ac0889a`); `api-00010-zah` is retained.
  - `/health` returns 200 on the Cloud Run URL, `dzeroth.com`, `dzeroth.com/privacy`, `dzeroth.com/api/health` and `dzeroth-prod.web.app`.
  - Hosting live version `9bdfd1db6ba943e2` (45 files, 14,817,253 bytes, released 07:37:06); previous `d648882fd8671864`.
  - Artifact Registry has `v0.1.0`, `v0.4.0` and `v0.4.1`.
  - Since 07:34 the serving revision logged 6 requests, 0 ERROR, 0 5xx, and 0 x509/certificate/tls lines.

## Deviations
- **P2.6 (authenticated smoke against the candidate) was SKIPPED** by explicit founder decision on 2026-10-21, about 07:21. It is the
  only gate that exercises outbound TLS (the JWKS fetch and Firestore), and the risk was accepted per readiness H5/H6: `/health` is a static
  handler, and prod sees about 1.7k requests/day, mostly the uptime check, so the 10% canary carries almost no signal. Compensating
  evidence: the other gates and canary checks recorded above. **The first real authenticated traffic is what exercises
  the changed code**, and it is watched below.
  **Resolved after the fact:** on 2026-10-21 at about 11:08 UTC (16:38 IST), about 3.5 hours after stage 100 finished (07:37), the founder
  ran `scripts/promotion/prod-smoke.sh` (added in #209, `445649a`) from their own terminal against the LIVE prod service URL, once for each
  of the two throwaway prod smoke accounts. Both printed `authenticated smoke: PASS`: sign-in HTTP 200, unauthenticated GetMe 401, GetMe 200
  with a profile handle, GetProfile 200 with the same handle. Server-side evidence (Cloud Logging, read-only): prod was serving
  `api-00013-qov` at 100%; in the 30 minutes around the run that revision served exactly the six smoke requests (per account: GetMe 401,
  GetMe 200, GetProfile 200, between 11:08:38 and 11:08:43 UTC); since 10:50 UTC it logged 0 ERROR, 0 5xx and 0 lines containing x509,
  certificate or `tls:`. **Proves:** a signed ID token is accepted on the live v0.4.1 build (the Google key fetch and signature verification
  work) and Firestore reads over TLS work: exactly the path GO-2026-6809 and the Go 1.26.10 change touch. **Does not prove:** any write path,
  App Check (monitor mode) or any flagged feature.
- The 15-minute stage-10 watch was honored. The readiness file's "cold start < 1.5 s" and ">= 50 requests" style gates were replaced by the
  readiness §5 P3 wording.
- **Preparation PR #204 was closed unmerged, with red CI.** The failure was the known `buf breaking` false positive (its baseline,
  `origin/main`, is 209 commits newer than v0.4.0). That early exit also skipped `govulncheck`, `osv-scanner` and the Flutter steps.
  Substitute evidence:
  - a local go1.26.10 build plus `govulncheck` v1.8.0: 0 vulnerabilities affecting the code (only GO-2026-5932 in `x/crypto`, not
    called, ignored in `osv-scanner.toml` until 2026-11-30);
  - CI under go1.26.10 passed the Go unit tests, `go vet`, the coverage gate (88%), the linter and `buf lint`.

## Smoke tooling findings and fixes
Running the P2.6 smoke after the release exposed three tooling gaps, all fixed. Runbook: `docs/runbooks/authenticated-smoke.md`.
- **Referrer-restricted web key.** The web API key is restricted by HTTP referrer, so a sign-in from a terminal (no Referer) got 403
  `API_KEY_HTTP_REFERRER_BLOCKED`; that run used the Android key (no application restriction). Fix: the script sends a Referer on the
  sign-in request only (prod default `https://dzeroth.com/`). PR #210 (`9d284b9`); see "API key restrictions (the sign-in Referer)".
- **Password reset from Git Bash.** A first reset passed the password as a command-line argument to Windows programs and produced credentials
  Google rejected. Resetting through the environment and verifying by signing in before storing fixed it. The Windows-safe procedure is
  documented since PR #210 (`9d284b9`); see "Resetting and verifying the prod smoke passwords (Git Bash on Windows)".
- **No smoke tooling in the promotion path.** The dev promotion now runs the same authenticated smoke in CI as step 4b/8 of `promote-dev.sh`
  against every 0% candidate, fail closed when promoting. PR #212 (`a45e73f`); its first run on main (deploy-dev run 39612975974) passed;
  see "Dev (CI): the authenticated smoke in deploy-dev". Prod stays a manual, founder-run step (the script plus runbook) until the
  public-repo ADR and a `v*` tag ruleset make prod secrets safe; see "Why prod credentials are NOT in GitHub yet".

Unrelated, same day: CI exposed a time bomb in the notifications test fixtures (fixed in #211, `2d17ae4`).

## Watch (P5): check daily until 2026-10-28 (owner: founder; the lead can check)
- The first authenticated traffic was exercised once on 2026-10-21 (see Deviations); the daily watch below continues to 2026-10-28.
- Logs Explorer: `resource.type="cloud_run_revision" AND resource.labels.service_name="api" AND severity>=ERROR` on `api-00013-qov` → expect 0, and 0 5xx.
- Zero log lines containing `x509`, `certificate` or `tls:`. **Any x509/TLS line means roll back immediately.**
- Firestore reads < 10k/day. The uptime check stays green.
- The first 03:00 IST `account_job backstop` line from the new revision shows `outcome=ok`.

## Rollback (kept available)
- Cloud Run: `gcloud run services update-traffic api --project=dzeroth-prod --region=asia-south1 --to-revisions=api-00010-zah=100`
  (always `--to-revisions`, never `--to-latest`). `api-00010-zah` and its image survive: the `keep-tag-v` policy protects `v*` images.
- Web: Firebase Hosting release history → version `d648882fd8671864`.

## Follow-ups (none blocks anything)
- Pin the ko base image by digest in `backend/.ko.yaml`.
- `rollback.md` says `/healthz`; use `/health`.
- Add `*.md text eol=lf` to `.gitattributes`.
- Make CI run `govulncheck` and `osv-scanner` even when an earlier `make ci` step fails.
- Give release branches a proper `buf breaking` baseline.
- Update the `release-rollout` skill and `cloud-bootstrap.md` for a PUBLIC repo, and evaluate required reviewers on the `prod` environment
  and `v*` tag rulesets via an ADR.
- The unapplied prod Terraform plan (new env vars, TTL fields) remains a separate founder decision and was not touched.
