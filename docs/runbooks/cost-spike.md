# Runbook: cost spike / free-tier quota exhaustion

## Symptoms
- Billing budget alert email/Pub/Sub message at 25/50/90/100% of the $5 budget, or 100% forecasted.
- Monitoring alert: "Firestore reads > 40k/day, 80% of free quota".
- Firebase console → Firestore → Usage tab trending toward 50k reads / 20k writes / 20k deletes per day.
- Cloud Run instance count pinned at `max_instance_count` (3) — probably also a traffic/abuse spike, see `docs/runbooks/abuse-spike.md`.

## Immediate triage (5 minutes)
1. Open Cloud Monitoring dashboard "Free-tier budget (\<env\>)" (Terraform: `modules/monitoring`) — identify which metric is spiking:
   Firestore reads/writes, Cloud Run requests/instances, or GCS egress.
2. Check Cloud Logging for the request path/RPC driving it (structured logs include `rpc`, `fs_reads`, `fs_writes` per
   the observability skill) — is this real traffic, a retry storm, a bad deploy (e.g. an N+1 query), or abuse/scraping?
3. Check Error Reporting for a spike in errors around the same time (a bug causing retries is a common cause).

## Flip degraded mode (stops the bleeding, keeps read paths alive)
Cloud Run env var `DEGRADED_MODE` — flip without a deploy:

```bash
# Reject writes with a friendly error; timeline/profile reads still work.
gcloud run services update api \
  --project=<dzeroth-dev|dzeroth-prod> --region=asia-south1 \
  --update-env-vars DEGRADED_MODE=readonly

# Or: stop issuing media upload URLs (keeps everything else, including posting text).
gcloud run services update api \
  --project=<dzeroth-dev|dzeroth-prod> --region=asia-south1 \
  --update-env-vars DEGRADED_MODE=nomedia

# Back to normal once the spike is understood/fixed:
gcloud run services update api \
  --project=<dzeroth-dev|dzeroth-prod> --region=asia-south1 \
  --update-env-vars DEGRADED_MODE=off
```

This is a live env-var update on the existing revision's config — it does not require rebuilding or redeploying an
image, and it's instantly reversible.

## If it's abuse/scraping, not a bug
- Cloud Run `max_instance_count = 3` already caps the blast radius (Terraform: `modules/cloud-run-api`) — cost cannot
  exceed 3 instances' worth of compute regardless of request volume.
- Confirm Firebase App Check is enforced (see `security-checklist` skill) — most scripted abuse dies here for free.
- Per-user/IP quotas live in Firestore/in-memory (Go code); a specific abusive UID/IP can be blocked at the app layer
  without any infra change.
- Do **not** add Cloud Armor or a load balancer — that's a fixed monthly cost forbidden at Stage 0 (`cost-guard` hook).

## If Firestore reads/writes are the binding constraint
1. Check for a missing `Limit()` on a query, a read-in-a-loop, or a cache that stopped working (instance LRU restarted
   on every cold start? TTL too short?) — see `free-tier-budget` skill §3 techniques.
2. Verify the incremental-refresh `since` cursor is actually being sent by clients (a client bug refetching the full
   timeline every time will blow through the daily read quota fast).
3. If genuinely organic growth past ~250–500 DAU: this is the documented Stage 1 trigger. Firestore overage past the
   free quota is cents per 100k ops — **do not panic-provision a cache**. If it's sustained for 7 days, architect
   writes an ADR per `free-tier-budget` skill §6 (Memorystore/Cloud SQL) — not before.

## Last resort (human decision only — never automate)
Detaching the billing account from the project stops all billable activity but can lead to service/resource deletion.
Do not do this without explicit sign-off from the founder; prefer `DEGRADED_MODE=readonly` + investigating.

## After the spike
- Note the cause and the fix in `docs/reviews/cost-model.md` (sre-performance owns the running actuals-vs-model table).
- If a code fix is needed, ship it through the normal `ship-feature` workflow — degraded mode is a stopgap, not a fix.
- Confirm `DEGRADED_MODE=off` is restored once the underlying issue is resolved.
