variable "project_id" {
  description = "GCP project ID for dev, e.g. \"dzeroth-dev\"."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX. Same billing account as prod."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo allowed to federate via WIF, as \"owner/name\"."
  type        = string
}

variable "founder_emails" {
  description = "Emails to receive budget/uptime/error alerts."
  type        = list(string)
}

variable "region" {
  description = "Cloud Run / Firestore / Artifact Registry region."
  type        = string
  default     = "asia-south1"
}

variable "firestore_location" {
  description = <<-EOT
    ****************************************************************
    * PERMANENT. Firestore location cannot be changed after the     *
    * database is created — the only way to move it is export all   *
    * data, delete the project's Firestore, and reimport elsewhere. *
    * CONFIRM this value with a human before the first apply.        *
    ****************************************************************
    Defaults to "asia-south1" per CLAUDE.md — founder-confirmed 2026-09-27 (ADR-0007).(Cloud Run/Firestore/Artifact
    Registry colocated in Mumbai for Indian users; Firestore's free daily
    quota applies to the (default) database in any location).
  EOT
  type        = string
  default     = "asia-south1"
}

variable "media_bucket_region" {
  description = "Must be a US region — GCS Always Free storage is US-only. Media bucket is deliberately NOT colocated with Cloud Run/Firestore."
  type        = string
  default     = "us-central1"
}

variable "cors_origins" {
  description = "Origins allowed to PUT to the upload bucket (local dev + this env's web app domain)."
  type        = list(string)
  default     = ["http://localhost:5000", "http://localhost:8080"]
}

variable "android_package_name" {
  type    = string
  default = "com.dzeroth.dzeroth"
}

variable "ios_bundle_id" {
  type    = string
  default = "com.dzeroth.dzeroth"
}

variable "hosting_site_id" {
  description = "Firebase Hosting site ID — must be globally unique across ALL Firebase projects."
  type        = string
}

variable "image" {
  description = "Placeholder image for the very first apply, before CI has built anything. CI-managed afterwards."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "budget_amount" {
  description = "Monthly budget in budget_currency_code units (~$5 at Stage 0)."
  type        = number
  default     = 500
}

variable "budget_currency_code" {
  description = "Must equal the billing account currency (gcloud billing accounts describe ... --format='value(currencyCode)')."
  type        = string
  default     = "INR" # this billing account bills in INR
}

# Find with: gcloud services api-keys list --project=<project_id> --format="table(uid,displayName)"
variable "browser_key_uid" {
  description = "UID of the Firebase-auto-created browser API key (security audit M3)."
  type        = string
  # Not a secret: the UID only identifies the key (the key string itself ships in the app).
  default = "b2413e40-5b82-4c43-9898-6479d55c37c7"
}

variable "android_key_uid" {
  description = "UID of the Firebase-auto-created Android API key (security audit M3)."
  type        = string
  # Not a secret: the UID only identifies the key (the key string itself ships in the app).
  default = "3093a811-6a7e-463e-a30a-9d345152ae2f"
}

variable "ios_key_uid" {
  description = "UID of the Firebase-auto-created iOS API key (security audit M3)."
  type        = string
  # Not a secret: the UID only identifies the key (the key string itself ships in the app).
  default = "e6fc1659-2bc0-46bc-849c-2a82cab88ad3"
}

variable "feature_graph" {
  description = "FEATURE_GRAPH rollout mode for the graph slice (ADR-0008 D6): off | allowlist | percent | on."
  type        = string
  default     = "on"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_graph)
    error_message = "feature_graph must be one of: off, allowlist, percent, on."
  }
}

variable "feature_graph_allowlist" {
  description = "FEATURE_GRAPH_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_graph_percent" {
  description = "FEATURE_GRAPH_PERCENT: 0-100, only meaningful when feature_graph = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_graph_percent >= 0 && var.feature_graph_percent <= 100 && floor(var.feature_graph_percent) == var.feature_graph_percent
    error_message = "feature_graph_percent must be an integer 0-100."
  }
}
