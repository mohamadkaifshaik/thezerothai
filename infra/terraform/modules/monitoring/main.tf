// One dashboard (5 charts from free-tier-budget §5), one uptime check, and a
// small handful of alert policies. Free at Stage 0 volumes, with one approved exception:
// the ADR-0011 C4 log-based metric + alert policy (~$0.40/month, founder-approved).

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

  # ADR-0011 D-A: messages that exhausted retries on the jobs topic (dead-lettered). Any non-zero bar needs a look;
  # the daily-maintenance backstop re-publishes stuck jobs.
  dlq_tile = {
    width  = 12
    height = 4
    yPos   = 12
    widget = {
      title = "Pub/Sub jobs DLQ: dead-lettered messages"
      xyChart = {
        dataSets = [{
          timeSeriesQuery = {
            timeSeriesFilter = {
              filter = "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" resource.type=\"pubsub_topic\" resource.label.\"topic_id\"=\"jobs-dlq\""
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
    displayName = "Free-tier budget (${var.env})"
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
// Alert policies — kept to a small handful per the observability skill.
// ---------------------------------------------------------------------------

// 1. Uptime check fails for 5 minutes.
resource "google_monitoring_alert_policy" "uptime_failing" {
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

// 2. Cloud Run 5xx rate. NOTE: this is an absolute rate (5xx responses/sec,
// summed across revisions), NOT a percentage of total traffic — computing a
// true error *ratio* needs an MQL condition (dividing 5xx count by total
// count) or a log-based metric, and the observability skill says not to add
// log-based/custom metrics without an ADR (they're billable beyond a small
// free allotment). Named honestly so on-call doesn't misread the threshold
// as "5% of requests"; revisit with an MQL ratio query if false
// positives/negatives at low traffic become a problem.
resource "google_monitoring_alert_policy" "run_5xx_rate" {
  project      = var.project_id
  display_name = "api 5xx rate > 0.05 req/s for 10 min, absolute not % (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "5xx response rate (requests/sec, all revisions summed)"
    condition_threshold {
      filter          = "metric.type=\"run.googleapis.com/request_count\" resource.type=\"cloud_run_revision\" metric.label.\"response_code_class\"=\"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.05
      duration        = "600s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
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
// cost warning (billing budget is the hard cost backstop).
resource "google_monitoring_alert_policy" "firestore_reads_near_quota" {
  project      = var.project_id
  display_name = "Firestore reads > 40k/day, 80% of free quota (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "Firestore document reads, daily sum"
    condition_threshold {
      filter          = "metric.type=\"firestore.googleapis.com/document/read_count\" resource.type=\"firestore_instance\""
      comparison      = "COMPARISON_GT"
      threshold_value = 40000
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

// 4. ADR-0011 control C4: unexpected Firebase Auth mutation volume. The runtime SA holds a custom role that can
// disable/delete ANY Auth user (IAM cannot scope it to one uid); code controls C1-C3 limit it to the caller's own
// uid, and this alert detects misuse after the fact. Expected ~9 deletions/month; the metric counts successful deletes (op=delete, outcome=ok: one per deletion) plus ERROR refusals. The read-only `get` op (export, M2 sign-up check) never matches.
// Response (runbook, T22): set FEATURE_ACCOUNT_LIFECYCLE=off, remove the accountLifecycleAuth binding, investigate.
// Cost: the only recurring charge in ADR-0011, ~$0.40/month TOTAL, prod only (var.enable_auth_admin_alert; dev has no
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
    content   = "Unexpected volume of Firebase Auth disable/delete calls (ADR-0011 C4). Set FEATURE_ACCOUNT_LIFECYCLE=off, remove the accountLifecycleAuth IAM binding on the api runtime SA, then investigate. Runbook: docs/runbooks (account lifecycle)."
  }

  alert_strategy {
    auto_close = "3600s"
  }
}
