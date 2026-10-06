---
name: pr-workflow
description: Branch naming, commit, review-loop and merge conventions for this repo. Use when committing, pushing, opening or updating a pull request.
---

# PR workflow

- **Branches:** `feat/<slug>`, `fix/<slug>`, `docs/<slug>`, `chore/<slug>`. Posts-slice tickets: `feat/posts-t<N>-<slug>`.
- **One ticket per PR**, titled `<type>(<scope>): <ticket> <summary>`; link the plan ticket and ADR in the body.
- **Before pushing:** `make ci` (backend changes also `make test-int`; protos also `make proto`). The `commit-gate` hook runs the fast subset on `git commit`.
- **Only open a PR or push to `main` when the human asks.** Push to your assigned working branch.
- **Never force-push or rewrite history** on a shared branch; merge `origin/main` into the branch to resolve conflicts.
- **Review loop:** `code-reviewer` + `security-auditor` + `tester` (`/review`); fix Blocker/Major findings and re-run only the failing review. Max 3 loops, then escalate.
- **Docs in the PR:** update the plan ticket `Status`, `docs/code-map.md` / `docs/ui-catalog.md` for new reusable items, the runbook for new failure modes, and the cost model if budgets changed.
- **ADRs** are accepted by the founder only (the merge of the ADR PR is the acceptance).
