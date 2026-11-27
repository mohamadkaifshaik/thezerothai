// One dashboard (5 charts from free-tier-budget §5), one uptime check, and a
// small handful of alert policies. Free at Stage 0 volumes, with approved exceptions: the auth-admin log-based metric +
// alert policy (~$0.40/month), and the prod ops alerts for dead-lettered messages, failing Scheduler jobs and the
// daily-maintenance heartbeat (founder-approved 2026-11-04). Pending the owner's cost approval: the session-revoke failure
// alert (prod) and the E2EE epoch order fallback alert (dev and prod), sections 10 and 11. Each billable resource carries
// a cost-approved marker.

resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.founder_emails)

  project      = var.project_id
  type         = "email"
  display_name = "Founder alert: ${each.value}"

  labels = {
    email_address = each.value
  }
}

locals {
  # Each chart: title, metric type, aligner, alignment period (seconds as a string+"s").
  charts = [
    {
      title   = "Firestore reads/day"
      metric  = "firestore.googleapis.com/document/read_count"
      aligner = "ALIGN_SUM"
      period  = "86400s"
    },
    {
      title   = "Firestore writes/day"
      metric  = "firestore.googleapis.com/document/write_count"
      aligner = "ALIGN_SUM"
      period  = "86400s"
    },
    {
      title   = "Cloud Run requests (rate)"
      metric  = "run.googleapis.com/request_count"
      aligner = "ALIGN_RATE"
      period  = "60s"
    },
    {
      title   = "Cloud Run instance count"
      metric  = "run.googleapis.com/container/instance_count"
      aligner = "ALIGN_MEAN"
      period  = "60s"
    },
    {
      title   = "Cloud Run request latency p95 by revision (ms)"
      metric  = "run.googleapis.com/request_latencies"
      aligner = "ALIGN_PERCENTILE_95"
      period  = "60s"
    },
    {
      title   = "Cloud Run request latency p99 by revision (ms)"
      metric  = "run.googleapis.com/request_latencies"
      aligner = "ALIGN_PERCENTILE_99"
      period  = "60s"
    },
  ]

  # The Monitoring API drops position fields equal to 0 and adds targetAxis = "Y1" on read-back. Mirror that
  # normalized form here (omit zero xPos/yPos, set targetAxis) so provider upgrades do not leave a perpetual plan diff.
  chart_tiles = [
    for i, c in local.charts : merge({
      width  = 6
      height = 4
      widget = {
        title = c.title
        xyChart = {
          dataSets = [{
            timeSeriesQuery = {
              timeSeriesFilter = {
                filter = "metric.type=\"${c.metric}\" resource.type=\"${startswith(c.metric, "run.googleapis.com/") ? "cloud_run_revision" : "firestore_instance"}\""
                aggregation = {
                  alignmentPeriod  = c.period
                  perSeriesAligner = c.aligner
                }
              }
            }
            plotType   = "LINE"
            targetAxis = "Y1"
          }]
        }
      }
      },
      (i % 2) * 6 == 0 ? {} : { xPos = (i % 2) * 6 },
      floor(i / 2) * 4 == 0 ? {} : { yPos = floor(i / 2) * 4 },
    )
  ]

  egress_tile = {
    width  = 12
    height = 4
    yPos   = 12
    widget = {
      title = "GCS egress (network sent bytes, media bucket)"
      xyChart = {
        dataSets = [{
          timeSeriesQuery = {
            timeSeriesFilter = {
              filter = "metric.type=\"storage.googleapis.com/network/sent_bytes_count\" resource.type=\"gcs_bucket\""
              aggregation = {
                alignmentPeriod  = "3600s"
                perSeriesAligner = "ALIGN_SUM"
              }
            }
          }
          plotType   = "LINE"
          targetAxis = "Y1"
        }]
      }
    }
  }

  # Messages that exhausted retries, per subscription (dead-lettered). Any non-zero bar needs a look;
  # the daily-maintenance backstop re-publishes stuck jobs.
  dlq_tile = {
    width  = 12
    height = 4
    yPos   = 16
    widget = {
      title = "Pub/Sub DLQ: dead-lettered messages"
      xyChart = {
        dataSets = [{
          timeSeriesQuery = {
            timeSeriesFilter = {
              filter = "metric.type=\"pubsub.googleapis.com/subscription/dead_letter_message_count\" resource.type=\"pubsub_subscription\""
              aggregation = {
                alignmentPeriod  = "3600s"
                perSeriesAligner = "ALIGN_SUM"
              }
            }
          }
          plotType   = "LINE"
          targetAxis = "Y1"
        }]
      }
    }
  }
}

