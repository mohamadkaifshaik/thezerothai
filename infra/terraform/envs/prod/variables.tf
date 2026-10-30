variable "project_id" {
  description = "GCP project ID for prod, e.g. \"dzeroth-prod\"."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID, format XXXXXX-XXXXXX-XXXXXX. Same billing account as dev."
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
    Defaults to "asia-south1" per CLAUDE.md — founder-confirmed 2026-09-27 (ADR-0007).
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
  description = "Origins allowed to PUT to the upload bucket (production web app domain(s) only — no localhost in prod)."
  type        = list(string)
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
  default = "eacd65c0-c4fd-4c48-9e58-7d8c791ed585"
}

variable "android_key_uid" {
  description = "UID of the Firebase-auto-created Android API key (security audit M3)."
  type        = string
  # Not a secret: the UID only identifies the key (the key string itself ships in the app).
  default = "2c5b4004-ae22-4176-aeb4-def6aa8eff72"
}

variable "ios_key_uid" {
  description = "UID of the Firebase-auto-created iOS API key (security audit M3)."
  type        = string
  # Not a secret: the UID only identifies the key (the key string itself ships in the app).
  default = "0bbd8085-c7ab-4077-bebf-938efd9384ba"
}

variable "feature_graph" {
  description = "FEATURE_GRAPH rollout mode for the graph slice (ADR-0008 D6): off | allowlist | percent | on."
  type        = string
  default     = "off"

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
  default     = "off"

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
  default     = "off"

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

variable "feature_messaging" {
  description = "FEATURE_MESSAGING rollout mode for direct messages (ADR-0027 D6; SendMessage and AcceptMessageRequest need it on for the caller, the list, read and delete RPCs only need it not off): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_messaging)
    error_message = "feature_messaging must be one of: off, allowlist, percent, on."
  }
}

variable "feature_messaging_allowlist" {
  description = "FEATURE_MESSAGING_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_messaging_percent" {
  description = "FEATURE_MESSAGING_PERCENT: 0-100, only meaningful when feature_messaging = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_messaging_percent >= 0 && var.feature_messaging_percent <= 100 && floor(var.feature_messaging_percent) == var.feature_messaging_percent
    error_message = "feature_messaging_percent must be an integer 0-100."
  }
}

variable "feature_lists" {
  description = "FEATURE_LISTS rollout mode for Lists and custom Home tabs (ADR-0030 D9; gates every ListService RPC, GetListTimeline, SetHomeTabs LIST entries and GetMe.home_tabs): off | allowlist | percent | on. Default off; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_lists)
    error_message = "feature_lists must be one of: off, allowlist, percent, on."
  }
}

