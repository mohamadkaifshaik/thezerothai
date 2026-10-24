# Release readiness — v0.4.1 (hotfix: v0.4.0 rebuilt with Go 1.26.10 for GO-2026-6809; no code, proto, Firebase, infra or flag change)

Reviewer: `production-reviewer` (read-only), 2026-10-21. Reviewed commit: `origin/release/v0.4.1` at `e67de15` (`e67de15fbffe7a3f6757d609d1db69e1573428fc`). That is tag `v0.4.0` (`b4a77a7`) plus one commit. **Release name: `v0.4.1`. It is cut from `v0.4.0`, not from `main`.** `main` is 209 commits ahead of `v0.4.0` and is deliberately not released. PR #204 (base `release/v0.4.0-base` = `b4a77a7`) is a preparation PR only: **never merge it into `main`**.

Prod today: `api-00010-zah` (v0.4.0, image `api@sha256:c1a5e07ea12f9c20332f5e201bf345d4ab6c941460cdaee3f7220005da46c133`, built with go1.26.9) serves 100%. The `candidate` traffic tag is on `api-00010-zah`; `release-prod` moves it to the new revision. `api-00003-tiw` to `api-00007-8mq` are v0.1.0 revisions: **never route traffic to them.**

## 1. Verdicts
| Decision | Verdict |
|---|---|
| A. Tag `v0.4.1` + zero-traffic `candidate` | **GO**, once the P0 checks in §5 pass on the tag commit. This file must be committed on `release/v0.4.1` (on top of `e67de15`, not on `main`), and the tag goes on that commit. |
| B. Promote 10% → 100% | **GO, conditional:** every P2 gate in §5 must pass, **including the authenticated smoke against the candidate URL (P2.6)**, before stage=10. P3 must be clean before stage=100. Any failed gate: stop and roll back to `api-00010-zah`. The founder dispatching `promote-prod.yml` is the human approval. |

