// Media buckets — MUST be in a US region for GCS's Always Free storage
// allowance (5 GB-months, 5k Class A ops, 50k Class B ops, 100 GB egress).
// Two buckets:
//   upload: private, short-lived staging area for direct client PUTs via
//           V4 signed URLs; objects here are never served publicly.
//   media:  public-read, the durable home for moderated/approved media.
// Clients never proxy media through the API (CLAUDE.md design rule 7).

resource "google_storage_bucket" "upload" {
  project                     = var.project_id
  name                        = "${var.project_id}-media-upload" # ADR-0005: exact name checked by firebase/storage.rules
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  public_access_prevention = "enforced"

  lifecycle_rule {
    condition {
      age = 2 # days — sweep abandoned/failed uploads before moderation copies them
    }
    action {
      type = "Delete"
    }
  }

  cors {
    origin          = var.cors_origins
    method          = ["PUT", "OPTIONS"]
    response_header = ["Content-Type", "Content-MD5", "x-goog-*"]
    max_age_seconds = 3600
  }

  labels = var.labels
}

resource "google_storage_bucket" "media" {
  project                     = var.project_id
  name                        = "${var.project_id}-media"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  # Public read only — writes always go through the app (moderation copies
  # the object here after SafeSearch / after the report-driven review path).
  public_access_prevention = "inherited"

  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  lifecycle {
    prevent_destroy = true
  }

  labels = var.labels
}

resource "google_storage_bucket_iam_member" "media_public_read" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

// The runtime SA writes finished uploads into `upload/` and moderated copies
// into `media/`, and issues signed PUT URLs against `upload/`.
resource "google_storage_bucket_iam_member" "runtime_upload_admin" {
  bucket = google_storage_bucket.upload.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.runtime_service_account_email}"
}

resource "google_storage_bucket_iam_member" "runtime_media_admin" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.runtime_service_account_email}"
}

// Account-export bucket (ADR-0011 D-B, option B). Private, never served publicly: the API writes one export object
// per request and hands the user a short-lived V4 signed GET URL. The 7-day lifecycle matches EXPORT_RETENTION
// (168h); it lives on its own bucket so it can never touch upload/ (2 days) or media/ objects. No CORS: downloads
// are plain navigations, not XHR. Same US region as the other buckets for the GCS free tier.
resource "google_storage_bucket" "exports" {
  project                     = var.project_id
  name                        = "${var.project_id}-exports" # must equal config.go's default EXPORT_BUCKET
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  force_destroy               = false

  public_access_prevention = "enforced"

  # Export objects hold full PII. The GCS default soft delete keeps deleted/expired objects recoverable for 7 days,
  # which would defeat the 7-day expiry and right-to-delete. Disable it (0 = off). Founder decision 2026-10-08 (M3).
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    condition {
      age = 7 # days; keep in step with EXPORT_RETENTION
    }
    action {
      type = "Delete"
    }
  }

  labels = var.labels
}

resource "google_storage_bucket_iam_member" "runtime_exports_admin" {
  bucket = google_storage_bucket.exports.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.runtime_service_account_email}"
}
