output "billing_alerts_topic" {
  value = local.topic_id
}

output "budget_name" {
  value = google_billing_budget.this.name
}