## 2. Findings and status (verified 2026-10-21 at `e67de15`)
| # | Sev | Finding | Status | Evidence |
|---|---|---|---|---|
| H1 | INFO | The diff against v0.4.0 is 2 files and 4 lines: `go-version` 1.26.9 → 1.26.10 in `release-prod.yml` and in both `setup-go` steps of `ci.yml`; `ci.yml` `pull_request.branches` `[main]` → `[main, "release/**"]` | ✅ | `git diff --stat v0.4.0 origin/release/v0.4.1`. The diff restricted to `backend app proto firebase firebase.json infra Makefile` is **empty**. `promote-prod.yml` is byte-identical to v0.4.0. `release-prod.yml` differs only in the `go-version` line |
| H2 | INFO | No `v0.4.1` tag exists (git local, origin, or Artifact Registry) | ✅ | `git tag -l`, `git ls-remote --tags origin`, `gcloud artifacts docker tags list` |
| H3 | INFO | Reason for the release, and proof the fix works | ✅ | `govulncheck v1.8.0 ./...` on the release tree, `GOOS=linux GOARCH=amd64`. **go1.26.9:** affected by GO-2026-6809 (`crypto/x509`, fixed in go1.26.10), reachable via `internal/posts/purge.go:143` `posts.FirestoreRepo.ExportUser` → `x509.Certificate.Verify`. **go1.26.10:** affected by 0; GO-2026-5932 (x/crypto, no fix) is in a required module but not called, and is ignored in `osv-scanner.toml` until 2026-11-30. The v0.4.0 release run 38107433559 log shows `go version go1.26.9 linux/amd64` |
| H4 | ACCEPTABLE | PR #204 CI run 39554433397 is red | Accepted (§7) | Passed under `go1.26.10 linux/amd64`: gofmt, `go vet`, `go test -race -shuffle=on` (32 packages ok, 0 FAIL), `pkg/platform` coverage gate **88.0%** (≥ 70%), golangci-lint, `buf lint`. **Failed:** `buf breaking` against `origin/main`. This is a false positive: `main` is newer, and `proto/` is byte-identical to v0.4.0, so a check against `v0.4.0` is trivially clean. **Skipped by the early exit:** flutter analyze/test and `make test-int` (`app/` and `backend/` trees are identical to v0.4.0, which was green, F8 in the v0.4.0 file), govulncheck (re-run by the reviewer, H3), osv-scanner (**not re-run**; `go.mod`, `go.sum` and `pubspec.lock` are unchanged since v0.4.0) |
| H5 | ACCEPTABLE, gate | `/health` is a static `ok` handler: no Firestore, no JWKS, no outbound TLS. Neither the `release-prod` smoke nor the uptime check exercises the `crypto/x509` change | Gate P2.6 | `backend/pkg/platform/health/health.go` |
| H6 | ACCEPTABLE | The 10% canary carries almost no signal. Prod serves about 1,729 2xx/day, about what the 300 s uptime check from ~6 locations produces, so 10% for 15 min ≈ 2 candidate requests, both `/health`. v0.4.0's "≥ 50 requests" gate cannot be met, and p95 on 2 samples (min 0 instances) is mostly cold start | P3 restated in §5 | Cloud Monitoring `run.googleapis.com/request_count`, 7 days: 0 5xx; daily p95 191–877 ms |
| H7 | INFO | `backend/.ko.yaml` uses `gcr.io/distroless/static-debian12:nonroot` as a **tag, not a digest**, so the base image can drift. Today it resolves (linux/amd64) to `sha256:52dcfbabb7457ea47c82f6e13af8c8a4a1d9f7b0145142b3ecab20f2b888411d`, the same base recorded in the v0.4.0 and v0.1.0 image annotations (`org.opencontainers.image.base.digest`). ko build reproducibility does not matter here: the binary changes anyway (new toolchain), so a new digest is expected | Checked again in P2.4 | Registry manifests, read-only |
| H8 | INFO | The candidate inherits the service template, which equals `api-00010-zah`'s config. Flags: `FEATURE_POSTS=off` (0%, empty allowlist), `FEATURE_ACCOUNT_LIFECYCLE=off` (0%, empty allowlist), `FEATURE_GRAPH=allowlist` (2 smoke uids, 0%; the v0.4.0 F1(a) acceptance still applies), `DEGRADED_MODE=off`, `APP_CHECK_MODE=monitor`. Scaling min 0 / max 3, 1 vCPU, 512 Mi, concurrency 80, timeout 30 s. `cursor-hmac-key` has a single enabled version. The hotfix changes no flag | ✅ (P2.3 diff) | `gcloud run services describe api`: `latestCreatedRevisionName` = `latestReadyRevisionName` = `api-00010-zah` |
| H9 | INFO | Firebase steps re-run from the tag. **Rules:** live ruleset `862cabbe-c1c3-4cf3-9c4b-b1d38f68405c` (released 2026-10-11T03:36Z) has the same content as `firebase/firestore.rules` at v0.4.0 and v0.4.1, so redeploying it creates a new ruleset with identical content. **Indexes:** 9 composite indexes READY and identical to the file; 21 field overrides match; the 4 Terraform-managed TTL overrides (`exports`, `idempotency`, `media`, `notifications` `.expireAt`) survive because the workflows do not pass `--force` (v0.4.0 run log: "there are 4 field overrides … not present in your firestore indexes file. To delete them, run this command with the --force flag"). **Hosting (stage=100 only):** a real new release, rebuilt from an `app/` identical to v0.4.0 with Flutter 3.47.5 pinned by SHA; the current live version is `d648882fd8671864` (2026-10-11, 45 files, about 14.8 MB) and is the rollback target. PROD_* repo variables are unchanged since 2026-09-27 | ✅ | Firebase Rules and Hosting REST (GET), `gcloud firestore indexes composite list` / `fields list`, `gh variable list` |
| H10 | INFO | Rollback image retention. `api:v0.4.0` = `sha256:c1a5e07…` exists. Cleanup policies are live (no dry-run): `keep-tag-v` (prefix `v`), `keep-last-3`, `keep-tag-last-good`, `delete-tagged-after-30d`, `delete-untagged-after-1d`. **`keep-tag-v` is load-bearing:** without it, `delete-tagged-after-30d` would delete the v0.4.0 image around 2026-11-10. Do not change it during this release | ✅ | `gcloud artifacts repositories describe api` |
| H11 | INFO | Pipeline gates. Live WIF `github-deploy/github` condition: `repository == 'mohamadkaifshaik/thezerothai'`, `ref` starts with `refs/tags/v`, `job_workflow_ref` starts with `…/release-prod.yml@refs/tags/v` or `…/promote-prod.yml@refs/tags/v`, and `environment == 'prod'`. GitHub env `prod` has one deployment policy, `v*` (type tag). Nothing checks the branch, so a tag on a commit that is not on `main` works. On a tag push only `release-prod.yml` fires (`deploy-dev`: push to main; `terraform`: PR to main; `ci`: PR) | ✅ | `gcloud iam workload-identity-pools providers describe`, `gh api …/environments/prod` |
| H12 | INFO | The repo is **PUBLIC**, but the release-rollout skill and `cloud-bootstrap.md` §6a assume a private repo. Consequences: Actions minutes, including macOS, are $0; public-repo features (environment required reviewers, tag rulesets) may already be available on GitHub Free, which weakens the "accepted gap" premise; nothing in this file may contain PII or uids | Post-release ADR | `gh repo view --json visibility` |
| H13 | INFO | Operability. The Error Reporting API is now **enabled** (v0.4.0 F13 closed). Uptime check `api /health (prod)` (300 s) passed fraction 1.0. Alert policies enabled: Firestore reads > 40k/day, 5xx > 0.05 req/s, Auth mutations, uptime. Budget "Stage 0 budget (prod) 500 INR/mo", alerts at 25/50/90/100% actual and 100% forecast → `billing-alerts`. 7-day prod baseline: 0 ERROR, 0 5xx, 28 WARNING (404s) | ✅ | `gcloud services list`, Monitoring REST, Budgets REST, Logging `entries:list` |
| H14 | INFO | `ci.yml` trigger widened to `release/**`: `permissions: contents: read`, no secrets, no `pull_request_target`. Safe on a public repo | ✅ | `ci.yml` at `e67de15` |
| H15 | INFO | `rollback.md` "After any rollback" says to confirm `/healthz`, which `*.run.app` never routes to the container (CLAUDE.md rule 8). Use `/health` | Follow-up on `main` | — |
| H16 | INFO | Supporting evidence only: dev has served go1.26.10 builds of `main` since #200 (`b6b5a1a`, 2026-10-21 10:42 IST), with 0 ERROR/5xx since | — | Logging, `dzeroth-dev` |
| H17 | ACCEPTABLE | `core.autocrlf=true`, and `.gitattributes` does not cover `*.md`. A CR on this file's last line would make `promote-prod` fail closed (whole-line match) | P0.3 | `git config`, `.gitattributes` |

