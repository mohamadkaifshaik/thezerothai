# CI enforcement and review gates (PROPOSAL, nothing enabled)
Status: draft for founder review, 2026-10-20. No GitHub setting has been changed.

## What exists today (read-only check)
- Ruleset `main - Production protection` (id 24070946): **enforcement disabled**. It targets `~DEFAULT_BRANCH` **and `~ALL`**, blocks
  branch deletion and non-fast-forward pushes, requires a PR with **1 approving review** (`require_code_owner_review: false`),
  has an **empty** required-status-check list and **no bypass actors**.
- No classic branch protection on `main`. One collaborator (the repository owner, admin). No CODEOWNERS file before this PR.
- Consequence: CI is advisory. A red PR can merge, and a direct push to `main` runs `deploy-dev.yml` without PR checks.

## Why the existing ruleset must not simply be enabled
1. `~ALL` applies the PR requirement to every branch, so pushing any feature branch would be refused.
2. One required approval cannot be met by the sole collaborator (GitHub does not let an author approve their own PR) and there is no
   bypass actor, so **every merge, including Dependabot, would be blocked**.
3. Branch deletion would be blocked, so merged branches could not be cleaned up.

## Review gate limits (important)
All PRs, including those written by the assistant, are authored with the owner's own GitHub credentials. A required code-owner review
therefore cannot be satisfied by anyone else. Two honest options:
- **Solo owner (no second identity):** make the owner a bypass actor in `pull_request` mode. Gated files then need a deliberate
  "bypass" click on the PR page (recorded in the audit log). The assistant's default `gh pr merge` fails on a gated PR, and it
  must not use `--admin`, but that is a convention, not a technical control, because it holds the same token.
- **Second identity (free):** a dedicated machine/bot GitHub account or GitHub App authors the assistant's PRs; the owner is the code
  owner who approves gated files; **no bypass actors**. This is the only setup that technically separates author from reviewer.

The `field-overrides.ack` hash itself is a tripwire, not a control: the failing check prints the expected hash, so an author can paste it.
Its value is that the change appears as a deliberate diff to a CODEOWNERS-protected file.

## Proposed ruleset (NOT applied; replaces the disabled ruleset 24070946)
Required check name (exact, from the job `name:` in `ci.yml`): `promotion scripts (shellcheck, actionlint, fixture tests, flag registry)`.
Scope: the default branch only (`~DEFAULT_BRANCH`), not `~ALL`.
```bash
# Option 1: solo owner (bypass only through a PR, recorded in the audit log). Verify the admin role id (5) before applying.
gh api -X PUT repos/mohamadkaifshaik/thezerothai/rulesets/24070946 --input - <<'JSON'
{
  "name": "main - required checks and code-owner review",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": true, "require_last_push_approval": false, "required_review_thread_resolution": false}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "do_not_enforce_on_create": false,
      "required_status_checks": [{"context": "promotion scripts (shellcheck, actionlint, fixture tests, flag registry)"}]}}
  ]
}
JSON
# Option 2: second identity for the assistant: identical, but "bypass_actors": [] (no one can skip the code-owner review).
# Rollback: PUT the same body with "enforcement": "disabled" (or delete the ruleset).
```
### Merge impact if applied (Option 1)
- Direct pushes to `main` are refused (a PR is required); feature branches are untouched (they were swept in by `~ALL` before).
- Every PR must show a green `promotion scripts (...)` check. `make ci` is NOT required (it can fail on unrelated GitHub API rate limits;
  adding it is optional). A red or missing check blocks the merge button; Dependabot PRs need the check too (it runs on every PR to `main`).
- PRs touching a CODEOWNERS path need the owner's review, which the author (the owner's own account) cannot give: the owner merges them
  deliberately with "Merge without waiting for requirements" (bypass in `pull_request` mode). Other PRs merge as today once the check is green.
- Branch deletion of `main` and force-pushes to `main` stay blocked.
- Not covered: tags, the `prod` environment (separate branch/tag policy), and anything pushed with a token that is a bypass actor.