resource "google_monitoring_dashboard" "free_tier" {
  project = var.project_id

  dashboard_json = jsonencode({
    displayName = "Cost & usage (${var.env})"
    mosaicLayout = {
      columns = 12
      tiles   = concat(local.chart_tiles, [local.egress_tile, local.dlq_tile])
    }
  })
}

// ---------------------------------------------------------------------------
// Uptime check on /health (run.app reserves paths ending in "z", e.g. /healthz, at the Google front end)
// ---------------------------------------------------------------------------
resource "google_monitoring_uptime_check_config" "healthz" {
  project      = var.project_id
  display_name = "api /health (${var.env})"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/health"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.api_hostname
    }
  }
}

// ---------------------------------------------------------------------------
// Alert policies — kept to a small handful.
// ---------------------------------------------------------------------------

// The three ops alert policies became conditional (R4, founder decision 2026-10-10: prod only). These keep the
// existing prod state addresses so the change is a no-op there.
moved {
  from = google_monitoring_alert_policy.uptime_failing
  to   = google_monitoring_alert_policy.uptime_failing[0]
}

moved {
  from = google_monitoring_alert_policy.run_5xx_rate
  to   = google_monitoring_alert_policy.run_5xx_rate[0]
}

moved {
  from = google_monitoring_alert_policy.firestore_reads_near_quota
  to   = google_monitoring_alert_policy.firestore_reads_near_quota[0]
}

// 1. Uptime check fails for 5 minutes.
resource "google_monitoring_alert_policy" "uptime_failing" {
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = "api /health uptime check failing (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "Uptime check failure ratio"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" resource.type=\"uptime_url\" metric.label.\"check_id\"=\"${google_monitoring_uptime_check_config.healthz.uptime_check_id}\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  alert_strategy {
    auto_close = "1800s"
  }
}

// 2. Cloud Run 5xx count: a plain number of failures in 10 minutes, summed across revisions, not a percentage. A rate
// threshold needs steady traffic: at launch volumes a full outage never reached 0.05 failures/s. A ratio is no better
// here, because one failed request out of two is 50%. Raise run_5xx_per_10min as traffic grows.
resource "google_monitoring_alert_policy" "run_5xx_rate" {
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = "api 5xx > ${var.run_5xx_per_10min} in 10 min (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "5xx responses, 10 min sum, all revisions"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\" metric.label.\"response_code_class\"=\"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.run_5xx_per_10min
      duration        = "0s"

      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  alert_strategy {
    auto_close = "1800s"
  }
}