**Carried over from v0.4.0 unchanged (same code):** F1(a) graph allowlist (2 smoke accounts), F6 monitoring cost (prod), L-5, F4 M2 (dormant), F14 web-only (AAB/IPA not distributed), F15 HashUID, F10–F12/F20 flag-ramp prerequisites, R-2/R-P1. Security, test and code-review status is as recorded in `release-v0.4.0-readiness.md` §4. No source changed, so nothing new needs review.

## 3. Founder decisions
- The lead's brief (2026-10-21) asks for a toolchain-only hotfix from `v0.4.0`, not a release from `main`.
- The founder pushes the tag and runs `promote-prod.yml` (stage=10, then stage=100). Nothing shifts traffic automatically: `release-prod.yml` only stages at 0%, and `promote-prod.yml` is `workflow_dispatch` only.
- The H4/H6 acceptances in §7 take effect when the founder pushes `v0.4.1` after reading this file. **If the founder does not accept them, do not push the tag.**

## 4. Lead verifications (re-verified independently by the reviewer, 2026-10-21)
1. Diff is exactly 2 files: ✅ (H1).
2. Diff restricted to `backend app proto firebase firebase.json infra Makefile` is empty: ✅ (H1).
3. No `v0.4.1` tag: ✅ (H2).
4. Go 1.26.10 build and `govulncheck`: ✅. Backend builds for linux/amd64 with go1.26.10; `govulncheck v1.8.0` reports 0 affecting (only GO-2026-5932, not called); go1.26.9 reproduces GO-2026-6809 (H3). CI run 39554433397 passed Go unit tests (`-race`), vet, the coverage gate (88.0%) and buf lint under go1.26.10 (H4).
- Correction: `main` is **209** commits ahead of `v0.4.0` (#203 landed at 11:39 IST). Not material.

## 5. Commands (P0 before tag; P2 to P5 after)
```
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"
P="--project=dzeroth-prod --region=asia-south1"
```
On this Windows machine `gcloud.cmd` mis-parses filters that contain `>=`. Run log queries in the Cloud Console Logs Explorer, or through the Logging REST API.

**P0 (before tagging):**
1. Commit this file on `release/v0.4.1` on top of `e67de15`. Do not merge PR #204, and do not put this commit on `main`. Let `<T>` be that commit.
2. `git diff --stat e67de15 <T>` must list **only** `docs/reviews/release-v0.4.1-readiness.md`. Also `git diff --stat v0.4.0 <T> -- backend app proto firebase firebase.json infra Makefile .github/workflows/promote-prod.yml` must be empty.
3. Last-line bytes: `MSYS_NO_PATHCONV=1 git show <T>:docs/reviews/release-v0.4.1-readiness.md | tail -n 1 | od -c` must show the verdict text followed by `\n`, with **no `\r`** (12 bytes). The workflow does a whole-line match; a CR fails closed.
4. `git push origin release/v0.4.1`, then `git tag v0.4.1 <T> && git push origin v0.4.1`. Record the `release-prod` run ID.

**P2 (after `build-and-stage`; stop on any failure; each item is required):**
1. Build log shows `go version go1.26.10 linux/amd64`, and `Published …/api/api:v0.4.1@sha256:<D>`. Record `<D>`.
2. `"$G" run services describe api $P --format='yaml(status.traffic)'`: `api-00010-zah` at 100% (no tag), and a **new** revision `api-000NN` (NN > 10) at 0% tagged `candidate`.
3. Config equality, which must print nothing: `diff <("$G" run revisions describe api-00010-zah $P --format=json | jq -S '.spec.containers[0] | del(.image)') <("$G" run revisions describe <rc> $P --format=json | jq -S '.spec.containers[0] | del(.image)')`. The flags in H8 must be unchanged. The startup `feature_flags` log line on `<rc>` must match.
4. Base image: the manifest annotation `org.opencontainers.image.base.digest` of `api@<D>` must equal `sha256:52dcfbabb7457ea47c82f6e13af8c8a4a1d9f7b0145142b3ecab20f2b888411d`. Read-only command: `curl -s -H "Authorization: Bearer $("$G" auth print-access-token)" -H 'Accept: application/vnd.oci.image.manifest.v1+json' https://asia-south1-docker.pkg.dev/v2/dzeroth-prod/api/api/manifests/<D> | jq .annotations`. If it differs, stop: the base (CA roots, tzdata) changed underneath an x509 fix. Get an explicit founder OK before continuing.
5. `"$G" firestore indexes composite list --project=dzeroth-prod`: 9 READY. Field overrides still include the 4 `expireAt` TTLs (`ACTIVE`).
6. **Authenticated smoke on `https://candidate---api-jgr3aiensq-el.a.run.app`.** This is the only gate that exercises outbound TLS (JWKS fetch and Firestore over TLS):
   - `/health` returns 200, with cold start < 1.5 s.
   - `POST /dzeroth.identity.v1.IdentityService/GetMe` with `{}` and no token returns 401 (`unauthenticated`).
   - GetMe, then `GetProfile` (`{"user_id": …}`), with a smoke account's ID token return 200 with the existing profile.
   - `E2E_GRAPH_BASE_URL=<candidate URL> E2E_GRAPH_ID_TOKEN_A=… E2E_GRAPH_ID_TOKEN_B=… go test ./e2e -run TestE2E_GraphSmoke_FollowListBlockUnblock` passes (smoke accounts only).
7. Logs for `resource.labels.revision_name="<rc>" AND (severity>=ERROR OR httpRequest.status>=500)` return 0, and there is no line containing `x509`, `certificate` or `tls:`. The Error Reporting console (now enabled) shows nothing for `<rc>`.

**P3 (`promote-prod.yml` from tag `v0.4.1`, stage=10; watch ~15 min).** The canary carries almost no signal (H6); P2.6 is the real gate. Pass criteria:
- 0 5xx and 0 ERROR on `<rc>`, and no TLS/x509 error strings.
- Uptime check stays green.
- `api-00010-zah` is unaffected.
- p95 is noted but does not decide anything at this volume. Optional: re-run the P2.6 GetMe against the main URL a few times.
- **Rollback triggers:** any 5xx or ERROR on `<rc>`, any TLS/x509 error, an uptime failure, or a failed workflow step.

**P4 (stage=100):** founder dispatch.
- The run rebuilds the web bundle from the tag, shifts 100% to the verified `<rc>`, smokes `/health`, then deploys Hosting.
- Record the new Hosting version ID and file count (expect 45 files, about 14.8 MB, as in `d648882fd8671864`).
- Record the web bundle size.

**P5:**
- `dzeroth.com` loads in a clean profile, and Google sign-in works.
- `/privacy` and `/api/health` return 200.
- After the next 03:00 IST run, the `account_job backstop outcome=ok` line appears from the new revision.
- 24 h and 7 days: ERROR/5xx = 0, Firestore < 10k reads/day.
- Write `docs/archive/reviews/release-v0.4.1-postrelease.md`.

## 6. Rollback
- **Cloud Run (seconds):** `"$G" run services update-traffic api $P --to-revisions=api-00010-zah=100`. Always `--to-revisions`, never `--to-latest`. `api-00010-zah` and its image `api:v0.4.0@sha256:c1a5e07…` both survive: revisions are never deleted by a deploy, and `keep-tag-v` protects the image (H10).
- **Data compatibility:** none expected. The source is identical, and both revisions are P8-aware with the same `/internal/*` handlers. The `rollback.md` v0.1.0 caveat does not apply because neither side is v0.1.0. Pub/Sub push and Scheduler follow the traffic split, with identical handlers.
- **Firestore rules and indexes:** nothing to roll back (identical content, H9).
- **Web (only if stage=100 ran):** Firebase console → Hosting → release history → roll back to version `d648882fd8671864` (2026-10-11), or `firebase hosting:clone dzeroth-prod:@d648882fd8671864 dzeroth-prod:live`.
- After any rollback, confirm `/health` (not `/healthz`, see H15), the uptime check, and Error Reporting.

## 7. Risks accepted
| Risk | Basis | Status |
|---|---|---|
| H4: red CI on the release commit. `buf breaking` against `main` is a false positive; flutter, test-int, govulncheck and osv-scanner were skipped | Source trees identical to the green v0.4.0 release; Go unit tests, `-race`, vet, coverage and lint green under go1.26.10; govulncheck re-run by the reviewer (H3). **osv-scanner was not re-run**: dependency manifests are unchanged since v0.4.0, so any new finding would equally affect what prod serves today and is not a regression | Accepted by production-reviewer on this evidence; effective when the founder pushes the tag (§3) |
| H5/H6: weak automated smoke and canary | Replaced by the required authenticated candidate smoke (P2.6) and the error and TLS log checks | Accepted with the gate |
| H7: unpinned ko base image | Verified identical today; checked again in P2.4 before any traffic | Accepted. Follow-up: pin by digest on `main` |
| Stage=100 redeploys Hosting from identical `app/` source | Same Flutter SHA and lockfile; one-click Hosting rollback to `d648882fd8671864` | Accepted |
| Mobile jobs (`build-android`, `build-ios` on macOS) run on the tag; nothing ships from them | $0 on a public repo (H12). Cancelling is optional and harmless, but `gh run cancel` cancels the whole run, so only cancel after `build-and-stage` is green | Accepted; recommendation: let them finish |
| v0.4.0 carry-overs (F1(a), F6, L-5, F4 M2, F14, F15, R-2/R-P1) | Code unchanged | Unchanged from `release-v0.4.0-readiness.md` §7 |

**Cost:** $0 expected.
- One extra revision (min 0, scales to zero).
- About 15 MB extra in Artifact Registry (total about 43 MB of the 0.5 GB free).
- About 15 MB extra Hosting storage (10 GB free).
- Rules and index deploys are free.
- A few Firestore reads for the smoke.
- Actions minutes are free (public repo).
- No new resource, no Terraform change, no flag change.

## 8. Pre-tag actions (v0.4.0 §8, mapped to v0.4.1)
1. *v0.4.0 #1, Deploy-dev green on the release commit:* **N/A.** Dev runs `main`, not `release/v0.4.1`. Supporting evidence is H16.
2. *v0.4.0 #2, merge the PR carrying this file to `main` and tag that merge commit:* **Replaced.** Commit this file on `release/v0.4.1` only (PR #204 is never merged to `main`), run P0.2 and P0.3, then tag `<T>`. **Pending (owner).**
3. *v0.4.0 #3, `gh workflow run CI` on the tag commit:* **Not useful.** It would hit the same `buf breaking` false positive. Covered by H4.
4. *v0.4.0 #4, enable Error Reporting in prod:* **Done** (H13).
5. *v0.4.0 #5, post-release follow-ups:*
   - F22 addendum: still open.
   - F17, add `buf breaking` against the last release tag (or the PR base branch) to the gate: **now more urgent**, because it caused this red CI.
   - Founder may ratify or reverse delegated acceptances: still open.

**New post-release follow-ups (non-blocking, on `main`):**
- Pin the ko base image by digest (H7).
- Fix `/healthz` → `/health` in `rollback.md` (H15).
- Update the release-rollout skill and `cloud-bootstrap.md` for a PUBLIC repo, and evaluate required reviewers and `v*` tag rulesets via ADR (H12).
- Add `*.md text eol=lf` to `.gitattributes` (H17).
- Make CI run govulncheck and osv-scanner even when an earlier `make ci` step fails.

**Founder pre-conditions remaining:** the owner commits this file and pushes tag `v0.4.1`; the owner runs `promote-prod.yml` from the tag with stage=10, watches, then runs it again with stage=100. Nothing shifts traffic automatically.

VERDICT: GO
