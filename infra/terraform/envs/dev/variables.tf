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
  description = "Monthly budget alert threshold in budget_currency_code units. Stage 0 as configured costs about INR 434/month at 300 DAU (ADR-0022, docs/reviews/cost-model.md); this is an alert, not a fixed fee."
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

variable "feature_posts" {
  description = "FEATURE_POSTS rollout mode for the posts and timeline slice (ADR-0010): off | allowlist | percent | on."
  type        = string
  default     = "on"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_posts)
    error_message = "feature_posts must be one of: off, allowlist, percent, on."
  }
}

variable "feature_posts_allowlist" {
  description = "FEATURE_POSTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_posts_percent" {
  description = "FEATURE_POSTS_PERCENT: 0-100, only meaningful when feature_posts = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_posts_percent >= 0 && var.feature_posts_percent <= 100 && floor(var.feature_posts_percent) == var.feature_posts_percent
    error_message = "feature_posts_percent must be an integer 0-100."
  }
}

variable "feature_account_lifecycle" {
  description = "FEATURE_ACCOUNT_LIFECYCLE rollout mode for account deletion and export (ADR-0011): off | allowlist | percent | on."
  type        = string
  default     = "on"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_account_lifecycle)
    error_message = "feature_account_lifecycle must be one of: off, allowlist, percent, on."
  }
}

variable "feature_account_lifecycle_allowlist" {
  description = "FEATURE_ACCOUNT_LIFECYCLE_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_account_lifecycle_percent" {
  description = "FEATURE_ACCOUNT_LIFECYCLE_PERCENT: 0-100, only meaningful when feature_account_lifecycle = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_account_lifecycle_percent >= 0 && var.feature_account_lifecycle_percent <= 100 && floor(var.feature_account_lifecycle_percent) == var.feature_account_lifecycle_percent
    error_message = "feature_account_lifecycle_percent must be an integer 0-100."
  }
}

variable "feature_notifications" {
  description = "FEATURE_NOTIFICATIONS rollout mode for in-app notifications and FCM push (ADR-0017): off | allowlist | percent | on."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_notifications)
    error_message = "feature_notifications must be one of: off, allowlist, percent, on."
  }
}

variable "feature_notifications_allowlist" {
  description = "FEATURE_NOTIFICATIONS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_notifications_percent" {
  description = "FEATURE_NOTIFICATIONS_PERCENT: 0-100, only meaningful when feature_notifications = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_notifications_percent >= 0 && var.feature_notifications_percent <= 100 && floor(var.feature_notifications_percent) == var.feature_notifications_percent
    error_message = "feature_notifications_percent must be an integer 0-100."
  }
}

variable "feature_reports" {
  description = "FEATURE_REPORTS rollout mode for ReportContent (ADR-0016): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_reports)
    error_message = "feature_reports must be one of: off, allowlist, percent, on."
  }
}

variable "feature_reports_allowlist" {
  description = "FEATURE_REPORTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_reports_percent" {
  description = "FEATURE_REPORTS_PERCENT: 0-100, only meaningful when feature_reports = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_reports_percent >= 0 && var.feature_reports_percent <= 100 && floor(var.feature_reports_percent) == var.feature_reports_percent
    error_message = "feature_reports_percent must be an integer 0-100."
  }
}

variable "feature_removed_ids" {
  description = "FEATURE_REMOVED_IDS rollout mode for TimelineService removed_ids (ADR-0016 D10): off | allowlist | percent | on. Default off. Read docs/runbooks/moderation.md section 3b first: suspending an account with 50+ posts resets every client's cached feeds once."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_removed_ids)
    error_message = "feature_removed_ids must be one of: off, allowlist, percent, on."
  }
}

variable "feature_removed_ids_allowlist" {
  description = "FEATURE_REMOVED_IDS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_removed_ids_percent" {
  description = "FEATURE_REMOVED_IDS_PERCENT: 0-100, only meaningful when feature_removed_ids = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_removed_ids_percent >= 0 && var.feature_removed_ids_percent <= 100 && floor(var.feature_removed_ids_percent) == var.feature_removed_ids_percent
    error_message = "feature_removed_ids_percent must be an integer 0-100."
  }
}

