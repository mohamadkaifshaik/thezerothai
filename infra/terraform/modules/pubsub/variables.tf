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
    push_path = string # e.g. "/internal/pubsub/media-processing"
  }))
  default = {
    "media-processing" = {
      push_path = "/internal/pubsub/media-processing"
    }
    "notifications-fanout" = {
      push_path = "/internal/pubsub/notifications-fanout"
    }
  }
}

variable "labels" {
  type    = map(string)
  default = {}
}
