// Single Docker repo per environment. Cleanup policy keeps storage under the
// 0.5 GB Always Free allowance: only the 3 most recent versions of each
// image are kept (regardless of tag state — CI tags every image it pushes,
// so an untagged-only sweep would never reclaim space), untagged images are
// swept after 1 day, and tagged images older than 30 days are swept too.

resource "google_artifact_registry_repository" "api" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Container images for the ${var.env} api service (ko build output)."

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-last-3"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  cleanup_policies {
    id     = "delete-untagged-after-1d"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "86400s"
    }
  }

  // The `keep-last-3` KEEP policy above always wins for the 3 most recent
  // versions regardless of tag state, so this can't delete the images CI
  // (or a rollback) still needs.
  cleanup_policies {
    id     = "delete-tagged-after-30d"
    action = "DELETE"
    condition {
      tag_state  = "TAGGED"
      older_than = "2592000s" # 30 days
    }
  }

  labels = var.labels
}