variable "feature_media" {
  description = "FEATURE_MEDIA rollout mode for media uploads (P4, ADR-0005). Off keeps CreateUploadUrl/CompleteUpload closed; Vision spend only starts once on: off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_media)
    error_message = "feature_media must be one of: off, allowlist, percent, on."
  }
}

variable "feature_media_allowlist" {
  description = "FEATURE_MEDIA_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_media_percent" {
  description = "FEATURE_MEDIA_PERCENT: 0-100, only meaningful when feature_media = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_media_percent >= 0 && var.feature_media_percent <= 100 && floor(var.feature_media_percent) == var.feature_media_percent
    error_message = "feature_media_percent must be an integer 0-100."
  }
}

variable "feature_engagement" {
  description = "FEATURE_ENGAGEMENT rollout mode for likes / reposts / quotes (P5): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_engagement)
    error_message = "feature_engagement must be one of: off, allowlist, percent, on."
  }
}

variable "feature_engagement_allowlist" {
  description = "FEATURE_ENGAGEMENT_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_engagement_percent" {
  description = "FEATURE_ENGAGEMENT_PERCENT: 0-100, only meaningful when feature_engagement = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_engagement_percent >= 0 && var.feature_engagement_percent <= 100 && floor(var.feature_engagement_percent) == var.feature_engagement_percent
    error_message = "feature_engagement_percent must be an integer 0-100."
  }
}

variable "feature_quotes" {
  description = "FEATURE_QUOTES rollout mode for quote CREATION (additionally requires feature_engagement): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_quotes)
    error_message = "feature_quotes must be one of: off, allowlist, percent, on."
  }
}

variable "feature_quotes_allowlist" {
  description = "FEATURE_QUOTES_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_quotes_percent" {
  description = "FEATURE_QUOTES_PERCENT: 0-100, only meaningful when feature_quotes = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_quotes_percent >= 0 && var.feature_quotes_percent <= 100 && floor(var.feature_quotes_percent) == var.feature_quotes_percent
    error_message = "feature_quotes_percent must be an integer 0-100."
  }
}

variable "feature_bookmarks" {
  description = "FEATURE_BOOKMARKS rollout mode for bookmarks (ADR-0023; AddBookmark needs it on for the caller, List and Remove only need it not off): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_bookmarks)
    error_message = "feature_bookmarks must be one of: off, allowlist, percent, on."
  }
}

variable "feature_bookmarks_allowlist" {
  description = "FEATURE_BOOKMARKS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_bookmarks_percent" {
  description = "FEATURE_BOOKMARKS_PERCENT: 0-100, only meaningful when feature_bookmarks = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_bookmarks_percent >= 0 && var.feature_bookmarks_percent <= 100 && floor(var.feature_bookmarks_percent) == var.feature_bookmarks_percent
    error_message = "feature_bookmarks_percent must be an integer 0-100."
  }
}

variable "feature_profile_extras" {
  description = "FEATURE_PROFILE_EXTRAS rollout mode for profile_extras (ADR-0024 D9; gates UpdateProfile banner, location, website and pin fields and CreateUpload(BANNER), which also needs media): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_profile_extras)
    error_message = "feature_profile_extras must be one of: off, allowlist, percent, on."
  }
}

variable "feature_profile_extras_allowlist" {
  description = "FEATURE_PROFILE_EXTRAS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_profile_extras_percent" {
  description = "FEATURE_PROFILE_EXTRAS_PERCENT: 0-100, only meaningful when feature_profile_extras = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_profile_extras_percent >= 0 && var.feature_profile_extras_percent <= 100 && floor(var.feature_profile_extras_percent) == var.feature_profile_extras_percent
    error_message = "feature_profile_extras_percent must be an integer 0-100."
  }
}

variable "feature_profile_tabs" {
  description = "FEATURE_PROFILE_TABS rollout mode for profile_tabs (ADR-0024 D9; gates GetUserTimeline tab MEDIA and REPOSTS): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_profile_tabs)
    error_message = "feature_profile_tabs must be one of: off, allowlist, percent, on."
  }
}

