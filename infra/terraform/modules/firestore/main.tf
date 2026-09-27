// Firestore Native, `(default)` database only — Stage 0 uses no other database.
//
// IMPORTANT: `location_id` is PERMANENT for the life of the project. There is
// no migration path other than exporting all data and recreating the project.
// The calling root module must have this confirmed by a human before first apply.

resource "google_firestore_database" "default" {
  project     = var.project_id
  name        = "(default)"
  location_id = var.location
  type        = "FIRESTORE_NATIVE"

  concurrency_mode                  = "OPTIMISTIC"
  app_engine_integration_mode       = "DISABLED"
  point_in_time_recovery_enablement = "POINT_IN_TIME_RECOVERY_DISABLED" # PITR is billed; stay at $0
  delete_protection_state           = "DELETE_PROTECTION_ENABLED"

  deletion_policy = "ABANDON" # `terraform destroy` must not silently delete production data

  lifecycle {
    prevent_destroy = true
  }
}

// TTL policies let Firestore delete expired docs for free instead of us
// running a paid cron/backfill job. Fields must be a Timestamp type.
// Per ADR-0003: collection groups `idempotency`, `media`, `notifications`,
// `exports`, field `expireAt` on each — owned by Terraform. An empty
// `index_config {}` exempts the TTL field from single-field indexing (it's
// never queried, only used by the TTL sweep), matching
// `firebase/firestore.indexes.json`, which never declares `expireAt`: no
// field is configured in both places.
resource "google_firestore_field" "ttl" {
  for_each = var.ttl_fields

  project    = var.project_id
  database   = google_firestore_database.default.name
  collection = each.value.collection
  field      = each.value.field

  ttl_config {}

  index_config {}
}

// Weekly backups (ADR-0007, founder-approved for prod). Pay-per-use: backup
// storage only, no fixed fee. Restores are billed as reads, so only on incident.
resource "google_firestore_backup_schedule" "weekly" {
  count = var.weekly_backup_enabled ? 1 : 0

  project   = var.project_id
  database  = google_firestore_database.default.name
  retention = var.backup_retention

  weekly_recurrence {
    day = "SUNDAY"
  }
}