variable "feature_lists_allowlist" {
  description = "FEATURE_LISTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_lists_percent" {
  description = "FEATURE_LISTS_PERCENT: 0-100, only meaningful when feature_lists = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_lists_percent >= 0 && var.feature_lists_percent <= 100 && floor(var.feature_lists_percent) == var.feature_lists_percent
    error_message = "feature_lists_percent must be an integer 0-100."
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

# ---- Scheduled posts (ADR-0021 D1). The sweep job lives in prod only; envs/dev has no Scheduler job.

variable "publish_scheduled_schedule" {
  description = "Cloud Scheduler cron (UTC) for the publish-scheduled sweep job (ADR-0021 D1). Only \"every N minutes\" is accepted, N = 1 to 10 (\"* * * * *\" or \"*/N * * * *\"): a cadence that never fires or leaves gaps above SCHEDULED_MAX_LATENESS (6 h) would silently strand or EXPIRE scheduled posts. Default every 5 minutes: 8,640 requests/month, inside the free tier. A shorter cadence costs Firestore reads (every minute is +1,152 reads/day) and needs the cost-model headroom check; ADR-0022 allows every minute only until 2026-12-22."
  type        = string
  default     = "*/5 * * * *"

  validation {
    condition     = can(regex("^(\\*|\\*/([1-9]|10)) \\* \\* \\* \\*$", var.publish_scheduled_schedule))
    error_message = "publish_scheduled_schedule must be \"* * * * *\" or \"*/N * * * *\" with N from 1 to 10, for example \"*/5 * * * *\"."
  }
}

# ---- ADR-0022 credit mode (time-boxed, prod only). The defaults below are the Stage 0 values: CI plan (prod) runs
# with them and must show no change from this block. The credit values go only in the real, gitignored terraform.tfvars
# (see terraform.tfvars.example). Dates and the cap: docs/adr/0022-credit-funded-runway.md.

variable "min_instance_count" {
  description = "Cloud Run SERVICE-level minimum instances (ADR-0022). 0 = Stage 0. 1 = credit mode only, until 2026-12-22 (about INR 936/month idle, paid by the credit). The module refuses 1 after credit_mode_until in a local plan."
  type        = number
  default     = 0

  validation {
    condition     = var.min_instance_count == 0 || var.min_instance_count == 1
    error_message = "min_instance_count must be 0 or 1."
  }
}

variable "vision_monthly_cap" {
  description = "VISION_MONTHLY_CAP: SafeSearch units per calendar month (ADR-0005). 10000 = Stage 0. ADR-0022 credit mode: 20000, then 40000 once DAU > 1,300 (R4). Each image costs 2 units while VISION_SCREEN_THUMB=true."
  type        = number
  default     = 10000

  validation {
    condition     = var.vision_monthly_cap >= 0 && var.vision_monthly_cap <= 40000 && floor(var.vision_monthly_cap) == var.vision_monthly_cap
    error_message = "vision_monthly_cap must be an integer 0-40000 (0 disables screening spend; above 40000 needs an ADR amendment)."
  }
}

variable "vision_exhausted_policy" {
  description = "VISION_EXHAUSTED_POLICY (ADR-0005): what an upload becomes once the cap is spent. unscreened_established (Stage 0) | reject (credit mode: no unscreened image is ever published)."
  type        = string
  default     = "unscreened_established"

  validation {
    condition     = contains(["unscreened_established", "reject"], var.vision_exhausted_policy)
    error_message = "vision_exhausted_policy must be one of: unscreened_established, reject (backend/pkg/platform/config/config.go)."
  }
}

variable "enable_credit_budgets" {
  description = "Create the ADR-0022 credit-runway budget (whole billing account, gross, custom period) and the prod monthly gross budget. false = Stage 0 (no new resource)."
  type        = bool
  default     = false
}

variable "credit_spend_cap_inr" {
  description = "ADR-0022 gross spend cap for the credit window, in budget_currency_code units (INR). Rule: min(25000, remaining credit on the Billing > Credits page minus the 2000 reserve). Only used when enable_credit_budgets = true. The default is the conservative low figure (20,000 pool minus the 2,000 reserve): a lower cap alerts earlier. Changing it is a founder decision."
  type        = number
  default     = 18000

  validation {
    condition     = var.credit_spend_cap_inr > 0 && var.credit_spend_cap_inr <= 25000 && floor(var.credit_spend_cap_inr) == var.credit_spend_cap_inr
    error_message = "credit_spend_cap_inr must be a whole number 1-25000 (ADR-0022 hard limit; raising it means amending the ADR)."
  }
}

variable "prod_gross_budget_inr" {
  description = "ADR-0022 D3 prod monthly gross budget (about the 1k-DAU profile). Only used when enable_credit_budgets = true."
  type        = number
  default     = 3000
}

variable "enable_request_flood_alert" {
  description = "ADR-0022 D3: alert when Cloud Run requests exceed request_flood_per_hour in an hour. false = Stage 0."
  type        = bool
  default     = false
}

variable "request_flood_per_hour" {
  description = "Requests per hour for the flood alert (50,000 is about 14 req/s). Raise as DAU grows."
  type        = number
  default     = 50000
}

variable "firestore_reads_alert_per_day" {
  description = "Firestore reads/day alert threshold. 40000 = Stage 0 (80% of the free quota). ADR-0022 credit mode: 250000 until 2026-12-22 (about 1,070 DAU)."
  type        = number
  default     = 40000
}

variable "feature_search" {
  description = "FEATURE_SEARCH rollout mode for search (ADR-0028 D8; gates SearchPeople and SearchPosts per caller): off | allowlist | percent | on. Default off. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 6, no prod raise."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_search)
    error_message = "feature_search must be one of: off, allowlist, percent, on."
  }
}

