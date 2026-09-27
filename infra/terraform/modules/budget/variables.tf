variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX."
  type        = string
}

variable "amount_usd" {
  type    = number
  default = 5
}

variable "actual_thresholds" {
  description = "Threshold percentages (as fractions) on CURRENT_SPEND, in addition to the always-included 100% FORECASTED_SPEND rule."
  type        = list(number)
  default     = [0.25, 0.5, 0.9, 1.0]
}

variable "notification_channel_ids" {
  description = "Cloud Monitoring email notification channel IDs (from the monitoring module)."
  type        = list(string)
}

variable "labels" {
  type    = map(string)
  default = {}
}
