output "billing_alerts_topic" {
  value = google_pubsub_topic.billing_alerts.id
}

output "budget_name" {
  value = google_billing_budget.this.name
}
