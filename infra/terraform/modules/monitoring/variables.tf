variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "founder_emails" {
  description = "Emails to receive uptime/error/cost alerts."
  type        = list(string)
}

variable "api_hostname" {
  description = "Hostname (no scheme) of the Cloud Run api service, e.g. api-xyz-uc.a.run.app, for the uptime check."
  type        = string
}

variable "enable_auth_admin_alert" {
  description = "ADR-0011 C4: create the (billable, ~$0.40/month) Auth-mutation alert policy. Prod only; the free log-based metric exists regardless."
  type        = bool
  default     = false
}

variable "auth_admin_alert_per_hour" {
  description = "ADR-0011 control C4: alert when Firebase Auth disable/delete mutations in a rolling hour exceed this. Counts one event per deletion (op=delete) plus refusals. Expected ~9 deletions/month, so 5 in an hour is abnormal."
  type        = number
  default     = 5
}

variable "enable_ops_alerts" {
  description = "Create the three ops alert policies (uptime, 5xx rate, Firestore reads). Billable under Cloud Monitoring alerting pricing (~$0.35 per metric reference per month), so prod only (ADR-0007 amendment 2026-10-10, R4). The dashboard and uptime check exist regardless."
  type        = bool
  default     = true
}
