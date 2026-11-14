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
      # Collection group ID — actual docs live at users/{uid}/notifications/{id}.
      # TTL field config is keyed by collection group, not path.
      collection = "notifications"
      field      = "expireAt"
    }
    exports_expire_at = {
      collection = "exports"
      field      = "expireAt"
    }
    # Set when a report is resolved (resolvedAt + 90 days); absent while OPEN, so open reports never expire.
    reports_expire_at = {
      collection = "reports"
      field      = "expireAt"
    }
    # The copied text of a MESSAGE report at reports/{id}/evidence/message; expireAt =
    # filing + 180 days, shortened to resolvedAt + 90 days when the report is resolved. Collection-group key; the report stays.
    report_evidence_expire_at = {
      collection = "evidence"
      field      = "expireAt"
    }
    # The moderation removal log (postRemovals/{postId}); expireAt = createdAt + 32 days
    # (posts.RemovalRetention), set against the 30-day timeline since token. Edited only, not applied.
    post_removals_expire_at = {
      collection = "postRemovals"
      field      = "expireAt"
    }
    # Finished scheduled posts (PUBLISHED / CANCELLED / FAILED) at users/{uid}/scheduled/{id}; expireAt is
    # set when the item leaves PENDING (+7 days), absent while PENDING so pending items never expire. Collection-group key.
    scheduled_expire_at = {
      collection = "scheduled"
      field      = "expireAt"
    }
    # A poll vote (pollVotes/{postId}_{uid}); expireAt = the poll's closesAt + 30 days
    # (POLL_VOTE_TTL_AFTER_CLOSE), so the votes on a deleted poll post expire by TTL. Edited only, not applied: apply
    # it before FEATURE_POLLS leaves off in a project (otherwise vote docs simply stay).
    poll_votes_expire_at = {
      collection = "pollVotes"
      field      = "expireAt"
    }
    # A beacon (beacons/{beaconId}); expireAt = startAt + 30 days (beacons.ExpireAfterStart), so finished plans
    # leave on their own. Edited only, not applied: apply it before FEATURE_BEACONS leaves off in a project.
    beacons_expire_at = {
      collection = "beacons"
      field      = "expireAt"
    }
    # A beacon's participant rows (beacons/{beaconId}/beaconParticipants/{uid}); expireAt is the beacon's, because a
    # parent's TTL does not cascade to its subcollection. Collection-group key. Edited only, not applied.
    beacon_participants_expire_at = {
      collection = "beaconParticipants"
      field      = "expireAt"
    }
    # A durable work item (outbox/{kind}:{key}, backend/pkg/platform/outbox); expireAt = createdAt + 30 days. The
    # sweep deletes delivered items; the TTL only removes one no sweep ever delivered. Edited only, not applied.
    outbox_expire_at = {
      collection = "outbox"
      field      = "expireAt"
    }
    # A view dedupe record (users/{uid}/impressions/{postId}_{yyyymmdd}, F1 post views); expireAt = createdAt + 48 h.
    # Collection-group key. The account erasure deletes them outright; the TTL only keeps the subcollection small.
    # Edited only, not applied: apply it before FEATURE_POST_VIEWS leaves off in a project.
    impressions_expire_at = {
      collection = "impressions"
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
