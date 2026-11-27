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
  description = "ADR-0011 C4: create the (billable, ~$0.40/month) Auth-mutation alert policy, and with it the H1 session-revoke failure alert (~$0.20/month, cost approval pending). Prod only; the free log-based metrics exist regardless."
  type        = bool
  default     = false
}

# 20, raised from 5 when C4 started counting session revokes (H1). Why 20: deletions stay rare (~9/month), but every
# REMOTE device removal that cuts sessions now adds one revoke_sessions event, and one honest user tidying up old phones
# can remove several devices in a row. The per-uid daily revoke cap (KEYS_SESSION_REVOKES_PER_DAY = 10) bounds one user
# at 10 ok events, then capped events. 20 lets one user use the whole cap in an hour, plus a few deletions and refusals,
# without paging; it still pages on two users at the cap in one hour, on a client retry loop past the cap, or on a burst
# of deletions or C1 refusals that no normal hour produces. Lower it again if revokes move to their own alert.
variable "auth_admin_alert_per_hour" {
  description = "ADR-0011 control C4: alert when Firebase Auth mutations in a rolling hour exceed this. Counts one event per deletion (op=delete ok), per session revoke (op=revoke_sessions ok or capped, H1) and per C1 refusal. Deletions are ~9/month; one user can revoke up to 10 times a day (the daily cap), so 20 in an hour is abnormal."
  type        = number
  default     = 20
}

variable "enable_epoch_order_fallback_alert" {
  description = "Create the E2EE epoch order fallback alert (any messaging_epoch_order_fallback line in a rolling hour: the messages (mlsKey, createdAt) index is missing or not READY). Billable like the other alert policies, so it needs the owner's cost approval; meant for dev and prod before any prod E2EE_DM change. The free log-based metric exists regardless."
  type        = bool
  default     = false
}

variable "enable_ops_alerts" {
  description = "Create the ops alert policies (uptime, 5xx count, Firestore reads, dead-lettered messages, failing Scheduler jobs, missed daily-maintenance, stuck outbox items). Billable under Cloud Monitoring alerting pricing (~$0.35 per metric reference per month), so prod only (ADR-0007 amendment 2026-10-10, R4). The dashboard and uptime check exist regardless."
  type        = bool
  default     = true
}

variable "enable_request_flood_alert" {
  description = "ADR-0022 D3: create the request-count flood alert (> request_flood_per_hour requests per hour). Prod, credit mode only; false keeps Stage 0 plans unchanged. Alerting is free before 2027-09-01."
  type        = bool
  default     = false
}

variable "request_flood_per_hour" {
  description = "Requests per rolling hour above which the flood alert fires (50,000 = about 14 req/s). Raise it as DAU grows."
  type        = number
  default     = 50000
}

variable "firestore_reads_alert_per_day" {
  description = "Daily Firestore reads above which the near-quota alert fires. 40000 = 80% of the free 50k (Stage 0). ADR-0022 D2 raises it to 250000 in credit mode until 2026-12-22."
  type        = number
  default     = 40000
}

variable "run_5xx_per_10min" {
  description = "5xx responses in 10 minutes above which the api 5xx alert fires. A count, so it works at low traffic: raise it as traffic grows."
  type        = number
  default     = 5
}
