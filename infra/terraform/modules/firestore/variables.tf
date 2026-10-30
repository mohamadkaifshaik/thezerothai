variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "location" {
  description = <<-EOT
    Firestore location ID (e.g. "asia-south1"). PERMANENT once the database
    is created — there is no in-place migration. Confirm with the human
    before the first `terraform apply`.
  EOT
  type        = string
}

variable "ttl_fields" {
  description = "Map of TTL policies to enable, e.g. { notifications_expire = { collection = \"notifications\", field = \"expireAt\" } }."
  type = map(object({
    collection = string
    field      = string
  }))
  default = {
    idempotency_expire_at = {
      collection = "idempotency"
      field      = "expireAt"
    }
    media_expire_at = {
      collection = "media"
      field      = "expireAt"
    }
    notifications_expire_at = {
      # Collection group ID — actual docs live at users/{uid}/notifications/{id}
      # (ADR-0003); TTL field config is keyed by collection group, not path.
      collection = "notifications"
      field      = "expireAt"
    }
    exports_expire_at = {
      collection = "exports"
      field      = "expireAt"
    }
    # ADR-0016 D2: set when a report is resolved (resolvedAt + 90 days); absent while OPEN, so open reports never expire.
    reports_expire_at = {
      collection = "reports"
      field      = "expireAt"
    }
    # ADR-0016 note 2026-10-30 (W7-36): the copied text of a MESSAGE report at reports/{id}/evidence/message; expireAt =
    # filing + 180 days, shortened to resolvedAt + 90 days when the report is resolved. Collection-group key; the report stays.
    report_evidence_expire_at = {
      collection = "evidence"
      field      = "expireAt"
    }
    # ADR-0016 D10: the moderation removal log (postRemovals/{postId}); expireAt = createdAt + 32 days
    # (posts.RemovalRetention), set against the 30-day timeline since token. Edited only, not applied.
    post_removals_expire_at = {
      collection = "postRemovals"
      field      = "expireAt"
    }
    # ADR-0021: finished scheduled posts (PUBLISHED / CANCELLED / FAILED) at users/{uid}/scheduled/{id}; expireAt is
    # set when the item leaves PENDING (+7 days), absent while PENDING so pending items never expire. Collection-group key.
    scheduled_expire_at = {
      collection = "scheduled"
      field      = "expireAt"
    }
  }
}

variable "weekly_backup_enabled" {
  description = "Weekly scheduled backup of (default). Billed on backup storage only (cents at < 1 GiB). Founder-approved for prod in ADR-0007."
  type        = bool
  default     = false
}

variable "backup_retention" {
  description = "How long each weekly backup is kept, as a duration string."
  type        = string
  default     = "1209600s" # 14 days
}
