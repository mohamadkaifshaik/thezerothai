variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "service_name" {
  type    = string
  default = "api"
}

variable "runtime_service_account_email" {
  type = string
}

variable "pubsub_push_service_account_email" {
  type = string
}

variable "image" {
  description = <<-EOT
    Container image to deploy. On first `apply` (before CI has ever built
    anything) use a placeholder public image so the service can be created;
    CI overwrites this with real revisions afterwards (ignored by lifecycle).
  EOT
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "max_instance_count" {
  description = "Hard cap on concurrent instances — cost + blast-radius cap. Changing this needs a PR note with cost impact."
  type        = number
  default     = 3
}

variable "concurrency" {
  type    = number
  default = 80
}

variable "cpu" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "512Mi"
}

variable "request_timeout_seconds" {
  type    = number
  default = 30
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "degraded_mode" {
  description = "off | readonly | nomedia — see docs/runbooks/cost-spike.md."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "readonly", "nomedia"], var.degraded_mode)
    error_message = "degraded_mode must be one of: off, readonly, nomedia."
  }
}

variable "app_check_mode" {
  description = "enforce | monitor — ADR-0006: monitor in both envs for now. Passed through as APP_CHECK_MODE."
  type        = string
  default     = "monitor"

  validation {
    condition     = contains(["enforce", "monitor"], var.app_check_mode)
    error_message = "app_check_mode must be one of: enforce, monitor."
  }
}

variable "internal_oidc_audience" {
  description = <<-EOT
    Audience Go verifies on incoming Pub/Sub push / Cloud Scheduler OIDC tokens for /internal/*
    (ADR-0006 §5). Must be the SAME value the pubsub and scheduler modules use as the OIDC
    `audience` — compute it once in the root module (e.g. the deterministic
    `https://<service>-<project_number>.<region>.run.app` URL from the project number) and pass it
    here AND to those modules, never `module.cloud_run_api.url` (that would be a dependency cycle:
    this module's own env var can't depend on this module's own output).
  EOT
  type        = string
}

variable "internal_oidc_allowed_emails" {
  description = "Service account emails allowed to call /internal/* (pubsub-push SA, + scheduler SA if different). Joined with commas into INTERNAL_OIDC_ALLOWED_EMAILS."
  type        = list(string)
  default     = []
}

variable "secret_env_vars" {
  description = <<-EOT
    Env vars sourced from Secret Manager via `value_source.secret_key_ref` (no volume mount needed).
    Each secret must already exist (see the `secrets` module) and grant this service's runtime SA
    `roles/secretmanager.secretAccessor` on that specific secret.
  EOT
  type = list(object({
    name    = string
    secret  = string # Secret Manager secret ID (short name, not the full resource path)
    version = optional(string, "latest")
  }))
  default = []
}

variable "extra_env_vars" {
  description = "Additional plain (non-secret) env vars as a list of {name, value}."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "labels" {
  type    = map(string)
  default = {}
}
