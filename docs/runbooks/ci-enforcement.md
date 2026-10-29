# CI enforcement and review gates: Option 2, a separate identity for the assistant (PROPOSAL, nothing enabled)
Status: draft for founder review, 2026-10-20. **No GitHub setting, ruleset, App or credential has been changed or created.**
Decision (founder, 2026-10-20): technical separation with a dedicated GitHub App or bot identity and **no bypass actors**; code owner
`@mohamadkaifshaik`. The solo-owner bypass option is rejected.
Update 2026-10-22: sections 6-9 were applied (see section 9); sections 11-12 below describe the current required checks, the tag ruleset
and how bot PRs are approved.

## 1. State today (read-only checks)
- Ruleset `main - Production protection` (id 24070946): **enforcement disabled**, targets `~DEFAULT_BRANCH` **and `~ALL`**, 1 approving
  review, empty required-check list, no bypass actors. It must not be enabled as it is (it would refuse pushes to every branch and,
  with one collaborator and no bypass, block every merge).
- No classic branch protection on `main`. One collaborator. CI is advisory: a red PR can merge, and a direct push to `main` runs
  `deploy-dev.yml` without PR checks.
- `gh` on this machine is logged in as the owner (keyring, scopes `repo`, `workflow`, `gist`, `read:org`); git uses Windows Credential
  Manager. The assistant runs as the same OS user, so **today every PR the assistant opens is authored by, and can be approved/merged
  by, the owner's own credential.**

## 2. What "technical separation" requires (read this first)
A second GitHub identity separates author from reviewer **only if the assistant cannot reach the owner's credential.** The assistant
runs under the owner's Windows account, where the owner's `gh` keyring login and the Credential Manager entry live. Therefore:
1. The assistant's `gh`/`git` must use the **App's installation token only** (via `GH_TOKEN` in its session environment).
2. The owner's GitHub login must **not be available** to the assistant's process: either run the assistant under a **separate Windows
   user** (or a container/VM) that has no owner credentials, or at minimum `gh auth logout` and remove the `git:https://github.com`
   Credential Manager entry from the profile the assistant uses, and do owner-only actions (approvals, merges of gated PRs, settings)
   in the browser or a different Windows user. Without this, the second identity is cosmetic.
