# Dependency updates and pinned Actions

Closes the v0.1.0 risk acceptances L6 (Dependabot off) and L7 (Actions pinned by tag, not SHA). Both were due
2026-10-12. Cost: $0 (Dependabot is free).

## What is in place
- `.github/dependabot.yml` opens weekly PRs (Monday 04:00 IST, max 5 open per ecosystem) for `gomod` (`/backend`),
  `pub` (`/app`), `github-actions` (`/`) and `terraform` (`/infra/terraform/envs/dev`, `envs/prod`, `modules/*`).
  Minor and patch bumps are grouped into one PR per ecosystem; majors arrive one per PR. Labels: `dependencies` plus
  `go`, `flutter`, `github-actions` or `terraform`. There is no `go.work`; the Go module root is `backend/`.
- Every third-party `uses:` in `.github/workflows/*.yml` is a full 40-character commit SHA with the release as a
  trailing comment: `uses: actions/checkout@<sha> # v4.4.0`. Dependabot's github-actions ecosystem updates both the SHA
  and the comment.

## Reviewing a Dependabot PR
1. Read the release notes linked in the PR. For Actions, look for changed inputs, new Node runtime requirements and
   permission changes.
2. Check the PR's own CI. The PR runs `ci.yml` (lint, tests, buf, govulncheck) and `terraform.yml` (plan for dev and
   prod; a provider bump must produce **no unexpected diff**).
3. Extra care for anything on the release path:
   - Actions used by `deploy-dev.yml`, `release-prod.yml`, `promote-prod.yml` (`google-github-actions/auth`,
     `setup-gcloud`, `ko-build/setup-ko`, `setup-node`, `setup-go`, `.github/actions/setup-flutter`, `upload-artifact`). CI on the PR
     does **not** run these workflows. Merge such PRs on a day you can watch the next `main` push (deploy-dev) and
     do not merge them between tagging a release and finishing promotion.
   - Terraform provider bumps: read the plan; never apply as part of the merge (apply stays a separate, approved step).
   - Go: a minor bump touching `firebase.google.com/go`, `cloud.google.com/go/*` or `connectrpc.com/*` needs
     `make test-int` locally.
