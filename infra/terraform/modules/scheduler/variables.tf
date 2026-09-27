variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "asia-south1"
}

variable "push_base_url" {
  description = <<-EOT
    Base URL Cloud Scheduler calls AND the OIDC audience it stamps on the token. Must be
    byte-for-byte the same value passed as `internal_oidc_audience` to the cloud-run-api module and
    as `push_base_url` to the pubsub module — see that module's variable doc for why.
  EOT
  type        = string
}

variable "pubsub_push_service_account_email" {
  type = string
}

variable "request_timeout_seconds" {
  type    = number
  default = 30
}

variable "jobs" {
  description = <<-EOT
    Map of job name => { schedule (unix-cron), path }. Cloud Scheduler's free
    tier is 3 jobs per BILLING ACCOUNT, shared across dev + prod — keep the
    combined total across both envs' tfvars at or under 3.
  EOT
  type = map(object({
    schedule = string
    path     = string
  }))
  default = {
    "daily-maintenance" = {
      schedule = "0 3 * * *"
      path     = "/internal/cron/daily-maintenance"
    }
  }
}
