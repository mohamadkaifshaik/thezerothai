// One dashboard (5 charts from free-tier-budget §5), one uptime check, and a
// small handful of alert policies. Free at Stage 0 volumes, with approved exceptions: the auth-admin log-based metric +
// alert policy (~$0.40/month), and the prod ops alerts for dead-lettered messages, failing Scheduler jobs and the
// daily-maintenance heartbeat (founder-approved 2026-11-04). Each billable resource carries a cost-approved marker.

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
                filter = "metric.type=\"${c.metric}\" resource.type=\"${c.metric == "run.googleapis.com/request_count" || c.metric == "run.googleapis.com/container/instance_count" ? "cloud_run_revision" : "firestore_instance"}\""
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
    yPos   = 8
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
    yPos   = 12
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
// Response: set FEATURE_ACCOUNT_LIFECYCLE=off, remove the accountLifecycleAuth binding, investigate.
// Cost: the only recurring charge of account lifecycle, ~$0.40/month TOTAL, prod only (var.enable_auth_admin_alert; dev has no
// alert and relies on log inspection). The label-free log-based counter is inside the free metric ingestion
// allotment, so it stays in both envs at $0. Founder-approved 2026-10-07, prod-only 2026-10-08.
resource "google_logging_metric" "auth_admin_mutations" { # cost-approved: ADR-0011
  project     = var.project_id
  name        = "auth_admin_mutations"
  description = "Successful Firebase Auth delete calls (one per deletion) plus C1 refusals (ERROR auth_admin_refused) made by the api (ADR-0011 C3/C1)."
  filter      = "resource.type=\"cloud_run_revision\" AND ((jsonPayload.auth_admin_op=\"delete\" AND jsonPayload.outcome=\"ok\") OR (severity=ERROR AND jsonPayload.outcome=\"refused\"))"

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
    content   = "Unexpected volume of Firebase Auth disable/delete calls (ADR-0011 C4). Set FEATURE_ACCOUNT_LIFECYCLE=off, remove the accountLifecycleAuth IAM binding on the api runtime SA, then investigate. (account lifecycle)."
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
