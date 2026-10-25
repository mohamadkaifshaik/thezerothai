// Cloud Scheduler jobs → api `/internal/cron/*`, OIDC-authenticated.
// Cloud Scheduler's free tier is 3 jobs PER BILLING ACCOUNT (not per
// project) — dev + prod together must stay at or under 3 total. Keep this
// list short; each root module's tfvars says how many it's allowed.

resource "google_cloud_scheduler_job" "jobs" {
  for_each = var.jobs

  project   = var.project_id
  region    = var.region
  name      = each.key
  schedule  = each.value.schedule
  time_zone = "Etc/UTC"

  // A job may carry its own deadline (attempt_deadline_seconds); jobs that do not keep the module-wide
  // request_timeout_seconds, so existing jobs (daily-maintenance: 30s) are unchanged.
  attempt_deadline = "${coalesce(each.value.attempt_deadline_seconds, var.request_timeout_seconds)}s"

  // Every job retries 3 times on a non-2xx answer (the cron routes answer 204, or 500 only when their query fails).
  retry_config {
    retry_count = 3
  }

  http_target {
    http_method = "POST"
    uri         = "${var.push_base_url}${each.value.path}"

    oidc_token {
      service_account_email = var.pubsub_push_service_account_email
      audience              = var.push_base_url
    }
  }
}
