# 0019. Enforce the prod release gate with environment required reviewers and a v* tag ruleset
Status: Accepted (founder, 2026-10-21). Rollout R1-R3 done 2026-10-21 (see Rollout log); R4 follow-up docs PRs are pending.
Date: 2026-10-21
Deciders: architect, founder

## Context
`docs/runbooks/cloud-bootstrap.md` §6a (2026-09-27) was written when this repository was **private on GitHub Free**. It concluded that
branch protection, rulesets, tag protection and environment required reviewers were unavailable, and that "the founder clicking Run
workflow is the approval". It ends: "Revisit via an ADR before adding a second collaborator". The readiness review of v0.4.1 (H12) flagged
that the repository is now **public**, which weakens that premise. This ADR is that revisit.

Facts (verified read-only on 2026-10-21; anything not verified is marked **unverified**):
- The repository is public and user-owned (`mohamadkaifshaik/thezerothai`, a personal account), so the only admin is the owner.
- GitHub documents that environment required reviewers and wait timers are available on GitHub Free **for public repositories**, and that
  rulesets can target branches or tags (Sources). Proof on this repo: the branch ruleset 24070946 ("main - required check and code-owner
  review", no bypass actors) has been enforced since 2026-10-20. The documentation does **not** state tag-ruleset availability on Free
  explicitly: **unverified** until rollout step R1 proves it.
- Today the only ruleset is the default-branch one: **tags are not covered**. The `prod` GitHub Environment has only a deployment policy
  "tag `v*`": no required reviewers, no wait timer.
- The only collaborator is the owner, but the assistant's GitHub App (installed on this repo, Contents: write) can push branches and
  **create tags**. Existing release tags: `v0.1.0`, `v0.4.0`, `v0.4.1`.
- `release-prod.yml` fires on a `v*` tag push; its `build-and-stage` job (the only job that authenticates to GCP) declares
  `environment: prod`. `promote-prod.yml` is `workflow_dispatch`-only; the App has no Actions write, so it cannot dispatch it.
  The mobile build jobs in `release-prod.yml` declare no environment and never touch GCP.
- The prod Workload Identity provider pins repository, ref prefix `refs/tags/v`, `job_workflow_ref` to `release-prod.yml` /
  `promote-prod.yml` at `refs/tags/v`, and `environment == 'prod'`. It matches the workflow file **path and ref, not its contents**.

**Threat.** A workflow file modified on a branch and run at a `v*` tag created by anything other than the owner would still satisfy the
WIF pin and could obtain prod GCP credentials (it can stage a 0% candidate; promotion still needs a human dispatch). Any future `prod`
Environment secret (for example prod smoke credentials, see `docs/runbooks/authenticated-smoke.md`, "Why prod credentials are NOT in
GitHub yet") would be exposed to it. The App can create tags today.

## Options
### A. Status quo (deployment policy `v*` + WIF pin only)
- Pros: nothing to do; the owner clicking "Run workflow" stays the only step.
- Cons: the threat above is open; blocks any prod secret in GitHub. Cost: $0.

### B. Required reviewer on `prod` only
- Pros: the OIDC token for the `prod` environment is only minted after approval, so a job started by a tag from another actor waits for the
  owner. Cons: anyone able to push can still create, move or delete release tags (a tag can be moved to a different commit before approval;
  the approver must notice). Cost: $0.

### C. Tag ruleset on `v*` only
- Pros: only the owner (Admin role) can create, move or delete release tags. Cons: a tag pushed by the owner at a modified workflow still
  starts the job without a pause; no per-run approval. Cost: $0.

### D. Both: tag ruleset on `refs/tags/v*` plus the owner as required reviewer on `prod` (proposed)
- Pros: the two controls cover each other (who can create a release tag, and an explicit approval screen showing the tag and commit before
  any job gets cloud credentials). Cons: three extra approval clicks per release. Cost: $0 (public-repo features).

### E. Paid plan (Pro/Team)
- Not needed: the features are free for public repositories. Cost would be a fixed monthly fee (CLAUDE.md prime directive: rejected).

### F. CODEOWNERS on the workflows (exists)
- It protects `main` only (code-owner review on the PR). It does not constrain a tag created from another branch, so it does not close the
  threat. Kept, not a substitute.

## Cost impact
- Fixed monthly cost added: **$0** (environment required reviewers and rulesets are public-repo features on the free plan; no paid plan).
- Free-tier quota consumed: none on GCP/Firebase. GitHub Actions minutes: a job waiting for review does not run, so it adds no minutes.
- Operational cost: **3 approvals per release** (see Consequences). Trigger that justifies it: the threat above, and the wish to hold prod
  secrets in GitHub (separate decision), not a scale trigger.

## Decision (proposed)
Adopt option D.
1. **Tag ruleset** on `refs/tags/v*` with rules `creation`, `update`, `deletion`. Bypass actors: the repository **Admin** role only
   (`actor_type` `RepositoryRole`, `actor_id` 5, `bypass_mode` `always`). The assistant's App and everyone else cannot create, move or
   delete release tags.
2. **`prod` environment:** the owner as a **required reviewer**, "prevent self-review" **off** (there is one human; the control targets
   non-owner actors such as the App, not the owner), **no wait timer**. Keep the existing `v*` tag deployment policy and the WIF pin. The
   environment OIDC claim is only minted once the job starts, which happens after approval, so a tag pushed by another actor cannot reach
   GCP credentials without the owner's approval. (By design of required reviewers; **unverified** experimentally until the first real
   release, see R3. Whether "prevent self-review" is offered on this plan is also **unverified**.)
3. **Administrator bypass: leave the default.** The `prod` environment currently has `can_admins_bypass: true` (GitHub's default "Allow
   administrators to bypass configured protection rules"). The owner, as the only admin, can therefore bypass the reviewer. This does not
   weaken the control against the assistant's App (it is not an admin), but it means the approval is **not unskippable for the owner**.
   The observed value is recorded in the R3 read-back and diff. If the owner ever wants the approval to be unskippable, the setting is
   `can_admins_bypass=false` where the plan offers it (**unverified**).

## Acceptance record
The founder accepted this ADR on 2026-10-21: option D, and explicitly these three points:
- **Three approval clicks per release** (`release-prod` `build-and-stage`, `promote-prod` stage=10, `promote-prod` stage=100).
- **"Prevent self-review" stays OFF.**
- **The `prod` environment's `can_admins_bypass` stays at its default (true):** the approval is not unskippable for the owner, but the
  assistant's App cannot bypass it.

## Consequences
- **Approval clicks per release: 3.** `release-prod`'s `build-and-stage` job (declares `environment: prod`), `promote-prod` stage=10, and
  `promote-prod` stage=100. A re-run or a re-dispatch needs its own approval. Mobile jobs are not gated; `dev` is unaffected.
- **The approver must look.** The approval screen shows the tag and commit. Compare the tag commit with the reviewed readiness commit
  (the readiness doc's P0 diff checks) before approving. This is the control against a modified workflow at an owner-created tag.
- **Unlocks (not decided here):** automating the prod authenticated smoke with `prod` Environment secrets becomes defensible only after
  this ADR is rolled out; that is a separate decision and ADR.
- **The approval is skippable by the owner.** With `can_admins_bypass: true` (the default we keep, see Decision 3), the owner can bypass the
  reviewer. The gate is aimed at non-owner actors such as the App; against the owner it relies on the owner's discipline.
- **Residual risks:** the owner approving without looking; a compromised owner account (out of scope); a modified workflow at an
  owner-created tag (the approval screen and the readiness P0 diff are the control); GitHub changing free-plan features.
- **Rollback (owner-only API calls):** delete the tag ruleset (`DELETE /repos/.../rulesets/<id>`) and remove the reviewer (PUT the
  environment with `"reviewers": []`); commands in R5.
- **Revisit** when a second collaborator is added, or if GitHub changes the free-plan features.

## Rollout (each step has an expected result and a rollback)
**Never test with a tag matching `v*`: a `v*` tag push starts `release-prod.yml`, which stages a prod candidate.** Run in Git Bash from
the repo root. Every block says who runs it. The owner's `gh` login (administration rights) runs everything **except** two blocks in R1, the
**positive control** and the **refusal check**: those need the App token from `scripts/mint-app-token.sh`, which only the `claude-agent` OS
user can mint, so they run in the `claude-agent` session. The App has no administration permission, so it cannot run anything else here.
`R=repos/mohamadkaifshaik/thezerothai` below.

### R1. Prove the mechanism on a harmless pattern (`zz-adr-test-*`)
**1. Owner: create the test ruleset DISABLED.** Expect 201. A 403/422 here means the plan blocks tag rulesets: STOP and record it in this ADR.
```bash
R=repos/mohamadkaifshaik/thezerothai
gh api -X POST "$R/rulesets" --input - <<'JSON'
{
  "name": "zz-adr-test",
  "target": "tag",
  "enforcement": "disabled",
  "conditions": { "ref_name": { "include": ["refs/tags/zz-adr-test-*"], "exclude": [] } },
  "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" } ],
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ]
}
JSON
```
**2. `claude-agent` session: positive control, while the ruleset is still disabled.** The App must be able to create and delete a tag at all
(expect 201, then 204); otherwise the refusal in step 4 would prove nothing.
```bash
(
R=repos/mohamadkaifshaik/thezerothai
SHA=$(git rev-parse origin/main)
TOKEN=$(bash scripts/mint-app-token.sh) || { echo "CONTROL FAILED: could not mint the App token"; exit 1; }
[ -n "$TOKEN" ] || { echo "CONTROL FAILED: empty App token"; exit 1; }
created=$(GH_TOKEN=$TOKEN gh api -i -X POST "$R/git/refs" -f ref=refs/tags/zz-adr-test-0 -f sha="$SHA" 2>&1 | awk 'NR==1 {print $2}')
deleted=$(GH_TOKEN=$TOKEN gh api -i -X DELETE "$R/git/refs/tags/zz-adr-test-0" 2>&1 | awk 'NR==1 {print $2}')
echo "create zz-adr-test-0: HTTP ${created:-none} (expect 201); delete: HTTP ${deleted:-none} (expect 204)"
if [ "$created" = 201 ] && [ "$deleted" = 204 ]; then
  echo "POSITIVE CONTROL OK: the App can create and delete tags"
else
  echo "CONTROL FAILED: do not continue; the refusal check would be meaningless"
  exit 1
fi
)
```
**3. Owner: activate the test ruleset.** Expect `active` in the read-back.
```bash
R=repos/mohamadkaifshaik/thezerothai
TEST_ID=$(gh api "$R/rulesets" --jq '.[] | select(.name=="zz-adr-test") | .id')
echo '{"enforcement":"active"}' | gh api -X PUT "$R/rulesets/$TEST_ID" --input - --jq .enforcement
```
**4. `claude-agent` session: the refusal check (a differential check, not a text match).** GitHub answers a ruleset-blocked tag creation with
HTTP 422 and the **generic** body `{"message":"Reference update failed"}`, with no rule-violation wording (observed 2026-10-21), so the
message cannot be the evidence. The evidence is the before/after comparison: **PASS** = the App's create returns 422 or 403 **and** no tag
exists afterwards (`git ls-remote`), **and** step 2 returned 201 for the identical request while the ruleset was disabled, **and** step 5
shows the owner succeeds while the ruleset is active. A 201 here is **FAIL**. Anything else (token mint failed, network error, 401/404) is
INCONCLUSIVE.
```bash
(
R=repos/mohamadkaifshaik/thezerothai
SHA=$(git rev-parse origin/main)
TOKEN=$(bash scripts/mint-app-token.sh) || { echo "INCONCLUSIVE: could not mint the App token"; exit 1; }
[ -n "$TOKEN" ] || { echo "INCONCLUSIVE: empty App token"; exit 1; }
out=$(GH_TOKEN=$TOKEN gh api -i -X POST "$R/git/refs" -f ref=refs/tags/zz-adr-test-1 -f sha="$SHA" 2>&1) || true
status=$(printf '%s\n' "$out" | awk 'NR==1 {print $2}')
printf 'status line: %s\n' "$(printf '%s\n' "$out" | head -n 1 | tr -d '\r')"
printf 'body:\n%s\n' "$(printf '%s\n' "$out" | tr -d '\r' | awk 'f{print} /^$/{f=1}')"
remaining=$(git ls-remote --tags origin 'zz-adr-test-1') || { echo "INCONCLUSIVE: could not list remote tags"; exit 1; }
case "$status" in
  201)
    echo "FAIL: the App created the tag (HTTP 201): the ruleset is NOT enforced for it. STOP, do not continue to R2."
    GH_TOKEN=$TOKEN gh api -X DELETE "$R/git/refs/tags/zz-adr-test-1" > /dev/null
    exit 1 ;;
  403 | 422)
    if [ -z "$remaining" ]; then
      echo "PASS (differential): refused with HTTP $status and no tag exists. Compare step 2 (201 while disabled) and step 5 (owner allowed while active)."
    else
      echo "FAIL: HTTP $status but a zz-adr-test-1 tag exists; investigate before continuing"
      exit 1
    fi ;;
  *)
    echo "INCONCLUSIVE: HTTP ${status:-none}; this is not a ruleset refusal"
    exit 1 ;;
esac
)
```
**5. Owner: the owner must be ALLOWED** (bypass), then remove the test ruleset (the rollback of R1).
```bash
R=repos/mohamadkaifshaik/thezerothai
SHA=$(git rev-parse origin/main)
TEST_ID=$(gh api "$R/rulesets" --jq '.[] | select(.name=="zz-adr-test") | .id')
gh api -X POST "$R/git/refs" -f ref=refs/tags/zz-adr-test-1 -f sha="$SHA" --jq .ref   # expect refs/tags/zz-adr-test-1
gh api -X DELETE "$R/git/refs/tags/zz-adr-test-1"                                     # expect no error (204)
if [ -n "$TEST_ID" ]; then gh api -X DELETE "$R/rulesets/$TEST_ID"; else echo "test ruleset id not found"; fi   # expect no error (204)
```
Expected: step 1 accepted; step 2 `POSITIVE CONTROL OK` (201/204); step 3 `active`; step 4 `PASS (differential)` (422 or 403, no tag
exists); step 5 succeeds. The refusal message is generic; the evidence is the before/after comparison (201 while the ruleset was disabled,
refusal while active, owner allowed through the bypass). If step 4 prints `FAIL` or `INCONCLUSIVE`, or step 2 prints `CONTROL FAILED`, STOP:
do not continue to R2.

### R2. Create the real ruleset on `refs/tags/v*`
The ready-to-run form in `cloud-bootstrap.md` §6a uses repeated `rules[][type]` fields; the JSON body below avoids relying on how `gh`
groups repeated array-of-object keys (**unverified**).
```bash
R=repos/mohamadkaifshaik/thezerothai
gh api -X POST "$R/rulesets" --input - <<'JSON'
{
  "name": "protect-version-tags",
  "target": "tag",
  "enforcement": "disabled",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" } ],
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ]
}
JSON
TAG_RULESET_ID=$(gh api "$R/rulesets" --jq '.[] | select(.name=="protect-version-tags") | .id')
echo '{"enforcement":"active"}' | gh api -X PUT "$R/rulesets/$TAG_RULESET_ID" --input - --jq .enforcement
# read-back: target tag, include refs/tags/v*, three rules, one Admin-role bypass
gh api "$R/rulesets/$TAG_RULESET_ID" --jq '{name, target, enforcement, include: .conditions.ref_name.include, rules: [.rules[].type], bypass: .bypass_actors}'
gh api "$R/rulesets" --jq '.[] | [.id, .name, .target, .enforcement] | @tsv'
```
Expected: `active`; the read-back shows `target: tag`, include `refs/tags/v*`, rules creation/update/deletion, and the Admin bypass; the branch
ruleset 24070946 is still listed unchanged. **A behavioural refusal test against `v*` is not possible without creating a `v*` tag, which
is forbidden**: the pattern is the only difference from R1, which proved enforcement against the App. The `v*` behaviour is confirmed at the
next real release (the owner's tag push must succeed). Rollback: `gh api -X DELETE "$R/rulesets/$TAG_RULESET_ID"`.

### R3. Required reviewer on the `prod` environment
The PUT replaces the environment's settings, so the existing deployment branch policy is resent.
```bash
R=repos/mohamadkaifshaik/thezerothai
gh api "$R/environments/prod" > "${TMPDIR:-/tmp}/prod-env-before.json"
OWNER_ID=$(gh api user --jq .id)
jq -n --argjson id "$OWNER_ID" '{
  wait_timer: 0,
  prevent_self_review: false,
  reviewers: [ { type: "User", id: $id } ],
  deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }
}' | gh api -X PUT "$R/environments/prod" --input - > /dev/null
gh api "$R/environments/prod" > "${TMPDIR:-/tmp}/prod-env-after.json"
diff <(jq -S 'del(.updated_at)' "${TMPDIR:-/tmp}/prod-env-before.json") <(jq -S 'del(.updated_at)' "${TMPDIR:-/tmp}/prod-env-after.json") || true
# the v* tag policy must still be there (expect: v*  tag)
gh api "$R/environments/prod/deployment-branch-policies" --jq '.branch_policies[] | [.name, .type] | @tsv'
# record the administrator-bypass setting before and after (observed today: true; the decision is to leave the default)
echo "can_admins_bypass before: $(jq .can_admins_bypass "${TMPDIR:-/tmp}/prod-env-before.json")"
echo "can_admins_bypass after:  $(jq .can_admins_bypass "${TMPDIR:-/tmp}/prod-env-after.json")"
```
Expected: the diff adds only the `required_reviewers` rule (and `prevent_self_review: false`); the policy list still shows `v*` of type `tag`;
`can_admins_bypass` is `true` before and after (the default, left as is: the owner, as the only admin, can bypass the reviewer; see Decision 3).
If the PUT changed it, record the new value here and decide whether that is acceptable.
If the diff shows anything else removed or changed, restore from `prod-env-before.json` (R5). **Behavioural check, at the next real release
only:** `release-prod`'s `build-and-stage` job must show "Waiting for review" and start only after the owner approves. Do **not** test by
dispatching `promote-prod.yml`: after approval it would shift traffic.

### R4. After Accepted and rolled out (follow-up PRs, not in this PR)
Update `cloud-bootstrap.md` §6a (replace the "no required reviewers / no tag ruleset" trust model), the `release-rollout` skill
("Manual-approval model on GitHub Free"), `docs/runbooks/ci-enforcement.md` (tags are now covered) and the readiness template (an approval
step before tagging and promoting).

### R5. Rollback
```bash
R=repos/mohamadkaifshaik/thezerothai
TAG_RULESET_ID=$(gh api "$R/rulesets" --jq '.[] | select(.name=="protect-version-tags") | .id')
if [ -z "$TAG_RULESET_ID" ]; then
  echo "no ruleset named protect-version-tags found; nothing to delete (list them with: gh api $R/rulesets)"
else
  gh api -X DELETE "$R/rulesets/$TAG_RULESET_ID" && echo "tag ruleset $TAG_RULESET_ID deleted"
fi
jq -n '{ wait_timer: 0, prevent_self_review: false, reviewers: [], deployment_branch_policy: { protected_branches: false, custom_branch_policies: true } }' |
  gh api -X PUT "$R/environments/prod" --input - > /dev/null
```
Both are owner-only calls.

## Handoff
- backend-developer: none.
- frontend-developer: none.
- production-deployer: the owner runs R1-R3, except the two App-token blocks in R1 (positive control and refusal check), which run in the
  `claude-agent` session (the App has no administration permission); follow-up PRs per R4.
- tester: after rollout, confirm at the next release that the tag push by the owner succeeds and `build-and-stage` waits for review.

## Sources
- Environments (required reviewers, wait timers; available on Free for public repositories):
  https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- Reviewing deployments: https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/review-deployments
- About rulesets (branches or tags): https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- Repository: `docs/runbooks/cloud-bootstrap.md` §6a, `.claude/skills/release-rollout/SKILL.md`, `docs/runbooks/ci-enforcement.md`,
  `docs/reviews/release-v0.4.1-readiness.md` (H11, H12), `docs/runbooks/authenticated-smoke.md`.
- **Unverified:** tag-ruleset availability on the Free plan (proved by R1), whether "prevent self-review" is offered on this plan, and the
  exact `gh` array-of-object grouping used in the older §6a command.

## Rollout log
Filled in as the owner reports results; nothing is recorded until it is reported.
- R1 (prove the mechanism on `zz-adr-test-*`): **done 2026-10-21**, three legs. (1) Positive control while the test ruleset was disabled:
  the App created and deleted a tag (HTTP 201 / 204). (2) With the ruleset active, the identical App request was refused: HTTP 422,
  generic body `Reference update failed`, and no tag was created (`git ls-remote` empty). (3) The owner created and deleted a tag through the
  bypass. The test ruleset and its tag were then removed; only the branch ruleset 24070946 remained.
- R2 (tag ruleset on `refs/tags/v*`): **done 2026-10-21**. Ruleset `protect-version-tags` was created disabled, then activated. Read-back
  OK: target tag, include `refs/tags/v*`, rules creation/update/deletion, one Admin-role bypass. Branch ruleset 24070946 is unchanged, and both
  rulesets are active.
- R3 (required reviewer on `prod`): **done 2026-10-21**. The before-state was read first: `can_admins_bypass` true; the only protection rule
  was the branch policy; the deployment policy was `v*` of type tag. After the PUT the diff added **only** a `required_reviewers` rule (the
  owner, `prevent_self_review` false). The `v*` tag policy survived. `can_admins_bypass` is true before and after.
  Incident 2026-10-21: the reviewer rule was removed for a short window by a pasted rollback block (no release was running); it was
  re-applied with the same PUT and verified (`required_reviewers` present, `can_admins_bypass` true, `v*` tag policy intact, tag ruleset
  unchanged).

Behavioural confirmation is pending the next real release: `build-and-stage` must show "Waiting for review", and the owner tag push must still
work through the Admin bypass. Never test with a `v*` tag or by dispatching `promote-prod.yml`.
