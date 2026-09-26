---
description: Readiness gate + staged production release on Cloud Run
argument-hint: <version, e.g. v1.4.0>
---
1. Use the `production-deployer` subagent to deploy `$ARGUMENTS` to prod as a tagged `rc` revision with no traffic and run the smoke suite.
2. Use the `production-reviewer` subagent to produce `docs/reviews/release-$ARGUMENTS-readiness.md`.
3. If and only if it says `VERDICT: GO`, use `production-deployer` to shift traffic 10% → 100% per the `release-rollout` skill.
   Ask me before going to 100%.
4. If NO-GO, list blockers and the agent that owns each; leave the `rc` revision at 0% traffic.
