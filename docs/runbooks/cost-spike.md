# Runbook: cost spike / free-tier quota exhaustion

## Symptoms
- Billing budget alert email/Pub/Sub message at 25/50/90/100% of the ₹500/month budget (per project), or 100% forecasted.
- Monitoring alert: "Firestore reads > 40k/day, 80% of free quota".
- Firebase console → Firestore → Usage tab trending toward 50k reads / 20k writes / 20k deletes per day.
- Cloud Run instance count pinned at `max_instance_count` (3) — probably also a traffic/abuse spike, see `docs/runbooks/abuse-spike.md`.

## Immediate triage (5 minutes)
1. Open Cloud Monitoring dashboard "Free-tier budget (\<env\>)" (Terraform: `modules/monitoring`) — identify which metric is spiking:
   Firestore reads/writes, Cloud Run requests/instances, or GCS egress.
2. Check Cloud Logging for the request path/RPC driving it (structured logs include `rpc`, `fs_reads`, `fs_writes` per
   the observability skill) — is this real traffic, a retry storm, a bad deploy (e.g. an N+1 query), or abuse/scraping?
3. Check for a spike in errors around the same time (a bug causing retries is a common cause). The Error Reporting API
   is not enabled yet, so use Logs Explorer: `resource.type="cloud_run_revision" AND severity>=ERROR`.

## Flip degraded mode (stops the bleeding, keeps read paths alive)
`DEGRADED_MODE`: `readonly` rejects writes (`ERROR_REASON_DEGRADED_MODE`, "temporarily read-only") while reads keep
working; `nomedia` stops issuing upload URLs; `off` is normal.

**Important:** `gcloud run services update --update-env-vars` creates a **new revision**. In prod, `promote-prod.yml`
pins traffic to a named revision (`--to-revisions`), so that new revision gets **0% traffic and nothing changes**.
Always shift traffic explicitly. This procedure was drilled on dev on 2026-09-28: the flip created `api-00016-kpf` at
0%; after the shift, CreateProfile returned `ERROR_REASON_DEGRADED_MODE` while GetMe still worked; restored to
`api-00017-7xq`.

```bash
G="$LOCALAPPDATA/Google/Cloud SDK/google-cloud-sdk/bin/gcloud.cmd"   # Git Bash on Windows
P="--project=dzeroth-prod --region=asia-south1"                       # or dzeroth-dev

# 0. Which revision serves now, and does the service template carry that same image? If a newer rc has been
#    staged by release-prod, the template has the *rc* image; then flip with --image=<serving image> as well.
"$G" run services describe api $P --format=json | python -c "import json,sys; d=json.load(sys.stdin); print([(t.get('revisionName'),t.get('percent'),t.get('tag')) for t in d['status']['traffic']]); print('template image:', d['spec']['template']['spec']['containers'][0]['image'])"
SERVING=<revision currently at 100%>

# 1. Flip. This creates a new revision at 0%.
"$G" run services update api $P --update-env-vars DEGRADED_MODE=readonly --quiet
NEW=$("$G" run services describe api $P --format="value(status.latestCreatedRevisionName)")

# 2. Shift traffic to it. This is the step that actually turns degraded mode on.
"$G" run services update-traffic api $P --to-revisions=$NEW=100 --quiet

# 3. Verify: a write returns ERROR_REASON_DEGRADED_MODE; GET-style RPCs still work.

# 4. Back to normal: flip to off, then shift to the newest revision the same way.
"$G" run services update api $P --update-env-vars DEGRADED_MODE=off --quiet
OFF=$("$G" run services describe api $P --format="value(status.latestCreatedRevisionName)")
"$G" run services update-traffic api $P --to-revisions=$OFF=100 --quiet
# (dev only: `update-traffic --to-latest` restores dev's normal follow-latest routing)
# Instant fallback while anything is unclear: update-traffic --to-revisions=$SERVING=100
```

## If it's abuse/scraping, not a bug
- Cloud Run `max_instance_count = 3` already caps the blast radius (Terraform: `modules/cloud-run-api`) — cost cannot
  exceed 3 instances' worth of compute regardless of request volume.
- App Check is **monitor-only** at Stage 0 (ADR-0006 amendment), so it won't stop scripted abuse. Follow
  `docs/runbooks/abuse-spike.md` (sign-up kill switch, disabling users, tighter rate limits).
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
