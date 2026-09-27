// Billing budget: $5/month, alerts at 25/50/90/100% actual spend + 100%
// forecast, emailed to founders AND published to a Pub/Sub topic so a future
// automation (e.g. a tiny Cloud Function flipping DEGRADED_MODE) can react.
//
// NOTE: applying this resource requires the identity running Terraform to
// hold a billing-account-level role (e.g. "Billing Account Costs Manager")
// on var.billing_account. That's a one-time manual grant by a Billing
// Account Admin — Terraform cannot bootstrap its own billing-account access.

resource "google_pubsub_topic" "billing_alerts" {
  project = var.project_id
  name    = "billing-alerts"
  labels  = var.labels
}

resource "google_billing_budget" "this" {
  billing_account = var.billing_account
  display_name    = "Stage 0 budget (${var.env}) — $${var.amount_usd}/month"

  budget_filter {
    projects = ["projects/${var.project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.amount_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.actual_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = var.notification_channel_ids
    pubsub_topic                     = google_pubsub_topic.billing_alerts.id
    disable_default_iam_recipients   = false # keep GCP's own emails to billing account admins as a backstop
  }
}
