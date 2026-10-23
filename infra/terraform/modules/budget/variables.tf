variable "project_id" {
  type = string
}

variable "project_number" {
  description = "Numeric project number (the budget API normalizes filters to it)."
  type        = string
}

variable "env" {
  type = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX."
  type        = string
}

variable "amount" {
  description = "Monthly budget in currency_code units (whole units)."
  type        = number
  default     = 5
}

variable "currency_code" {
  description = "Must equal the billing account's currency (e.g. INR for Indian accounts) or the API returns 400."
  type        = string
  default     = "USD"
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

// ---- ADR-0022 (credit-funded runway). Every default below reproduces today's budget exactly. ----

variable "display_name" {
  description = "Budget display name (the API allows at most 60 characters). null (default) keeps \"Stage 0 budget (<env>) <amount> <currency>/mo\"."
  type        = string
  default     = null

  validation {
    condition     = var.display_name == null ? true : length(var.display_name) <= 60
    error_message = "display_name must be at most 60 characters (Billing Budget API limit)."
  }
}

variable "pubsub_topic_id" {
  description = "Existing billing-alerts topic id to publish to. null (default) = this instance creates the topic. Set it on every extra budget in the same project (the topic name is fixed)."
  type        = string
  default     = null
}

variable "credit_types_treatment" {
  description = <<-EOT
    null (default) = leave unset: the API default INCLUDE_ALL_CREDITS, spend NET of every credit (a promotional credit hides all usage, so no alert can fire).
    INCLUDE_SPECIFIED_CREDITS with credit_types = ["FREE_TIER"] = GROSS view: only Always Free is subtracted, promotional credit (incl. the Free Trial) is not.
    EXCLUDE_ALL_CREDITS counts Always Free usage as spend and is not used (ADR-0022 D3).
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.credit_types_treatment == null ? true : contains(["INCLUDE_ALL_CREDITS", "EXCLUDE_ALL_CREDITS", "INCLUDE_SPECIFIED_CREDITS"], var.credit_types_treatment)
    error_message = "credit_types_treatment must be null or one of: INCLUDE_ALL_CREDITS, EXCLUDE_ALL_CREDITS, INCLUDE_SPECIFIED_CREDITS."
  }
}

variable "credit_types" {
  description = "Credit types to subtract; only valid with credit_types_treatment = INCLUDE_SPECIFIED_CREDITS (e.g. [\"FREE_TIER\"])."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.credit_types) == 0 || var.credit_types_treatment == "INCLUDE_SPECIFIED_CREDITS"
    error_message = "credit_types may only be set together with credit_types_treatment = INCLUDE_SPECIFIED_CREDITS."
  }
}

variable "projects" {
  description = "null (default) = filter to this env's project (project_number), as before. [] = the whole billing account (dev and account-level charges included). Otherwise project numbers (or projects/<number>)."
  type        = list(string)
  default     = null
}

variable "custom_period" {
  description = "null (default) = the monthly calendar period, as before. Otherwise a one-off window as { start = \"YYYY-MM-DD\", end = \"YYYY-MM-DD\" }; the FORECASTED_SPEND rule is then skipped (support UNVERIFIED)."
  type = object({
    start = string
    end   = string
  })
  default = null

  validation {
    condition = var.custom_period == null ? true : (
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.custom_period.start)) &&
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", var.custom_period.end)) &&
      try(tonumber(replace(var.custom_period.start, "-", "")) <= tonumber(replace(var.custom_period.end, "-", "")), false)
    )
    error_message = "custom_period start and end must be YYYY-MM-DD dates with start <= end."
  }
}
