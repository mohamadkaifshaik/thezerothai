variable "project_id" {
  type = string
}

variable "push_base_url" {
  description = <<-EOT
    Base URL Pub/Sub calls (push_endpoint) AND the OIDC audience it stamps on the token, e.g.
    https://api-<project_number>.<region>.run.app. Must be byte-for-byte the same value passed as
    `internal_oidc_audience` to the cloud-run-api module — pass the root module's precomputed
    deterministic URL local here, not `module.cloud_run_api.url` (which would create a dependency
    cycle back into that module's own env vars).
  EOT
  type        = string
}

variable "pubsub_push_service_account_email" {
  description = "OIDC identity Pub/Sub uses to call push endpoints (iam module's pubsub_push SA)."
  type        = string
}

variable "pubsub_service_agent_email" {
  description = "The project's Pub/Sub service agent, e.g. service-<PROJECT_NUMBER>@gcp-sa-pubsub.iam.gserviceaccount.com."
  type        = string
}

variable "topics" {
  description = "Map of topic name => push config. Keep this list small (10 GiB/month messages free)."
  type = map(object({
    push_path             = string # e.g. "/internal/pubsub/media-processing"
    minimum_backoff       = optional(string, "10s")
    max_delivery_attempts = optional(number, 5)
  }))
  default = {
    "media-processing" = {
      push_path = "/internal/pubsub/media-processing"
    }
    "notifications-fanout" = {
      push_path = "/internal/pubsub/notifications-fanout"
    }
    # ADR-0011 D-A: shared jobs topic (account delete/export self-chaining; P2 snapshot refresh reuses it). The
    # handler nacks with 429 to gate itself, so redelivery waits >= 60 s and 10 attempts leave room for real errors.
    "jobs" = {
      push_path             = "/internal/pubsub/jobs"
      minimum_backoff       = "60s"
      max_delivery_attempts = 10
    }
  }
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "runtime_service_account_email" {
  description = "Runtime SA of the api service; granted roles/pubsub.publisher on runtime_publisher_topics only (not project-wide)."
  type        = string
}

variable "runtime_publisher_topics" {
  description = "Topic names (keys of var.topics) the api actually publishes to. Code publishes only to `jobs` (JOBS_TOPIC); media-processing and notifications-fanout have no publisher yet, so add them here when one lands."
  type        = set(string)
  default     = ["jobs"]
}