4. Verify a new Actions SHA before merging (Dependabot's are trustworthy, but a manual bump is not):
   `gh api repos/<owner>/<repo>/commits/<sha> --jq .sha` must echo the same SHA, and the tag it claims must resolve to it
   (`gh api repos/<owner>/<repo>/git/ref/tags/<tag>`; if `object.type` is `tag`, follow `/git/tags/<sha>` once more).
5. Squash-merge once green. Never merge a red dependency PR to "fix it later".

## Re-pinning an Action by hand
```
gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.type + " " + .object.sha'
# if the type is "tag" (annotated), dereference:
gh api repos/<owner>/<repo>/git/tags/<sha> --jq '.object.sha'
gh api repos/<owner>/<repo>/commits/<final-sha> --jq .sha      # must echo the SHA
```
Edit the `uses:` line to `@<40-char-sha> # <tag>`. Keep the major version unless you mean to upgrade; some actions
(`bufbuild/buf-setup-action@v1`) publish the major as a branch, so resolve the exact `vX.Y.Z` tag on the same commit.
Do not pin to a branch name or a short SHA.

## Pinned tool versions (NOT covered by Dependabot: bump by hand)
Run-time tools are pinned to exact versions so a compromised or breaking "latest" cannot reach CI or the release path
(closes the remainder of L6, issue #46). Bump them deliberately, roughly monthly or when osv-scanner/govulncheck asks.

| Tool | Where | Current | How to find and verify the next version |
|---|---|---|---|
| govulncheck | `ci.yml` (`go install ...@vX.Y.Z`) | v1.8.0 | `curl -s https://proxy.golang.org/golang.org/x/vuln/@latest` |
| firebase-tools | `ci.yml`, `deploy-dev.yml` (x2), `release-prod.yml`, `promote-prod.yml` (`npm install -g firebase-tools@15.x.y`) | 15.32.0 | `npm view firebase-tools@15 version` (take the last line); a new major also needs the Java version in ci.yml checked |
| ko | `setup-ko` `version:` in `deploy-dev.yml`, `release-prod.yml` (tag with leading `v`) | v0.19.1 | `gh api repos/ko-build/ko/releases/latest --jq .tag_name` (repo is `ko-build/ko`, formerly `google/ko`) |
| gcloud (Cloud SDK) | `setup-gcloud` `version:` in `deploy-dev.yml`, `release-prod.yml`, `promote-prod.yml` | 587.0.0 | `curl -s https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json` (first `"version"`), then `curl -sI https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-<v>-linux-x86_64.tar.gz` must be 200 |
| osv-scanner | `ci.yml` env `OSV_SCANNER_VERSION` + `OSV_SCANNER_SHA256` | v2.6.0 | `gh release download <tag> -R google/osv-scanner -p osv-scanner_SHA256SUMS -O -` and copy the `osv-scanner_linux_amd64` hash |
| Flutter SDK | local action `.github/actions/setup-flutter` (`version:` and `sha:` inputs) in `ci.yml` (env `FLUTTER_VERSION`), `deploy-dev.yml`, `release-prod.yml` (x2), `promote-prod.yml` | 3.47.5 / `6a19cca5…1da1` | `git ls-remote https://github.com/flutter/flutter.git refs/tags/<v>`; bump `version` and `sha` together in every call site (the action fails if the tag no longer resolves to `sha`). We do not use `subosito/flutter-action`: its nested `actions/cache@vN` is rejected by the repo's SHA-pinning setting. |

Bump procedure: change every occurrence (grep the tool name in `.github/workflows`), run `actionlint`, open a PR. The PR's
CI exercises govulncheck, firebase-tools (emulator job) and osv-scanner. It does **not** exercise the release path
(`release-prod.yml`, `promote-prod.yml`, and `deploy-dev.yml` until merged): after merging a bump that touches ko,
gcloud or firebase-tools, watch the next `main` deploy-dev run, and for prod, a tagged rc build before promotion.
Still floating: `go 1.26.x` (deliberately, for stdlib security patches), `node 20`, `java 21`. Already exact: terraform
1.16.2, tflint v0.53.0, golangci-lint v2.14.0, buf 1.47.2, flutter 3.47.5.

## osv-scanner
Step "osv-scanner (go.mod + pubspec.lock)" in `ci.yml` scans `backend/go.mod` and `app/pubspec.lock` against osv.dev and
**fails on any finding** not listed in `osv-scanner.toml`. It is fail-on-any because OSV frequently has no CVSS score for
Go advisories, so a High/Critical threshold would pass everything. Call analysis is disabled; `govulncheck` (blocking) is
the reachability gate.
- Ignores are per-ID, carry a `reason`, and have `ignoreUntil` (currently GO-2026-5932 x/crypto and GO-2026-6443 grpc,
  until 2026-11-30, both unreachable per govulncheck). Never add a blanket ignore. When one expires, the job fails:
  re-check, then either bump the dependency (preferred) or renew with a fresh reason.
- Run locally from the repo root: `osv-scanner scan --config=osv-scanner.toml --no-call-analysis=go -L backend/go.mod -L app/pubspec.lock`.

## Repo setting (founder, GitHub UI; not done by any agent)
Turn on "Require actions to be pinned to a full-length commit SHA" only after this PR is merged and the next `main`
deploy-dev run is green (all `uses:` are already SHA-pinned, so nothing should break):
1. Repo > Settings > Actions > General.
2. Under "Workflow permissions / Actions permissions", tick **Require actions to be pinned to a full-length commit SHA**.
3. Save. Verify by re-running the latest `ci.yml` run on `main` (it must still start). If a workflow fails with "action is
   not pinned to a full-length commit SHA", that `uses:` was missed: pin it (see "Re-pinning an Action by hand").
4. Roll back by unticking the box (no data impact).
