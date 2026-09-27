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