variable "feature_profile_tabs_allowlist" {
  description = "FEATURE_PROFILE_TABS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_profile_tabs_percent" {
  description = "FEATURE_PROFILE_TABS_PERCENT: 0-100, only meaningful when feature_profile_tabs = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_profile_tabs_percent >= 0 && var.feature_profile_tabs_percent <= 100 && floor(var.feature_profile_tabs_percent) == var.feature_profile_tabs_percent
    error_message = "feature_profile_tabs_percent must be an integer 0-100."
  }
}

variable "feature_likes_list" {
  description = "FEATURE_LIKES_LIST rollout mode for likes_list (ADR-0024 D9; gates ListLikedPosts): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_likes_list)
    error_message = "feature_likes_list must be one of: off, allowlist, percent, on."
  }
}

variable "feature_likes_list_allowlist" {
  description = "FEATURE_LIKES_LIST_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_likes_list_percent" {
  description = "FEATURE_LIKES_LIST_PERCENT: 0-100, only meaningful when feature_likes_list = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_likes_list_percent >= 0 && var.feature_likes_list_percent <= 100 && floor(var.feature_likes_list_percent) == var.feature_likes_list_percent
    error_message = "feature_likes_list_percent must be an integer 0-100."
  }
}

variable "feature_follow_suggestions" {
  description = "FEATURE_FOLLOW_SUGGESTIONS rollout mode for follow_suggestions (ADR-0024 D9; gates ListSuggestedUsers (also needs graph)): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_follow_suggestions)
    error_message = "feature_follow_suggestions must be one of: off, allowlist, percent, on."
  }
}

variable "feature_follow_suggestions_allowlist" {
  description = "FEATURE_FOLLOW_SUGGESTIONS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_follow_suggestions_percent" {
  description = "FEATURE_FOLLOW_SUGGESTIONS_PERCENT: 0-100, only meaningful when feature_follow_suggestions = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_follow_suggestions_percent >= 0 && var.feature_follow_suggestions_percent <= 100 && floor(var.feature_follow_suggestions_percent) == var.feature_follow_suggestions_percent
    error_message = "feature_follow_suggestions_percent must be an integer 0-100."
  }
}

variable "feature_private_accounts" {
  description = "FEATURE_PRIVATE_ACCOUNTS rollout mode for private_accounts (ADR-0025 D12; gates UpdateProfile(is_private=true) for the caller, and ListFollowRequests / RespondToFollowRequest unless the caller is protected): off | allowlist | percent | on. Default off. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 3, no prod raise."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_private_accounts)
    error_message = "feature_private_accounts must be one of: off, allowlist, percent, on."
  }
}

variable "feature_private_accounts_allowlist" {
  description = "FEATURE_PRIVATE_ACCOUNTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_private_accounts_percent" {
  description = "FEATURE_PRIVATE_ACCOUNTS_PERCENT: 0-100, only meaningful when feature_private_accounts = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_private_accounts_percent >= 0 && var.feature_private_accounts_percent <= 100 && floor(var.feature_private_accounts_percent) == var.feature_private_accounts_percent
    error_message = "feature_private_accounts_percent must be an integer 0-100."
  }
}

variable "suggested_user_ids" {
  description = "SUGGESTED_USER_IDS: comma-separated Firebase uids of the curated 'who to follow' fallback (ADR-0024 D8), at most 20, not a secret. Empty = no curated fallback."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([A-Za-z0-9-]{1,128}(,[A-Za-z0-9-]{1,128})*)?$", var.suggested_user_ids))
    error_message = "suggested_user_ids must be comma-separated uids of [A-Za-z0-9-] (1-128 characters each), with no spaces."
  }

  validation {
    condition     = var.suggested_user_ids == "" || length(split(",", var.suggested_user_ids)) <= 20
    error_message = "suggested_user_ids may list at most 20 uids."
  }
}

variable "profile_media_retire" {
  description = "PROFILE_MEDIA_RETIRE (ADR-0024 Amendment 1 A4): which replaced or removed profile images the API deletes 24-48 h later. off = nothing (default) | banner | all (banners and avatars). Per-project retention, not a cohort flag. Set banner only after the media bucket's customTime lifecycle rule (modules/media-buckets) is applied in this project (a tagged object without the rule outlives its TTL'd media document and escapes the account eraser); set all only after the app release that shows a placeholder for an avatar that no longer loads."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "banner", "all"], var.profile_media_retire)
    error_message = "profile_media_retire must be one of: off, banner, all (backend/pkg/platform/config/modes.go)."
  }
}

