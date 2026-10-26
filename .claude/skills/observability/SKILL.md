---
name: observability
description: Logging, metrics, tracing, alerting and cost-usage monitoring using only free GCP/Firebase tooling. Use when adding instrumentation, dashboards, alerts or runbooks.
---

# Observability (free tier)

- **Logs:** `log/slog` JSON to stdout → Cloud Logging (50 GiB/project/month free). Fields: `severity, message,
  logging.googleapis.com/trace, rpc, uid_hash, latency_ms, fs_reads, fs_writes, cache_hit, code`.
  One log line per request, INFO; no request/response bodies, no post text, tokens or emails. Health checks not logged.
- **Metrics:** use the built-in Cloud Run, Firestore, GCS and Pub/Sub metrics (free). Don't create custom or
  log-based metrics unless an ADR says so (they're billable beyond small allotments). Per-RPC read counts come from logs
  (query in Logs Explorer / Log Analytics when needed).
- **Tracing:** Cloud Trace via OpenTelemetry with **1% sampling** (plus always-sample on errors) — keep well inside the free span allotment.
  Flutter sends `traceparent` so a slow request can be followed end to end.
- **Errors:** Error Reporting picks up `severity=ERROR` logs with stack traces automatically (free). Email notifications on new errors.
- **Client:** Firebase Crashlytics (free) + Performance Monitoring optional.
- **Dashboard (Terraform):** Firestore reads/day, writes/day, Cloud Run requests + instance count + p95 latency, GCS egress, Pub/Sub oldest unacked age.
- **Alerts (keep ≤ 3 conditions; check Monitoring pricing before adding more):**
  1. Uptime check on `/health` fails 2 of 3 regions for 5 min (`/healthz` is only a legacy alias; `*.run.app` reserves paths ending in `z`).
  2. Cloud Run 5xx ratio > 5% for 10 min.
  3. Firestore reads > 40k in a day (80% of free quota) — early cost warning. Credit mode (ADR-0022 D2) raises prod to 250k until 2026-12-22, then back to 40k.
  Billing budget emails (see `free-tier-budget`) are the cost backstop.
- **SLO-ish targets (Stage 0, reviewed monthly, not paged):** availability ≥ 99.5%, refresh p95 < 400 ms warm.
- **Runbooks:** `docs/runbooks/<topic>.md` — at minimum `cost-spike.md` (covers Firestore quota exhaustion), `abuse-spike.md`, `rollback.md`, `credit-sunset-pause-resume.md`, plus one per module; add one for any new failure mode (counter contention, Pub/Sub backlog) and for each `stage-ladder` trigger that gets an alert.
