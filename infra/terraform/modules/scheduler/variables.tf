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
    Map of job name => { schedule (unix-cron), path, attempt_deadline_seconds (optional) }.
    Cloud Scheduler's free tier is 3 jobs per BILLING ACCOUNT, shared across dev + prod — keep the
    combined total across both envs' tfvars at or under 3.

    attempt_deadline_seconds: how long Cloud Scheduler waits for one attempt before it cancels it and
    retries. Omit it (null) to use request_timeout_seconds, which is what existing jobs do. Cloud
    Scheduler allows 15 s to 30 min (1800 s) for HTTP targets. Keep it above the route's own deadline
    and above the Cloud Run request timeout.
  EOT
  type = map(object({
    schedule                 = string
    path                     = string
    attempt_deadline_seconds = optional(number)
  }))

  validation {
    condition = alltrue([
      for j in values(var.jobs) :
      j.attempt_deadline_seconds == null ? true : (j.attempt_deadline_seconds >= 15 && j.attempt_deadline_seconds <= 1800)
    ])
    error_message = "attempt_deadline_seconds must be between 15 and 1800 (Cloud Scheduler HTTP target limits)."
  }

  default = {
    "daily-maintenance" = {
      schedule = "0 3 * * *"
      path     = "/internal/cron/daily-maintenance"
    }
  }
}
