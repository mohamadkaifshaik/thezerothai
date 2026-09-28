---
name: ship-feature
description: End-to-end orchestration of a feature through the whole team — plan, design, build, test, review, cost check, release. Use when the user asks to build/ship/implement a feature end to end.
---

# Ship a feature with the team

Run these stages in order. Delegate each stage to the named subagent with the Agent tool, passing
the feature name and the paths of prior outputs. Stop and report to the human if any gate fails.
Skip stages the plan marks N/A (e.g., no design change → skip 2) — every subagent run costs time and tokens.

| # | Stage | Agent | Output / gate |
|---|---|---|---|
| 1 | Plan | `planner` | `docs/plans/<date>-<slug>.md` incl. cost rows |
| 2 | Design (only if contract/data model changes) | `architect` | ADR + `proto/` + Firestore model/index changes; `make proto` passes |
| 3 | Build API | `backend-developer` | code + tests; `make ci` green |
| 3 | Build client (parallel with 3) | `frontend-developer` | screens + widget tests; `flutter analyze` clean |
| 4 | Test | `tester` | `docs/reviews/test-report-<slug>.md` = PASS (incl. budget assertions) |
| 5 | Review (parallel) | `code-reviewer`, `security-auditor` | APPROVE, no Critical/High |
| 6 | Cost & perf | `sre-performance` | cost-model updated; emulator load smoke; free quotas hold |
| 7 | Stage | `production-deployer` | deployed to dev; prod `candidate` tagged revision with no traffic, smoke passes |
| 8 | Gate | `production-reviewer` | `VERDICT: GO` |
| 9 | Release | `production-deployer` | 10% → 100% traffic, watched 15 min (ask human before 100%) |

Loop rule: any REQUEST CHANGES / FAIL goes back to the owning developer agent with the findings,
then re-runs the failing stage only. Max 3 loops before escalating to the human.

At the end, summarize: what shipped, links to reports, flags state, cost delta (reads/writes per DAU), follow-ups.
