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

  // Rollback and release protection. Artifact Registry: "If an artifact matches the criteria in both the delete
  // policy and the keep policy, the artifact is kept" (docs.cloud.google.com/artifact-registry/docs/repositories/
  // cleanup-policy), so these beat both DELETE policies below regardless of age. `tag_prefixes` needs
  // tag_state = TAGGED and matches by PREFIX: "v" covers every release tag vX.Y.Z (CI tags are 40-hex git SHAs and
  // `sha256-<digest>.sbom` manifests; neither starts with "v"). The `.sbom` manifest of a protected image is NOT
  // protected (its tag starts with "sha256-"); it is not needed to pull or roll back the image.
  dynamic "cleanup_policies" {
    for_each = var.protected_tag_prefixes
    content {
      id     = "keep-tag-${cleanup_policies.value}"
      action = "KEEP"
      condition {
        tag_state    = "TAGGED"
        tag_prefixes = [cleanup_policies.value]
      }
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
