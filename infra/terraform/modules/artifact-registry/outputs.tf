output "repository_id" {
  value = google_artifact_registry_repository.api.repository_id
}

output "repository_url" {
  description = "Push/pull URL, e.g. asia-south1-docker.pkg.dev/PROJECT/api"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.api.repository_id}"
}
