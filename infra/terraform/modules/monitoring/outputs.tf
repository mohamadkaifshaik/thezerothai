output "notification_channel_ids" {
  value = [for c in google_monitoring_notification_channel.email : c.id]
}

output "dashboard_id" {
  value = google_monitoring_dashboard.free_tier.id
}

output "uptime_check_id" {
  value = google_monitoring_uptime_check_config.healthz.uptime_check_id
}
