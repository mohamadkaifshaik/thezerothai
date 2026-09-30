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
     `setup-gcloud`, `ko-build/setup-ko`, `setup-node`, `setup-go`, `flutter-action`, `upload-artifact`). CI on the PR
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

## Still unpinned (tracked, not covered by Dependabot)
Tool versions downloaded at run time: `govulncheck@latest` (ci.yml), `firebase-tools@15` (major only; ci, deploy-dev,
release-prod, promote-prod), `ko` and `gcloud` (setup actions with no `version:` input, so latest), `go 1.26.x`,
`node 20`, `java 21` (floating patch). Already exact: terraform 1.16.2, tflint v0.53.0, golangci-lint v2.14.0,
buf 1.47.2, flutter 3.47.5. Candidates for a follow-up: pin govulncheck and firebase-tools exact, set `version:` on
setup-ko and setup-gcloud, and add osv-scanner (remaining part of L6).

## Optional repo setting
Settings > Actions > General > "Require actions to be pinned to a full-length commit SHA" makes GitHub reject any
unpinned `uses:`. Enable it after this PR merges and one dependabot Actions PR has landed cleanly.
