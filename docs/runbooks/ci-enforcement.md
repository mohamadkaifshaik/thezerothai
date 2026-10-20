# CI enforcement and review gates: Option 2, a separate identity for the assistant (PROPOSAL, nothing enabled)
Status: draft for founder review, 2026-10-20. **No GitHub setting, ruleset, App or credential has been changed or created.**
Decision (founder, 2026-10-20): technical separation with a dedicated GitHub App or bot identity and **no bypass actors**; code owner
`@mohamadkaifshaik`. The solo-owner bypass option is rejected.

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
  `POST /app/installations/{id}/access_tokens` with `repositories` and the permission subset, export the result as `GH_TOKEN` for the
  session only. The token is never written to disk or logs (it is masked in any output).
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
- Not covered: tags, the `prod` environment's own tag policy, anything pushed with a token that has Administration.

## 7. Roll-out order (each step needs the owner)
1. Owner reviews this document and PR #176 (CODEOWNERS covers the ack, the check script, `firestore.indexes.json`, `flag-ceiling.json`,
   every file under `.github/workflows/`, and CODEOWNERS itself).
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
