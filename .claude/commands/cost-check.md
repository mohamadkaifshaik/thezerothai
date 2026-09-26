---
description: Check current and projected GCP/Firebase cost against the free tier
argument-hint: [optional: expected DAU, e.g. 500]
---
Use the `sre-performance` subagent with the `free-tier-budget` skill to:
1. Recompute `docs/reviews/cost-model.md` from the RPC budget rows (and expected DAU `$ARGUMENTS` if given).
2. If gcloud is authenticated, pull the last 7 days of Firestore reads/writes, Cloud Run requests/instances and GCS egress
   from Cloud Monitoring (read-only) and compare to the model.
3. Scan `infra/terraform` for fixed-cost resources and Cloud Run min-instances > 0.
4. Report: headroom per free quota, DAU at which each runs out, projected $/month at 2× and 10×, and any scale-up trigger that fired.
