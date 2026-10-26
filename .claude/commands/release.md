---
description: Readiness gate + staged production release on Cloud Run
argument-hint: <version, e.g. v1.4.0>
---
Follow the `release-rollout` skill and ADR-0019. The founder creates the `$ARGUMENTS` tag and gives every approval; agents never apply to prod, create tags or dispatch `promote-prod` on their own.
1. Confirm `release-prod.yml` has staged `$ARGUMENTS` in prod as a 0%-traffic `candidate` revision and that the smoke suite on the candidate URL passed. If it has not run, stop and ask the founder to create or approve the tag.
2. Use the `production-reviewer` subagent to produce `docs/reviews/release-$ARGUMENTS-readiness.md`; it needs `VERDICT: PASS`, `APPROVE`, `SECURITY: CLEAR` and `BUDGET: HOLDS` from the earlier gates.
3. If and only if it says `VERDICT: GO`, hand to the founder: they dispatch `promote-prod.yml` with `stage=10`, watch about 15 minutes, then `stage=100`. Use `production-deployer` to prepare the release record in `docs/releases/` and to watch the metrics between the two steps.
4. If NO-GO, list blockers and the agent that owns each; the `candidate` revision stays at 0% traffic.