variable "feature_ui_shell" {
  description = "FEATURE_UI_SHELL rollout mode for the new app shell (client-only; bottom bar + avatar drawer, account chip, rail): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_ui_shell)
    error_message = "feature_ui_shell must be one of: off, allowlist, percent, on."
  }
}

variable "feature_ui_shell_allowlist" {
  description = "FEATURE_UI_SHELL_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_ui_shell_percent" {
  description = "FEATURE_UI_SHELL_PERCENT: 0-100, only meaningful when feature_ui_shell = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_ui_shell_percent >= 0 && var.feature_ui_shell_percent <= 100 && floor(var.feature_ui_shell_percent) == var.feature_ui_shell_percent
    error_message = "feature_ui_shell_percent must be an integer 0-100."
  }
}

variable "feature_shells" {
  description = "FEATURE_SHELLS rollout mode for the W8 coming-soon pages (client-only; Creator tools, Premium, Advertise, Calls and their entries; docs/plans/ui-w8-shells.md): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_shells)
    error_message = "feature_shells must be one of: off, allowlist, percent, on."
  }
}

variable "feature_shells_allowlist" {
  description = "FEATURE_SHELLS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_shells_percent" {
  description = "FEATURE_SHELLS_PERCENT: 0-100, only meaningful when feature_shells = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_shells_percent >= 0 && var.feature_shells_percent <= 100 && floor(var.feature_shells_percent) == var.feature_shells_percent
    error_message = "feature_shells_percent must be an integer 0-100."
  }
}

variable "feature_content_disclosure" {
  description = "FEATURE_CONTENT_DISCLOSURE rollout mode for setting paid_partnership / made_with_ai on CreatePost (ADR-0021 D3): off | allowlist | percent | on. Default off; leaves off only after 100% of traffic is on a revision that stores the labels (ADR-0021 L-1)."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_content_disclosure)
    error_message = "feature_content_disclosure must be one of: off, allowlist, percent, on."
  }
}

variable "feature_content_disclosure_allowlist" {
  description = "FEATURE_CONTENT_DISCLOSURE_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_content_disclosure_percent" {
  description = "FEATURE_CONTENT_DISCLOSURE_PERCENT: 0-100, only meaningful when feature_content_disclosure = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_content_disclosure_percent >= 0 && var.feature_content_disclosure_percent <= 100 && floor(var.feature_content_disclosure_percent) == var.feature_content_disclosure_percent
    error_message = "feature_content_disclosure_percent must be an integer 0-100."
  }
}

variable "feature_reply_audience" {
  description = "FEATURE_REPLY_AUDIENCE rollout mode for setting a reply_policy on CreatePost (ADR-0021 D2); enforcement of a stored policy is never gated: off | allowlist | percent | on. Default off; leaves off only after 100% of traffic is on a revision that stores and enforces the policy (ADR-0021 L-1)."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_reply_audience)
    error_message = "feature_reply_audience must be one of: off, allowlist, percent, on."
  }
}

variable "feature_reply_audience_allowlist" {
  description = "FEATURE_REPLY_AUDIENCE_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_reply_audience_percent" {
  description = "FEATURE_REPLY_AUDIENCE_PERCENT: 0-100, only meaningful when feature_reply_audience = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_reply_audience_percent >= 0 && var.feature_reply_audience_percent <= 100 && floor(var.feature_reply_audience_percent) == var.feature_reply_audience_percent
    error_message = "feature_reply_audience_percent must be an integer 0-100."
  }
}

variable "feature_scheduled_posts" {
  description = "FEATURE_SCHEDULED_POSTS rollout mode for SchedulePost, ListScheduledPosts, CancelScheduledPost and the publish sweep (ADR-0021 D4): off | allowlist | percent | on. Default off; leaves off only after 100% of traffic is on a revision that stores scheduled posts (ADR-0021 L-1)."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_scheduled_posts)
    error_message = "feature_scheduled_posts must be one of: off, allowlist, percent, on."
  }
}

