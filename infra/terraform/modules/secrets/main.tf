// Secret Manager — only for values that truly can't be plain env config
// (CLAUDE.md: "most config is plain env vars"). Stay at or under 6 active
// versions total and 10k accesses/month (free tier); read once at startup,
// don't poll. Terraform creates the secret container; the *value* is set
// out-of-band (gcloud / console) so it never lands in state or a PR diff.

resource "google_secret_manager_secret" "secrets" {
  for_each = toset(var.secret_ids)

  project   = var.project_id
  secret_id = each.value

  replication {
    auto {}
  }

  labels = var.labels
}

resource "google_secret_manager_secret_iam_member" "runtime_accessor" {
  for_each = toset(var.secret_ids)

  project   = var.project_id
  secret_id = google_secret_manager_secret.secrets[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.runtime_service_account_email}"
}

// ---------------------------------------------------------------------------
// Secrets whose value is pure random material with no human-meaningful
// content (e.g. an HMAC signing key) — Terraform generates and seeds the
// initial version itself. Unlike `secret_ids` above, a manual out-of-band
// step here isn't safer, just a step someone could forget or under-fill;
// the value still never appears in a PR diff (only in state, same as any
// other Terraform-managed sensitive attribute). Rotate by tainting the
// `random_password` resource and re-applying (adds a new version; old
// versions can be disabled once the new one is confirmed live).
// ---------------------------------------------------------------------------
resource "random_password" "generated" {
  for_each = var.generated_secret_ids

  length  = 64 # ASCII chars used as raw key bytes — well over the required >= 32 bytes.
  special = false
}

resource "google_secret_manager_secret" "generated" {
  for_each = var.generated_secret_ids

  project   = var.project_id
  secret_id = each.value

  replication {
    auto {}
  }

  labels = var.labels
}

resource "google_secret_manager_secret_version" "generated" {
  for_each = var.generated_secret_ids

  secret      = google_secret_manager_secret.generated[each.value].id
  secret_data = random_password.generated[each.value].result
}

// Scoped to this one secret only — never project-wide (see iam module notes).
resource "google_secret_manager_secret_iam_member" "generated_runtime_accessor" {
  for_each = var.generated_secret_ids

  project   = var.project_id
  secret_id = google_secret_manager_secret.generated[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.runtime_service_account_email}"
}
