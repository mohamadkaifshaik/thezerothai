// Billing budget: ~$5/month (in the billing account's currency), alerts at 25/50/90/100% actual spend + 100%
// forecast, emailed to founders AND published to a Pub/Sub topic so a future
// automation (e.g. a tiny Cloud Function flipping DEGRADED_MODE) can react.
//
// NOTE: applying this resource requires the identity running Terraform to
// hold a billing-account-level role (e.g. "Billing Account Costs Manager")
// on var.billing_account. That's a one-time manual grant by a Billing
// Account Admin — Terraform cannot bootstrap its own billing-account access.

// ADR-0022: a second or third budget in the same project must reuse the existing topic (the name is fixed, so a
// second `create` would fail with 409). var.pubsub_topic_id = null (default) keeps today's behaviour: create it.
moved {
  from = google_pubsub_topic.billing_alerts
  to   = google_pubsub_topic.billing_alerts[0]
}

resource "google_pubsub_topic" "billing_alerts" {
  count   = var.pubsub_topic_id == null ? 1 : 0
  project = var.project_id
  name    = "billing-alerts"
  labels  = var.labels
}

locals {
  topic_id = var.pubsub_topic_id == null ? google_pubsub_topic.billing_alerts[0].id : var.pubsub_topic_id

  # var.projects: null (default) = this env's project, exactly as before; [] = the whole billing account (the filter
  # attribute is then omitted); a list = those projects. The API normalizes to the project *number*; using the ID
  # causes a permanent diff.
  filter_projects = var.projects == null ? ["projects/${var.project_number}"] : (
    length(var.projects) == 0 ? null : [for p in var.projects : startswith(p, "projects/") ? p : "projects/${p}"]
  )

  # custom_period takes nested start_date/end_date blocks of numbers; the module input is "YYYY-MM-DD" strings.
  period_start = var.custom_period == null ? null : [for p in split("-", var.custom_period.start) : tonumber(p)]
  period_end   = var.custom_period == null ? null : [for p in split("-", var.custom_period.end) : tonumber(p)]
}

resource "google_billing_budget" "this" {
  billing_account = var.billing_account
  display_name    = coalesce(var.display_name, "Stage 0 budget (${var.env}) ${var.amount} ${var.currency_code}/mo")

  budget_filter {
    projects = local.filter_projects

    # null (default) = leave unset exactly as before (the API default, INCLUDE_ALL_CREDITS, i.e. net of every credit).
    credit_types_treatment = var.credit_types_treatment
    credit_types           = length(var.credit_types) == 0 ? null : var.credit_types

    # calendar_period stays unset (monthly by API default) unless this is a custom period; the two are exclusive.
    dynamic "custom_period" {
      for_each = var.custom_period == null ? [] : [var.custom_period]
      content {
        start_date {
          year  = local.period_start[0]
          month = local.period_start[1]
          day   = local.period_start[2]
        }
        end_date {
          year  = local.period_end[0]
          month = local.period_end[1]
          day   = local.period_end[2]
        }
      }
    }
  }

  amount {
    specified_amount {
      currency_code = var.currency_code
      units         = tostring(var.amount)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.actual_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Skipped for a custom period: whether the API supports FORECASTED_SPEND there is UNVERIFIED (ADR-0022 D3).
  dynamic "threshold_rules" {
    for_each = var.custom_period == null ? [1] : []
    content {
      threshold_percent = 1.0
      spend_basis       = "FORECASTED_SPEND"
    }
  }

  all_updates_rule {
    monitoring_notification_channels = var.notification_channel_ids
    pubsub_topic                     = local.topic_id
    disable_default_iam_recipients   = false # keep GCP's own emails to billing account admins as a backstop
  }
}
