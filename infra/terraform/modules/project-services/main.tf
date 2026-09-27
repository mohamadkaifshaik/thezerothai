// Enables only the GCP APIs this project actually uses at Stage 0.
// Keeping this list tight avoids surprise quota/billing surfaces and keeps
// `gcloud services list` a useful audit trail.

resource "google_project_service" "this" {
  for_each = toset(var.services)

  project                    = var.project_id
  service                    = each.value
  disable_dependent_services = false
  # Never disable APIs on `terraform destroy` — some (e.g. Firestore) refuse
  # to re-enable cleanly and this module is not the place to make that call.
  disable_on_destroy = false
}