variable "feature_scheduled_posts_allowlist" {
  description = "FEATURE_SCHEDULED_POSTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_scheduled_posts_percent" {
  description = "FEATURE_SCHEDULED_POSTS_PERCENT: 0-100, only meaningful when feature_scheduled_posts = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_scheduled_posts_percent >= 0 && var.feature_scheduled_posts_percent <= 100 && floor(var.feature_scheduled_posts_percent) == var.feature_scheduled_posts_percent
    error_message = "feature_scheduled_posts_percent must be an integer 0-100."
  }
}

variable "feature_replies" {
  description = "FEATURE_REPLIES rollout mode for replies and GetThread (P3): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_replies)
    error_message = "feature_replies must be one of: off, allowlist, percent, on."
  }
}

variable "feature_replies_allowlist" {
  description = "FEATURE_REPLIES_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_replies_percent" {
  description = "FEATURE_REPLIES_PERCENT: 0-100, only meaningful when feature_replies = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_replies_percent >= 0 && var.feature_replies_percent <= 100 && floor(var.feature_replies_percent) == var.feature_replies_percent
    error_message = "feature_replies_percent must be an integer 0-100."
  }
}

variable "feature_profile_snapshot" {
  description = "FEATURE_PROFILE_SNAPSHOT rollout mode for profile snapshot refresh job and snapshot edits: off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_profile_snapshot)
    error_message = "feature_profile_snapshot must be one of: off, allowlist, percent, on."
  }
}

variable "feature_profile_snapshot_allowlist" {
  description = "FEATURE_PROFILE_SNAPSHOT_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_profile_snapshot_percent" {
  description = "FEATURE_PROFILE_SNAPSHOT_PERCENT: 0-100, only meaningful when feature_profile_snapshot = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_profile_snapshot_percent >= 0 && var.feature_profile_snapshot_percent <= 100 && floor(var.feature_profile_snapshot_percent) == var.feature_profile_snapshot_percent
    error_message = "feature_profile_snapshot_percent must be an integer 0-100."
  }
}

# ---- Manual cron testing in dev (ADR-0021 D1, security review L-5). OPT-IN: both default to "" and create nothing. Dev only:
# envs/prod has no such variable on purpose. Whether to set them is the founder's decision (docs/pending.md).

variable "cron_test_invoker" {
  description = "The one person allowed to mint an OIDC identity token for the dev pubsub-push service account, to curl a cron route by hand (ADR-0021 D1), as \"user:someone@example.com\". Empty (default) = no grant is created. Needs cron_test_invoker_expiry. Service accounts, groups, domains, allUsers and allAuthenticatedUsers are refused: a service account would hand the grant to everything that can act as it (security review L-2)."
  type        = string
  default     = ""

  validation {
    condition     = var.cron_test_invoker == "" || can(regex("^user:[^@[:space:]:]+@[^@[:space:]:]+$", var.cron_test_invoker))
    error_message = "cron_test_invoker must be empty or a single person such as \"user:someone@example.com\" (no serviceAccount:, group:, domain:, allUsers or allAuthenticatedUsers)."
  }
}

variable "cron_test_invoker_expiry" {
  description = "UTC timestamp in the exact form \"2026-11-24T00:00:00Z\" after which the cron_test_invoker grant stops working (IAM condition request.time < expiry). Required whenever cron_test_invoker is set. The resource's precondition refuses an expiry that is already past or more than 31 days after the plan (30 days is the intended maximum, one day of slack). Empty (default) = no grant."
  type        = string
  default     = ""

  validation {
    condition     = var.cron_test_invoker_expiry == "" || (can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.cron_test_invoker_expiry)) && can(timeadd(var.cron_test_invoker_expiry, "0s")))
    error_message = "cron_test_invoker_expiry must be a UTC timestamp in the form \"2026-11-24T00:00:00Z\" (no offsets, no fractions)."
  }

  validation {
    condition     = var.cron_test_invoker == "" || var.cron_test_invoker_expiry != ""
    error_message = "cron_test_invoker_expiry is required when cron_test_invoker is set: an unbounded grant is not allowed."
  }
}
