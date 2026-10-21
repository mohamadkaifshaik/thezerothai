# 0019. Enforce the prod release gate with environment required reviewers and a v* tag ruleset
Status: Proposed (only the founder accepts ADRs; nothing here has been executed or changed on GitHub)
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

## Consequences
- **Approval clicks per release: 3.** `release-prod`'s `build-and-stage` job (declares `environment: prod`), `promote-prod` stage=10, and
  `promote-prod` stage=100. A re-run or a re-dispatch needs its own approval. Mobile jobs are not gated; `dev` is unaffected.
- **The approver must look.** The approval screen shows the tag and commit. Compare the tag commit with the reviewed readiness commit
  (the readiness doc's P0 diff checks) before approving. This is the control against a modified workflow at an owner-created tag.
- **Unlocks (not decided here):** automating the prod authenticated smoke with `prod` Environment secrets becomes defensible only after
  this ADR is rolled out; that is a separate decision and ADR.
- **Residual risks:** the owner approving without looking; a compromised owner account (out of scope); a modified workflow at an
  owner-created tag (the approval screen and the readiness P0 diff are the control); GitHub changing free-plan features.
- **Rollback (owner-only API calls):** delete the tag ruleset (`DELETE /repos/.../rulesets/<id>`) and remove the reviewer (PUT the
  environment with `"reviewers": []`); commands in R5.
- **Revisit** when a second collaborator is added, or if GitHub changes the free-plan features.

## Rollout (owner-only; each step has an expected result and a rollback)
**Never test with a tag matching `v*`: a `v*` tag push starts `release-prod.yml`, which stages a prod candidate.** Run in Git Bash from
the repo root. The commands are proposals for the owner; the assistant does not run them (the App has no administration permission).
`R=repos/mohamadkaifshaik/thezerothai` below.

### R1. Prove the mechanism on a harmless pattern (`zz-adr-test-*`)
```bash
R=repos/mohamadkaifshaik/thezerothai
# 1. create DISABLED. Expect 201. A 403/422 here means the plan blocks tag rulesets: STOP and record it in this ADR.
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
TEST_ID=$(gh api "$R/rulesets" --jq '.[] | select(.name=="zz-adr-test") | .id')
# 2. activate. Expect enforcement "active" in the read-back.
echo '{"enforcement":"active"}' | gh api -X PUT "$R/rulesets/$TEST_ID" --input - --jq .enforcement
# 3. the App must be REFUSED (run by the assistant session; expect 403 or 422, "Repository rule violations")
SHA=$(git rev-parse origin/main)
GH_TOKEN=$(bash scripts/mint-app-token.sh) gh api -X POST "$R/git/refs" -f ref=refs/tags/zz-adr-test-1 -f sha="$SHA" || echo "refused, as expected"
# 4. the owner must be ALLOWED (expect 201, then 204 on delete)
gh api -X POST "$R/git/refs" -f ref=refs/tags/zz-adr-test-1 -f sha="$SHA" --jq .ref
gh api -X DELETE "$R/git/refs/tags/zz-adr-test-1"
# 5. remove the test ruleset (rollback of R1). Expect 204.
gh api -X DELETE "$R/rulesets/$TEST_ID"
```
Expected: steps 1-2 accepted, step 3 refused, step 4 succeeds, step 5 204. If step 3 is **not** refused, the ruleset is not enforced for the
App: STOP, do not continue to R2.

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
```
Expected: the diff adds only the `required_reviewers` rule (and `prevent_self_review: false`); the policy list still shows `v*` of type `tag`.
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
gh api -X DELETE "$R/rulesets/$TAG_RULESET_ID"
jq -n '{ wait_timer: 0, prevent_self_review: false, reviewers: [], deployment_branch_policy: { protected_branches: false, custom_branch_policies: true } }' |
  gh api -X PUT "$R/environments/prod" --input - > /dev/null
```
Both are owner-only calls.

## Handoff
- backend-developer: none.
- frontend-developer: none.
- production-deployer: the owner runs R1-R3 (the assistant's App cannot: no administration permission); follow-up PRs per R4.
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
