# Docs index

Start here. Binding rules are in `/CLAUDE.md`; decisions in `adr/` win over everything else.

| Need | Read |
|---|---|
| What is open right now, outside the wave plans | `docs/plans/roadmap.md`, section 9 |
| Where the product is heading | `plans/roadmap.md`, `plans/phase1.md` |
| Why something is built the way it is | `adr/` (0012-0015 are intentionally unused) |
| How a feature is being built | `plans/<feature>.md` (per-ticket Status) |
| What to do when something breaks or ships | `runbooks/` (`rollback.md`, `ci-enforcement.md`, `credit-sunset-pause-resume.md`) |
| Shared backend helpers, shared UI widgets | `code-map.md`, `ui-catalog.md` |
| Cost and free-tier numbers | `reviews/cost-model.md`, `plans/credit-runway-cost-model.md` |
| Release history and readiness | `releases/`, `reviews/release-*-readiness.md` |
| X reference captures for the UI | `x_research/` (local only, gitignored; not in a fresh clone) |
| Claude Code tooling and guardrails | `runbooks/claude-setup.md` |

`archive/` holds closed reports. They are history, not guidance: do not read them unless a task names them. `archive/reviews/` has the
code, security, test and cost reports of the shipped graph, posts/timeline, account-lifecycle and modern-UI slices (plans and ADRs still
cite them by their `docs/archive/reviews/` path), plus the phase 0 and p0 reviews and old post-release notes.

`reviews/` keeps what is still used: `cost-model.md` (read by `make cost`), the ADR-0021 security review (that work is in progress) and the
`release-<tag>-readiness.md` files. Keep the release files in place: `release-prod.yml` and `promote-prod.yml` require
`docs/reviews/release-<tag>-readiness.md` with a `VERDICT: GO` line for the tag being released.
