variable "project_id" {
  description = "GCP project ID whose Cloud Vision consumer quota is capped."
  type        = string
}

variable "safe_search_requests_per_minute" {
  description = <<-EOT
    Project-wide cap on SAFE_SEARCH_DETECTION requests per minute (and on the umbrella Vision request counter).
    Default 30 = 3.3x the realistic peak minute at the credit-mode ceiling (3,000 DAU, VISION_MONTHLY_CAP 40,000
    units a month: about 9 calls a minute at the busiest minute; arithmetic in docs/runbooks/ci-enforcement.md).
    The Vision default is 1,800. Raise it if finalizes start failing with RESOURCE_EXHAUSTED from vision.googleapis.com.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.safe_search_requests_per_minute >= 10 && var.safe_search_requests_per_minute <= 1800
    error_message = "safe_search_requests_per_minute must be between 10 (below that the app itself is throttled) and 1800 (the Vision default, i.e. no cap)."
  }
}

variable "unused_feature_limit" {
  description = "Per-minute (or per-day/concurrent) limit for every Vision feature the app does not call (labels, OCR, faces, web, Product Search, async). 0 blocks them. If the Service Usage API ever rejects 0, use 1."
  type        = number
  default     = 0

  validation {
    condition     = var.unused_feature_limit >= 0 && var.unused_feature_limit <= 1
    error_message = "unused_feature_limit must be 0 or 1."
  }
}