3. The owner remains able to do everything in the browser. The assistant loses: environment/secret/ruleset administration (it did
   these with the owner's token before; they become owner actions), and merging gated PRs.
This is a real change of working mode. Cloud (gcloud/Terraform) credentials are a separate question and are not changed by this document.

## 3. The second identity: a GitHub App (recommended) vs a machine user
| | GitHub App `dzeroth-agent` (recommended) | Machine user account + fine-grained PAT |
|---|---|---|
| Credential | private key (RS256) minted into a 1-hour installation token | PAT, up to 1 year |
| Scope | installed on this repository only, permissions chosen per category | repo-scoped PAT, permissions per category |
| Seat / ToS | none; an App is the sanctioned automation identity | free "machine account", ToS-allowed but a user |
| Blast radius if leaked | key alone is useless without minting; token lives 1 h | PAT usable until revoked/expired |
| Cost | $0 | $0 |
Pick the App. Creating it is an owner action in the GitHub UI (the assistant cannot and should not create it).

### Least-privilege permissions (repository permissions; everything else "No access")
| Permission | Level | Why |
|---|---|---|
| Metadata | Read | mandatory |
| Contents | Read and write | push branches, open PRs (cannot push to `main`: the ruleset blocks it) |
| Pull requests | Read and write | open/update/comment, merge PRs that satisfy the rules |
| Workflows | Read and write | needed to push changes under `.github/workflows/`; **those files are CODEOWNERS-protected**, so the owner approves every such change |
| Checks / Commit statuses / Actions | Read | read CI results and logs |
| Issues | Read and write (optional) | issue comments for follow-ups |
**Explicitly NOT granted:** Administration (rulesets, branch policies, collaborators), Environments, Secrets, Variables, Deployments,
Pages, Packages, Security events, Organization anything. Consequences: the assistant cannot change rulesets, environment settings,
secrets or variables, and cannot approve its own PR (an App cannot be a code owner unless named).
Installation: **only this repository**.

### Credential handling
- Private key (`.pem`) generated once; stored **outside the repo and outside any synced folder**, in a directory only the assistant's
  Windows user can read (`icacls` to remove inheritance); never printed, committed, pasted into chat, or passed on a command line.
- A small script mints the token: sign a JWT (`iat` now-60 s, `exp` <= 9 min, `iss` = App id) with `openssl`, call
  `POST /app/installations/{id}/access_tokens` (no body: the token carries the App's installed permissions on this repository only, and
  scoping is done in the App settings), export the result as `GH_TOKEN` for the session only. The token is never written to disk or logs (it is masked in any output). The script is `scripts/mint-app-token.sh`
  (CODEOWNERS-protected, since it mints the assistant's credentials).
- Commits use a bot identity (`<app>[bot]` noreply email) plus the existing `Co-Authored-By` trailer; git pushes over HTTPS with the token.
- Rotation: generate a second private key in the App settings, switch, delete the old key (the App supports two at once). Every 90 days
  or on any suspicion. Revocation: delete the key (instant for new tokens; existing ones expire within 1 h) or suspend/uninstall the App.
- Recovery: the owner regenerates a key and reinstalls; nothing the assistant holds is irreplaceable. Data/loss impact: none, the App
  owns no resources.

## 4. Review flow after the change
1. The assistant (App identity) opens a PR; required check `promotion scripts (...)` must pass.
2. The owner approves every assistant PR in the UI (`require_last_push_approval`, see section 6 and test 9). Then the owner (or the
   assistant, once approved) merges.
3. An assistant PR can never be merged without that approval, and direct pushes to `main` are refused. Gated files (CODEOWNERS) need the
   same owner approval; the assistant cannot supply it and the ruleset has no bypass.
4. Owner-only operations (settings, secrets, environments, ruleset edits, tags/releases that need admin): the owner runs them, e.g. via
   `! gh api ...` in their own session, not through the assistant.
5. Dependabot PRs are authored by Dependabot; the owner approves/merges as before.

## 5. Verification matrix (to run BEFORE the ruleset is enabled, with the App token, on a throwaway branch/PR)
| # | Test | Expected |
|---|---|---|
| 1 | `gh api user`/`repos/.../` identity | `dzeroth-agent[bot]`, not the owner |
| 2 | push a branch and open a PR | allowed |
| 3 | `gh api repos/.../rulesets` (read) / `PUT` a ruleset | read ok at most; **write refused (403)** |
| 4 | `gh secret set X --env dev` | **refused** |
| 5 | `gh api -X PUT repos/.../environments/dev` | **refused** |
| 6 | approve its own PR | **refused/ineffective** |
| 7 | after the ruleset: push to `main` directly | **refused** |
| 8 | after the ruleset: merge a PR changing `firebase/field-overrides.ack` without the owner's approval | **refused** |
| 9 | after the ruleset: merge an ordinary PR with a green required check | allowed |
| 10 | after the ruleset: the owner approves a gated PR in the UI, then merge | allowed |
| 11 | the owner's token is not reachable from the assistant's process (`gh auth status`, Credential Manager entry absent) | confirmed |
Test 11 is the one that makes the rest meaningful.

## 6. Ruleset (applied 2026-10-20 by the owner as ruleset 24070946; JSON below is the proposal it was applied from)
Verified read-only: the required check is reported under the exact name `promotion scripts (shellcheck, actionlint, fixture tests, flag
registry)` by GitHub Actions (`app.id` 15368, from `GET /commits/{sha}/check-runs` on PR #175's head), so the rule pins that `integration_id`.
```bash
gh api -X PUT repos/mohamadkaifshaik/thezerothai/rulesets/24070946 --input - <<'JSON'
{
  "name": "main - required check and code-owner review",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": true,
      "require_last_push_approval": true,
      "required_review_thread_resolution": false}},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "do_not_enforce_on_create": false,
      "required_status_checks": [{"context": "promotion scripts (shellcheck, actionlint, fixture tests, flag registry)", "integration_id": 15368}]}}
  ]
}
JSON
# rollback: the same body with "enforcement": "disabled"
```
- Scope: default branch only. PRs required (this also blocks direct pushes), non-fast-forward and deletion blocked, **no bypass actors**.
- `require_last_push_approval: true`: the approver must not be the last pusher, so approve-then-push is impossible; stale approvals are
  dismissed on every push.
- **Correction after testing (2026-10-20):** with `required_approving_review_count: 0`, `require_last_push_approval: true` makes GitHub
  block **every** App PR until the owner approves (test 9: an ordinary docs PR with a green required check stayed `BLOCKED`, `reviewDecision`
  empty). The effective policy is therefore "the owner approves every assistant PR". Code-owner enforcement on its own was **not isolated**:
  test 8 was blocked, but test 9 shows the block does not depend on CODEOWNERS. To isolate it, drop `require_last_push_approval` later and
  re-test 8 and 9 (8 should stay blocked, 9 should merge).
- Not covered by this ruleset: tags (now a separate ruleset, see section 11), the `prod` environment's own tag policy, anything pushed
  with a token that has Administration.

## 7. Roll-out order (each step needs the owner)
1. Owner reviews this document and PR #176 (CODEOWNERS covers the ack, the check script, `firestore.indexes.json`, `flag-ceiling.json`,
   every file under `.github/workflows/`, `scripts/mint-app-token.sh`, `/CLAUDE.md`, `/.claude/`, and CODEOWNERS itself).
2. Owner creates the App (permissions in section 3), installs it on this repository only, stores the key per section 3, and sets up the
   separate Windows user (or removes their credential from the assistant's profile).
3. Run the verification matrix tests 1-6 and 11.
4. Owner applies the ruleset above; run tests 7-10.
5. If anything is wrong: set `enforcement` to `disabled` (rollback), fix, retry.
Ruleset applied 2026-10-20; matrix tests 1-6, 11 passed.

## 8. The `field-overrides.ack` hash
The failing check prints the expected hash, so an author can paste it. With this setup that is fine: the ack is CODEOWNERS-protected,
the author is the App, and the owner sees and approves the ack diff. The hash is a tripwire; the approval is the control.

## 9. Results (2026-10-20)
Run by the assistant with the App installation token (owner authorized each step), after the ruleset was applied for tests 7-10.
| # | Result | HTTP / evidence |
|---|---|---|
| 1 | Pass | `GET /user` is **403** as expected for installation tokens; the throwaway PR's author was `dzeroth-agent[bot]` (type `Bot`) |
| 2 | Pass | branch pushed, draft PR opened |
| 3 | Pass (refused) | ruleset read **200**; `PUT` of the unchanged ruleset body **403** |
| 4 | Pass (refused) | `gh secret set X --env dev`: **403** on `environments/dev/secrets/public-key` |
| 5 | Pass (refused) | `PUT environments/dev`: **403** |
| 6 | Pass (refused) | approving its own PR: **422** "Review Can not approve your own pull request" |
| 7 | Pass (refused) | `git push origin main` rejected for repository rule violations; required check expected |
| 8 | Pass (refused) | PR #188 (`.github/CODEOWNERS`, required check green): merge refused, `mergeStateStatus` `BLOCKED` |
| 9 | Refused until owner approval | PR #189 (ordinary docs file, required check green): `BLOCKED` until approved, see section 6 |
| 10 | Pass | owner approval, then `CLEAN`, then merged (#188, #189) |
| 11 | Pass | see below |
Test 11 (the owner's credentials are not reachable from the assistant's process):
- `gh auth status` reports "not logged into any GitHub hosts"; `cmdkey /list` has no GitHub entry (verified by the assistant).
- Residual-credential check: no `~/.git-credentials`; no `~/.ssh`; no `GH_TOKEN`, `GITHUB_TOKEN` or `GH_ENTERPRISE_TOKEN` in the
  user environment (user variables are only `OneDrive`, `Path`, `TEMP`, `TMP`) or the process environment; the global git config has no
  `credential`, `insteadOf` or `url.*` keys.
- Reported by the owner: `claude-agent` is not an administrator; the owner's home directory, `gh` config and repository ACLs exclude
  `claude-agent`; `.dzeroth-agent` is denied to the owner.

## 10. Operational notes
- Git Bash rewrites leading-slash API paths (`/installation` becomes `C:/Program Files/Git/installation`): set `MSYS_NO_PATHCONV=1` or
  omit the leading slash.
- `scripts/mint-app-token.sh` converts `APP_KEY` with `cygpath -m`, so `openssl` can open the key when `MSYS_NO_PATHCONV=1` is set.
- Installation tokens get **403** on `/user` and **404** on `/installation`; read installation details with `/app/installations/{id}`
  and the App JWT instead.
- `repository.permissions` from the API can show all `false` for an installation token; rely on the refusal tests (3-5), not that field.

## 11. Required checks, make test-int and tags (current)
- **Required status checks** of the main ruleset (24070946): `make ci (lint, vet, unit tests, buf breaking, flutter analyze/test)` and
  `promotion scripts (shellcheck, actionlint, fixture tests, flag registry)`, both reported by GitHub Actions. (Section 6 shows the original
  proposal, which listed only the second.)
- **`make test-int (Firebase emulators)` runs on every PR but is not a required check**: a red `make test-int` does not block a merge by
  itself, so read it. It can flake on an App Check key fetch in CI: rerun **only the failed job**, and say so in the PR (do not silently
  retry or ignore it).
- **Tags:** `v*` tags are covered by the separate tag ruleset `protect-version-tags` (Admin-role bypass only), see ADR-0019
  (`docs/adr/0019-prod-release-gate-required-reviewers-and-tag-ruleset.md`); the assistant's App cannot create, move or delete them.
- **Promotion ceilings:** raising a ceiling in `scripts/promotion/flag-ceiling.json` is a reviewed PR (CODEOWNERS-protected) and must merge
  **before** the matching `FEATURE_<NAME>` is applied through Terraform; otherwise dev promotes refuse the revision, because the flag's
  effective mode would exceed the ceiling.

## 11a. Plan pool environment gate and Vision quota (finding M-A of the security review of PR #449)
**The risk.** The plan WIF pool (`github-plan`, `modules/iam`) used to accept any same-repo `pull_request` or `workflow_dispatch`,
and a PR runs the workflow file from its own head, so any PR could mint a `tf-plan` token before review. That token holds
`roles/serviceusage.serviceUsageConsumer` (needed by `user_project_override`), which lets it call any enabled paid API billed to
the project. Vision `images:annotate` checks no Vision IAM permission, only billing, and it is not counted by `VISION_MONTHLY_CAP`
(an app-side counter). At the default 1,800 requests a minute that is about INR 15,400 an hour if a request is one image
(1,800 x 60 = 108,000 units x USD 0.0015 x INR 95), so the INR 25,000 credit cap (ADR-0022) goes in under 2 hours.

**Two controls, both in this change.**

1. **Environment gate (the primary control).** The plan provider's `attribute_condition` now also requires
   `assertion.environment == 'tf-plan'`. This is the same OIDC `environment` claim the deploy pool pins in M6
   (`assertion.environment == 'prod'` / `'dev'`); GitHub sets it only on a job that declares `environment:`, and a job that
   declares a protected environment does not start until its required reviewer approves. `terraform.yml` now declares
   `environment: tf-plan` on the `plan (dev)` / `plan (prod)` jobs. The workflow expression is only UX (Dependabot and fork PRs get
   no environment so they do not wait); the boundary is the WIF condition plus the reviewer: a PR that deletes the `environment:`
   line just gets a job with no usable token. `fmt` and `tflint` moved to a separate `lint` job with no environment, no `id-token`
   and `contents: read` only, so they run at once and never wait for approval.
   **Consequence:** every plan run waits for the founder's approval. That costs nothing today because the plan job skips auth
   while an env is not bootstrapped (pending 1.19); the job still waits first, because `secrets` are not available to the
   `environment:` expression, so approve it and the gate step then skips the plan. Approve only after reading the PR's diff to
   `.github/workflows/`, `infra/terraform/` and `scripts/`: approval is the review.
2. **Vision quota overrides (the second layer, `modules/vision-quota`).** Service Usage consumer quota overrides on
   `vision.googleapis.com`, per project, via `google_service_usage_consumer_quota_override` (google-beta only in provider 8.8.1;
   `force = true` because every value is a decrease of more than 10%). Applied to dev and prod alike.
   - The app calls exactly one feature, `SAFE_SEARCH_DETECTION`, one image per request (`backend/internal/media/vision.go`).
     `safe_search_detection_requests` and the umbrella `default_requests` (both `/min/project`) are set to **30 a minute**; the default is 1,800.
   - Every other Vision project quota is set to **0**: label, text, document text, face, landmark, logo, object, web, image
     properties, crop hints, Product Search (requests, resource management, batch, import lines) and the async image and
     document quotas. Without this an attacker would switch to another billed feature (web detection is USD 3.50 per 1,000 units),
     or send one request with all features at once. `celebrity_recognition_requests` has no project bucket (restricted) and
     cannot be overridden.
   - The 30 is variable `safe_search_requests_per_minute` (default 30, validated 10 to 1,800); `unused_feature_limit` is 0 (use 1 only
     if the API refuses 0).

**Sizing (the app is never throttled).**

| Input | Value | Source |
|---|---|---|
| Vision calls per image | 2 (full image and thumbnail), one `images:annotate` request each | `finalizeOne`, `VISION_SCREEN_THUMB=true` |
| Highest monthly units | 37,423 at 3,000 DAU (12.47 units per DAU-month); cap 40,000 | `docs/reviews/cost-model.md` §5, ADR-0022 |
| Per day | 37,423 / 30.42 = 1,230 calls | |
| Busiest hour | 15% of the day = 185 calls = 3.1 a minute | planning assumption |
| Busiest minute | 3 x the busiest hour = **9.2 a minute** | planning assumption |
| Per-user ceiling | `RATE_LIMIT_POST_CREATE_PER_MIN` 10 shared by CreateUpload and FinalizeUpload, so at most 5 finalizes, each at most 4 images x 2 = 8 calls; `QUOTA_MEDIA_PER_DAY` 20 images (5 for a new account) = 40 calls a day | `config.go`, `ratelimit_config.go` |
| Cap chosen | **30 a minute** = 3.3 x the busiest minute; also 3 users finalizing a 4-image post in the same minute (24 calls) | |

A refusal is safe: the media service reserves the units before the call and releases them when it fails, and the upload stays PENDING,
so the client's retry succeeds the next minute. Watch for `RESOURCE_EXHAUSTED` from `vision.googleapis.com` in the API logs; raise the
variable if it appears in normal use. Dev's `VISION_MONTHLY_CAP` is 10,000, so the same 30 is generous there.

**What an attacker can spend after the change (INR 95 per USD, USD 1.50 per 1,000 units, so INR 0.1425 a unit).**

| Case | Units an hour | INR an hour |
|---|---|---|
| Before, 1,800 a minute, one image per request | 108,000 | about 15,400 |
| After, 30 a minute, one image per request | 1,800 | **about 256** |
| After, 30 a minute, if the quota counts requests and each carries 16 images (the API maximum) | 28,800 | about 4,100 |
| After, any other feature | 0 | 0 |

The cap is a 60x cut either way. Whether the quota counts images or requests is not documented in the metric names; the founder can
settle it in dev for free (step 7 below). With the environment gate in place the token is only minted after the founder approves a run,
so this is the layer for the case where a reviewed run is later proved hostile, or an approval is a mistake.

**Founder steps (order matters).**
1. **Create the environment BEFORE merging this PR.** A workflow that names an environment that does not exist creates it with no
   protection, which would leave the gate open. Repo Settings > Environments > New environment `tf-plan`: tick Required reviewers,
   add the founder, leave "Allow administrators to bypass" on only if you want that, and leave deployment branches on "All branches"
   (a pull request runs on `refs/pull/N/merge`, so a branch policy would block every PR plan). Or:
   `gh api -X PUT repos/<owner>/<repo>/environments/tf-plan --input -` with
   `{"reviewers":[{"type":"User","id":<founder numeric id>}]}` (the id from `gh api users/<login> --jq .id`).
2. Merge this PR (it is a gate-file change, so it needs your review).
3. **Dev: targeted plan, then apply.** Other pending dev changes are not part of this item.
   ```
   cd infra/terraform/envs/dev
   terraform init -backend-config="bucket=<state bucket>"
   terraform plan -out=tfplan -target=module.iam.google_iam_workload_identity_pool_provider.plan -target=module.vision_quota
   ```
   Expect `19 to add, 1 to change, 0 to destroy`: 19 `google_service_usage_consumer_quota_override` creates and the plan provider's
   `attribute_condition` in place. Anything else (a destroy, a replace) stops here. Then `terraform apply tfplan`.
   If the API rejects an override of 0, set `unused_feature_limit = 1` in the module call and plan again.
4. **Prove the gate in dev** (needs the `DEV_PLAN_*` secrets to exist; without them the job skips auth and proves nothing).
   Actions > Terraform > Run workflow on `main`: the `lint` job finishes without approval; `plan (dev)` and `plan (prod)` show
   "Waiting for review" and nothing authenticates. Approve `tf-plan`: `Auth to GCP` now succeeds for dev. Optional negative check on a
   throwaway branch: delete the `environment:` line, dispatch, and `Auth to GCP` must fail with a condition rejection (no approval was asked).
5. **Prove the quota in dev** (read-only). With your own login:
   `curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "x-goog-user-project: <dev project>" "https://serviceusage.googleapis.com/v1beta1/projects/<dev project>/services/vision.googleapis.com/consumerQuotaMetrics" | jq -r '.metrics[].consumerQuotaLimits[] | [.metric, .unit, .quotaBuckets[0].effectiveLimit] | @tsv'`
   shows `30` for `safe_search_detection_requests` and `default_requests` (`1/min/{project}`) and `0` for the others. Then upload one image
   in the dev app: it must still publish.
6. **Prod: plan for your OK, then apply.** `cd infra/terraform/envs/prod`, real `terraform.tfvars`, the same two `-target` flags and
   `-out=tfplan`. The expected result is the same `19 to add, 1 to change, 0 to destroy`. Send the plan to the assistant or read it
   yourself; apply `tfplan` only after the OK. Prod has other unapplied changes (`docs/pending.md` section 1), so keep the targets.
7. **Settle images versus requests (optional, free).** In dev, send one `images:annotate` request with 16 `SAFE_SEARCH_DETECTION`
   entries (the same public object 16 times) and read the Quotas page (IAM & Admin > Quotas, filter "Safe search") or the
   `serviceruntime.googleapis.com/quota/rate/net_usage` metric: +1 means requests, +16 means images. It costs 16 of dev's 1,000 free
   units a month. If it is +16, the third row of the table above does not apply.

**Rollback.** Remove the `vision_quota` module call (or a single override) and apply: the Vision default returns. Remove
`assertion.environment == 'tf-plan'` from the plan provider and apply to open plan tokens to any same-repo PR again (do not).

## 12. Bot PRs and the approval rule
- **The rule (intended configuration, section 6):** the main ruleset requires approval of the most recent push by someone other than the
  pusher (`require_last_push_approval`) and dismisses stale approvals on every push. Check the live ruleset before relying on this
  text: this document does not assert its current state.
- **So every commit of a bot PR must be authored and committed by `dzeroth-agent[bot]`, from the first commit.** Set the repo-local git
  identity (`user.name` `dzeroth-agent[bot]`, `user.email` the App's `...[bot]@users.noreply.github.com` address that earlier bot commits
  carry, see `git log`) **before** the first commit, then check `git log --format='%an <%ae> | %cn <%ce>'` shows the bot on every commit
  before pushing. Push and open the PR with a token minted per command (`scripts/mint-app-token.sh`), never stored or printed.
- **A PR the founder opens, or whose last push is the founder's, cannot be approved by the founder**, because the founder is then the last
  pusher. Do not "fix" that with an empty commit or a re-authored commit: the assistant's harness rightly refuses it. Open a new PR from
  a bot-authored branch instead.
- **A second open PR for the same head and base branch is not allowed by GitHub.** To replace a PR, close the old one first, or push the
  same commit under a new branch name; do not rebase, amend or force-push a branch that already has a PR.
