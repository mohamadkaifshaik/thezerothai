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