// 3. Firestore reads > 40k in a day — 80% of the 50k/day free quota, early
// cost warning.
// The threshold is a variable (250k/day in credit mode, back to 40k on 2026-12-22). The display name is
// unchanged at the default so Stage 0 plans show no diff.
resource "google_monitoring_alert_policy" "firestore_reads_near_quota" {
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = var.firestore_reads_alert_per_day == 40000 ? "Firestore reads > 40k/day, 80% of free quota (${var.env})" : "Firestore reads > ${var.firestore_reads_alert_per_day}/day (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "Firestore document reads, daily sum"
    condition_threshold {
      filter          = "metric.type=\"firestore.googleapis.com/document/read_count\" resource.type=\"firestore_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.firestore_reads_alert_per_day
      duration        = "0s"

      aggregations {
        alignment_period   = "86400s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  alert_strategy {
    auto_close = "86400s"
  }
}

// 4. Control C4: unexpected Firebase Auth mutation volume. The runtime SA holds a custom role that can
// disable/delete ANY Auth user (IAM cannot scope it to one uid); code controls C1-C3 limit it to the caller's own
// uid, and this alert detects misuse after the fact. Expected ~9 deletions/month; the metric counts successful deletes (op=delete, outcome=ok: one per deletion) plus ERROR refusals. The read-only `get` op (export, M2 sign-up check) never matches.
// Since H1 (security review L3) it also counts session revokes: op=revoke_sessions with outcome=ok (one per REMOTE device
// removal that cut sessions; RevokeRefreshTokens on the caller's own uid) and outcome=capped (WARN, a revoke skipped by the
// per-uid daily cap KEYS_SESSION_REVOKES_PER_DAY). A revoke that fails (outcome=error) has its own alert below
// (keys_session_revoke_failed). not_found never matches. See auth_admin_alert_per_hour for why the threshold moved.
// Response: set FEATURE_ACCOUNT_LIFECYCLE=off, remove the accountLifecycleAuth binding, investigate.
// Cost: the only recurring charge of account lifecycle, ~$0.40/month TOTAL, prod only (var.enable_auth_admin_alert; dev has no
// alert and relies on log inspection). The label-free log-based counter is inside the free metric ingestion
// allotment, so it stays in both envs at $0. Founder-approved 2026-10-07, prod-only 2026-10-08.
resource "google_logging_metric" "auth_admin_mutations" { # cost-approved: ADR-0011
  project     = var.project_id
  name        = "auth_admin_mutations"
  description = "Successful Firebase Auth delete calls (one per deletion), session revokes (revoke_sessions ok, plus capped by the daily cap) and C1 refusals (ERROR auth_admin_refused) made by the api (ADR-0011 C3/C1, H1)."
  filter      = "resource.type=\"cloud_run_revision\" AND ((jsonPayload.auth_admin_op=\"delete\" AND jsonPayload.outcome=\"ok\") OR (jsonPayload.auth_admin_op=\"revoke_sessions\" AND (jsonPayload.outcome=\"ok\" OR jsonPayload.outcome=\"capped\")) OR (severity=ERROR AND jsonPayload.outcome=\"refused\"))"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "auth_admin_mutations" { # cost-approved: ADR-0011
  count        = var.enable_auth_admin_alert ? 1 : 0
  project      = var.project_id
  display_name = "Firebase Auth mutations > ${var.auth_admin_alert_per_hour}/hour (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "auth_admin_mutations, 1 h sum"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.auth_admin_mutations.name}\" resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.auth_admin_alert_per_hour
      duration        = "0s"

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "Unexpected volume of Firebase Auth disable/delete/revoke calls (ADR-0011 C4, H1). Logs Explorer: jsonPayload.auth_admin_op:* shows op, outcome and uid_hash; many revoke_sessions lines or any outcome=\"capped\" point at device-removal abuse or a client retry loop, many deletes at account lifecycle. Set FEATURE_ACCOUNT_LIFECYCLE=off, remove the accountLifecycleAuth IAM binding on the api runtime SA, then investigate. (account lifecycle)."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

// 5. Request-flood detector (credit mode). Cloud Run bills every request that reaches the container, even
// ones our limiters answer with 429, and requests are not capped by max-instances: a 1,000 req/s flood is about
// INR 3,283/day. This metric lags by minutes. Default 50,000 requests/hour is about
// 14 req/s, 10x the 3k-DAU average. Alerting is not charged before 2027-09-01 (pricing page, 2026-10-23).
// Off by default (var.enable_request_flood_alert) so Stage 0 plans do not change.
resource "google_monitoring_alert_policy" "request_flood" { # cost-approved: ADR-0022 until:2026-12-26
  count        = var.enable_request_flood_alert ? 1 : 0
  project      = var.project_id
  display_name = "api requests > ${var.request_flood_per_hour}/hour, flood or abuse (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "Cloud Run request count, 1 h sum, all revisions"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\" resource.label.\"service_name\"=\"api\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.request_flood_per_hour
      duration        = "0s"

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "Request volume above the credit-mode flood threshold (ADR-0022 D3). Requests are billed even when answered 429, Fastest cost stop: remove the allUsers run.invoker binding on the api service (IAM-denied requests are not billed; lever L2). Then investigate the abuse or cost spike. Restore the invoker afterwards."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

// 6. Dead-lettered Pub/Sub messages: a delivery that used up its retries. Most of these are account deletions, exports and
// post-delete cleanup, so a silent DLQ is a privacy problem as well as a bug. The metric covers every push subscription.
resource "google_monitoring_alert_policy" "dead_lettered_messages" { # cost-approved: founder 2026-11-04 (prod ops alerts)
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Pub/Sub messages dead-lettered (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "dead_letter_message_count, per subscription"
    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/subscription/dead_letter_message_count\" resource.type=\"pubsub_subscription\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.subscription_id"]
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "A message used up its delivery attempts and went to the `<topic>-dlq` topic, which keeps it for 7 days. Find the cause in Error Reporting. To replay, create a subscription on that topic and seek it back. The daily-maintenance backstop republishes stuck account jobs."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

// 7. Cloud Scheduler attempts that failed. The docs name the AttemptFinished entry and show debugInfo on failures, but state
// no severity for it, so the filter accepts either signal. Free log-based metric, like auth_admin_mutations above.
resource "google_logging_metric" "scheduler_failed_attempts" { # cost-approved: founder 2026-11-04 (prod ops alerts)
  project     = var.project_id
  name        = "scheduler_failed_attempts"
  description = "Cloud Scheduler attempts that did not get a success answer from the api."
  filter      = "resource.type=\"cloud_scheduler_job\" AND jsonPayload.\"@type\"=\"type.googleapis.com/google.cloud.scheduler.logging.AttemptFinished\" AND (severity>=ERROR OR jsonPayload.debugInfo:*)"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

// Per job: 4 attempts per run (retry_count = 3), so more than 3 failures in an hour means a run used up its retries, or
// an often-run job keeps failing; one attempt that a retry recovered stays quiet. This sees only attempts that were made and
// failed. It does not see a job that never fired, or a step that failed while the route still answered 2xx.
resource "google_monitoring_alert_policy" "scheduler_failed_attempts" { # cost-approved: founder 2026-11-04 (prod ops alerts)
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Cloud Scheduler job failing (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "scheduler_failed_attempts, 1 h sum"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.scheduler_failed_attempts.name}\" resource.type=\"cloud_scheduler_job\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3
      duration        = "0s"

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.job_id"]
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "A Cloud Scheduler job is failing: the incident names it. daily-maintenance is the account-deletion backstop, so treat it first. Logs Explorer: resource.type=\"cloud_scheduler_job\", then the api's Error Reporting entries for the cron route."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

// 8. The daily-maintenance heartbeat: its success line proves the path end to end (Scheduler, OIDC, Cloud Run, Firestore
// reads), whatever the feature flags say and with no user traffic. /health proves none of that, and section 7 cannot see a
// job that never fired. The line is written by the backstop step, so the later steps of the route are not covered. The
// api writes it from CronHandler; a test there pins it. Free log-based metric, like the ones above.
resource "google_logging_metric" "daily_maintenance_success" { # cost-approved: founder 2026-11-04 (prod ops alerts)
  project     = var.project_id
  name        = "daily_maintenance_success"
  description = "Runs of the account-deletion backstop in daily-maintenance that finished without error."
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.account_job=\"backstop\" AND jsonPayload.outcome=\"ok\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

// A threshold condition, not metric absence: absence can look back 1 day at most (alignment plus duration), which leaves a
// daily job no slack, while a threshold condition goes to 25 hours (Monitoring quotas). The window is 24 h 50 m: alignment
// plus duration must stay within 25 h and leave room for ingestion delay. evaluation_missing_data needs a duration of at
// least 60 s, or it is ignored. Not yet seen firing, and it exists only where enable_ops_alerts is on (prod): after the
// first apply, watch the first missed run, or pause the job for a day, and confirm it opens. A new log metric has no
// history, so the first hours after the apply may open it once before the first run lands.
resource "google_monitoring_alert_policy" "daily_maintenance_missing" { # cost-approved: founder 2026-11-04 (prod ops alerts)
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = "daily-maintenance backstop has not succeeded in 25 hours (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "daily_maintenance_success, 24 h 50 m sum"
    condition_threshold {
      filter                  = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.daily_maintenance_success.name}\" resource.type=\"cloud_run_revision\""
      comparison              = "COMPARISON_LT"
      threshold_value         = 1
      duration                = "60s"
      evaluation_missing_data = "EVALUATION_MISSING_DATA_ACTIVE"

      aggregations {
        alignment_period     = "89400s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "No successful daily-maintenance backstop run in about 25 hours. It is the account-deletion backstop. Check the Cloud Scheduler job first, then the api's Error Reporting entries for cron/daily-maintenance, then Firestore. There is one data point a day, so a lost log-metric point can open this falsely: if the job shows a good run, it closes after the next one."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

// 9. Outbox items that used up their retries. The api writes one ERROR `outbox_item_stuck` line per item that crossed the
// attempt threshold (kind, uid_hash, scrubbed cause); the logger renames slog's msg key to `message`. The metric is labelled
// by kind only: uid_hash and cause are never labels (cardinality, and they stay out of metric data). Free log-based
// metric, like the ones above; the alert is part of the prod ops alerts (enable_ops_alerts), so dev has the metric only.
resource "google_logging_metric" "outbox_item_stuck" { # cost-approved: founder 2026-11-09 (outbox stuck alert)
  project     = var.project_id
  name        = "outbox_item_stuck"
  description = "Outbox items that exhausted their retries (ERROR outbox_item_stuck from the api), by kind."
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"api\" AND severity>=ERROR AND jsonPayload.message=\"outbox_item_stuck\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "kind"
      value_type  = "STRING"
      description = "Outbox item kind (e.g. post_delete)."
    }
  }

  label_extractors = {
    "kind" = "EXTRACT(jsonPayload.kind)"
  }
}

// Any occurrence opens an incident: a stuck item is a durable job (e.g. post-delete cleanup) that is not completing. The
// log line is written once per item, so a count above 0 in 10 minutes is a new stuck item; the incident auto-closes after
// an hour without one. Grouped by kind so each kind gets its own incident.
resource "google_monitoring_alert_policy" "outbox_item_stuck" { # cost-approved: founder 2026-11-09 (outbox stuck alert)
  count        = var.enable_ops_alerts ? 1 : 0
  project      = var.project_id
  display_name = "Outbox item stuck after retries (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "outbox_item_stuck, 10 min sum, per kind"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.outbox_item_stuck.name}\" resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.kind"]
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "An outbox item used up its retries and is stuck; the incident names its kind. Logs Explorer: resource.type=\"cloud_run_revision\" jsonPayload.message=\"outbox_item_stuck\" shows kind, uid_hash and the scrubbed cause, and the api's Error Reporting has a matching entry (outbox sweep). Find and fix the cause in the logged cause field, then check the item is processed or replay it. A privacy-relevant kind such as post_delete cleanup should not be left stuck."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}

// 10. Session revokes that keep failing (H1). A REMOTE device removal revokes the account's Firebase refresh tokens after
// the session cut; when the revoke (stage=revoke) or its note on the removal mark (stage=mark) fails after the one inline
// retry, keys writes one WARN `keys_session_revoke_failed` line (uid_hash, fixed stage, gRPC code; never the error text)
// and answers a retryable UNAVAILABLE before the sweep. The removal stays pending and the lost device's refresh token is
// not revoked until a retry succeeds. The logger renames slog's msg key to `message` (pkg/platform/logger, replaceAttr),
// as in outbox_item_stuck. Label-free counter, free like the metrics above; it exists in both envs.
resource "google_logging_metric" "keys_session_revoke_failed" { # cost-approved: <owner, date> (free log-based metric)
  project     = var.project_id
  name        = "keys_session_revoke_failed"
  description = "REMOTE device removals whose Firebase refresh-token revoke or revokeDone note failed after the inline retry (WARN keys_session_revoke_failed from the api, H1)."
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"api\" AND jsonPayload.message=\"keys_session_revoke_failed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

// More than 3 in an hour: one failed removal is retried by the client, so a single Auth blip writes one or two lines and
// stays quiet; a steady stream means Auth or the accountLifecycleAuth binding is broken for everyone. Prod only, with the
// C4 alert (enable_auth_admin_alert); dev keeps the metric for Logs Explorer and the metric explorer.
resource "google_monitoring_alert_policy" "keys_session_revoke_failed" { # cost-approved: <owner, date> (~$0.20/month, prod only)
  count        = var.enable_auth_admin_alert ? 1 : 0
  project      = var.project_id
  display_name = "Session revoke failures (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "keys_session_revoke_failed, 1 h sum > 3"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.keys_session_revoke_failed.name}\" resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3
      duration        = "0s"

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "REMOTE device removals cannot revoke Firebase refresh tokens (H1): the lost device can keep minting ID tokens until a retry succeeds. Logs Explorer: resource.type=\"cloud_run_revision\" jsonPayload.message=\"keys_session_revoke_failed\" shows uid_hash, stage (revoke or mark) and grpc_code. stage=revoke: check the accountLifecycleAuth binding on the api runtime SA and Firebase Auth status. stage=mark: check Firestore. The removals stay pending and the client retries."
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

// 11. The ordered epoch listing fell back (E2EE receive walks). ListEpochMessages orders by (mlsKey ASC, createdAt ASC),
// which needs a composite index. When Firestore answers FAILED_PRECONDITION (index missing or not READY), messaging fails
// closed with an empty page and writes one ERROR `messaging_epoch_order_fallback` line per request (epoch_order_fallback=true,
// conversation hash, kind; no uid). The request line also carries epoch_order_fallback=true, so the filter matches the
// message, not the field, to count each request once. Any line means the index is not serving: E2EE DM receivers see no
// new messages. The 5a ledger asks for this alert in dev and prod before any prod E2EE_DM change. Free label-free metric.
resource "google_logging_metric" "epoch_order_fallback" { # cost-approved: <owner, date> (free log-based metric)
  project     = var.project_id
  name        = "epoch_order_fallback"
  description = "ListEpochMessages requests that fell back because the messages (mlsKey, createdAt) index is missing or not READY (ERROR messaging_epoch_order_fallback from the api)."
  filter      = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"api\" AND severity>=ERROR AND jsonPayload.message=\"messaging_epoch_order_fallback\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

// Any occurrence in a rolling hour opens it (sum > 0). The window is a sliding one, so the incident opens within minutes
// of the first line; the hour only keeps it open while fallbacks continue. Dev and prod (enable_epoch_order_fallback_alert):
// dev is where a new index lands first, and a dev index that never became READY is the regression this catches.
resource "google_monitoring_alert_policy" "epoch_order_fallback" { # cost-approved: <owner, date> (~$0.20/month per env, dev and prod)
  count        = var.enable_epoch_order_fallback_alert ? 1 : 0
  project      = var.project_id
  display_name = "E2EE epoch order index fallback (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "epoch_order_fallback, 1 h sum > 0"
    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.epoch_order_fallback.name}\" resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "3600s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "ListEpochMessages fell back: the Firestore composite index on messages (mlsKey ASC, createdAt ASC) is missing or not READY, so E2EE DM receivers get empty pages. Check the index in the Firestore console (or gcloud firestore indexes composite list) and deploy firebase/firestore.indexes.json if it is absent. Logs Explorer: resource.type=\"cloud_run_revision\" jsonPayload.message=\"messaging_epoch_order_fallback\" shows the conversation hash and kind. It closes an hour after the last fallback."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}
