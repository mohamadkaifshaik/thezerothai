output "url" {
  value = google_cloud_run_v2_service.api.uri
}

output "name" {
  value = google_cloud_run_v2_service.api.name
}

output "location" {
  value = google_cloud_run_v2_service.api.location
}

output "latest_ready_revision" {
  value = google_cloud_run_v2_service.api.latest_ready_revision
}