variable "feature_search_allowlist" {
  description = "FEATURE_SEARCH_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_search_percent" {
  description = "FEATURE_SEARCH_PERCENT: 0-100, only meaningful when feature_search = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_search_percent >= 0 && var.feature_search_percent <= 100 && floor(var.feature_search_percent) == var.feature_search_percent
    error_message = "feature_search_percent must be an integer 0-100."
  }
}

variable "feature_trends" {
  description = "FEATURE_TRENDS rollout mode for trends (ADR-0028 D8; gates GetTrends per caller and the trends refresh step (never ramps ahead of search)): off | allowlist | percent | on. Default off. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 6, no prod raise."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_trends)
    error_message = "feature_trends must be one of: off, allowlist, percent, on."
  }
}

variable "feature_trends_allowlist" {
  description = "FEATURE_TRENDS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_trends_percent" {
  description = "FEATURE_TRENDS_PERCENT: 0-100, only meaningful when feature_trends = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_trends_percent >= 0 && var.feature_trends_percent <= 100 && floor(var.feature_trends_percent) == var.feature_trends_percent
    error_message = "feature_trends_percent must be an integer 0-100."
  }
}

variable "feature_polls" {
  description = "FEATURE_POLLS rollout mode for polls (ADR-0029 D12; gates creating a poll per caller; voting needs engagement per caller and polls not globally off; never ramps ahead of engagement; leaves off only once 100 percent of traffic is on a revision that stores and enforces polls, ADR-0021 L-1): off | allowlist | percent | on. Default off. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 6, no prod raise."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_polls)
    error_message = "feature_polls must be one of: off, allowlist, percent, on."
  }
}

variable "feature_polls_allowlist" {
  description = "FEATURE_POLLS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_polls_percent" {
  description = "FEATURE_POLLS_PERCENT: 0-100, only meaningful when feature_polls = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_polls_percent >= 0 && var.feature_polls_percent <= 100 && floor(var.feature_polls_percent) == var.feature_polls_percent
    error_message = "feature_polls_percent must be an integer 0-100."
  }
}

variable "feature_drafts" {
  description = "FEATURE_DRAFTS rollout mode for drafts (ADR-0029 D12; client only, no RPC guard, mirrored to clients through GetMe.enabled_features): off | allowlist | percent | on. Default off. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 6, no prod raise."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_drafts)
    error_message = "feature_drafts must be one of: off, allowlist, percent, on."
  }
}

variable "feature_drafts_allowlist" {
  description = "FEATURE_DRAFTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_drafts_percent" {
  description = "FEATURE_DRAFTS_PERCENT: 0-100, only meaningful when feature_drafts = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_drafts_percent >= 0 && var.feature_drafts_percent <= 100 && floor(var.feature_drafts_percent) == var.feature_drafts_percent
    error_message = "feature_drafts_percent must be an integer 0-100."
  }
}

variable "feature_gif" {
  description = "FEATURE_GIF rollout mode for GIF (ADR-0029 D12; gates CreateUpload with image/gif and CreatePost with a GIF media doc; never ramps ahead of media; leaves off only once 100 percent of traffic is on a revision that enforces it): off | allowlist | percent | on. Default off. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 6, no prod raise."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_gif)
    error_message = "feature_gif must be one of: off, allowlist, percent, on."
  }
}

variable "feature_gif_allowlist" {
  description = "FEATURE_GIF_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_gif_percent" {
  description = "FEATURE_GIF_PERCENT: 0-100, only meaningful when feature_gif = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_gif_percent >= 0 && var.feature_gif_percent <= 100 && floor(var.feature_gif_percent) == var.feature_gif_percent
    error_message = "feature_gif_percent must be an integer 0-100."
  }
}
