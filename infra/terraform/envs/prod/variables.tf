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
  description = "Emails to receive uptime/error alerts."
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
    Defaults to "asia-south1" by project decision — founder-confirmed 2026-09-27 (ADR-0007).
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
  description = "FEATURE_REMOVED_IDS rollout mode for TimelineService removed_ids (ADR-0016 D10): off | allowlist | percent | on. Default off. Suspending an account with 50+ posts resets every client's cached feeds once."
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

variable "feature_communities" {
  description = "FEATURE_COMMUNITIES rollout mode for Communities (ADR-0031 D10; gates every CommunityService RPC, GetCommunityTimeline, CreatePost.community_id and the COMMUNITY entries of SetHomeTabs and GetMe.home_tabs): off | allowlist | percent | on. Default off; ramp deliberately, never ahead of lists."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_communities)
    error_message = "feature_communities must be one of: off, allowlist, percent, on."
  }
}

variable "feature_communities_allowlist" {
  description = "FEATURE_COMMUNITIES_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_communities_percent" {
  description = "FEATURE_COMMUNITIES_PERCENT: 0-100, only meaningful when feature_communities = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_communities_percent >= 0 && var.feature_communities_percent <= 100 && floor(var.feature_communities_percent) == var.feature_communities_percent
    error_message = "feature_communities_percent must be an integer 0-100."
  }
}

variable "feature_beacons" {
  description = "FEATURE_BEACONS rollout mode for Beacons/Plans (docs/beacons-plan.md; gates every BeaconService RPC): off | allowlist | percent | on. Default off in prod; the prod ceiling in scripts/promotion/flag-ceiling.json is off, so raising it needs a reviewed ceiling PR first. A community-audience plan still needs FEATURE_COMMUNITIES for the caller."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_beacons)
    error_message = "feature_beacons must be one of: off, allowlist, percent, on."
  }
}

variable "feature_beacons_allowlist" {
  description = "FEATURE_BEACONS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_beacons_percent" {
  description = "FEATURE_BEACONS_PERCENT: 0-100, only meaningful when feature_beacons = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_beacons_percent >= 0 && var.feature_beacons_percent <= 100 && floor(var.feature_beacons_percent) == var.feature_beacons_percent
    error_message = "feature_beacons_percent must be an integer 0-100."
  }
}

variable "community_creators" {
  description = "COMMUNITY_CREATORS: comma-separated Firebase uids allowed to call CreateCommunity (ADR-0031 D10, F1; not a secret). At most 10, each 1-128 characters of [A-Za-z0-9-]; the API refuses to start otherwise. Default empty: nobody can create a community."
  type        = string
  default     = ""

  validation {
    condition     = length(compact(split(",", var.community_creators))) <= 10
    error_message = "community_creators lists at most 10 uids."
  }
}

variable "feature_profile_extras" {
  description = "FEATURE_PROFILE_EXTRAS rollout mode for profile_extras (ADR-0024 D9; gates the UpdateProfile location, website and pin fields): off | allowlist | percent | on. Default off; ramp deliberately."
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
  description = "PROFILE_MEDIA_RETIRE (ADR-0024 Amendment 1 A4): which replaced or removed profile images the API deletes 24-48 h later. off = nothing (default) | all (avatars). The legacy value banner is still accepted and means off (the profile banner was removed; it never covered avatars). Per-project retention, not a cohort flag. Set all only after the media bucket's customTime lifecycle rule (modules/media-buckets) is applied in this project (a tagged object without the rule outlives its TTL'd media document and escapes the account eraser) and after the app release that shows a placeholder for an avatar that no longer loads."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "banner", "all"], var.profile_media_retire)
    error_message = "profile_media_retire must be one of: off, all, or the legacy banner (= off) (backend/pkg/platform/config/modes.go)."
  }
}

variable "media_orphan_sweep" {
  description = "MEDIA_ORPHAN_SWEEP: the media orphan sweep's kill switch. off = nothing (default) | mark = mark unattached READY images and restore held ones, never delete (soak) | delete = also delete marked images at least 12 h later. Per-project operations config, not a cohort flag. Raise to delete only after a mark-only soak in this project."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "mark", "delete"], var.media_orphan_sweep)
    error_message = "media_orphan_sweep must be one of: off, mark, delete (backend/pkg/platform/config/modes.go)."
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
  description = "FEATURE_SHELLS rollout mode for the W8 coming-soon pages (client-only; Creator tools, Premium, Advertise, Calls and their entries): off | allowlist | percent | on. Default off; ramp deliberately."
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

# ---- Scheduled posts. The sweep job lives in prod only; envs/dev has no Scheduler job.

variable "publish_scheduled_schedule" {
  description = "Cloud Scheduler cron (UTC) for the publish-scheduled sweep job (ADR-0021 D1). Only \"every N minutes\" is accepted, N = 1 to 10 (\"* * * * *\" or \"*/N * * * *\"): a cadence that never fires or leaves gaps above SCHEDULED_MAX_LATENESS (6 h) would silently strand or EXPIRE scheduled posts. Default every 5 minutes: 8,640 requests/month, inside the free tier. A shorter cadence costs Firestore reads (every minute is +1,152 reads/day) and needs the cost-model headroom check; ADR-0022 allows every minute only until 2026-12-22."
  type        = string
  default     = "*/5 * * * *"

  validation {
    condition     = can(regex("^(\\*|\\*/([1-9]|10)) \\* \\* \\* \\*$", var.publish_scheduled_schedule))
    error_message = "publish_scheduled_schedule must be \"* * * * *\" or \"*/N * * * *\" with N from 1 to 10, for example \"*/5 * * * *\"."
  }
}

# ---- credit mode (time-boxed, prod only). The defaults below are the Stage 0 values: CI plan (prod) runs
# with them and must show no change from this block. The credit values go only in the real, gitignored terraform.tfvars
# (see terraform.tfvars.example).

variable "min_instance_count" {
  description = "Cloud Run SERVICE-level minimum instances (ADR-0022). 0 = Stage 0. 1 = credit mode only, until 2026-12-22 (about INR 936/month idle, paid by the credit). The module refuses 1 after credit_mode_until in a local plan."
  type        = number
  default     = 0

  validation {
    condition     = var.min_instance_count == 0 || var.min_instance_count == 1
    error_message = "min_instance_count must be 0 or 1."
  }
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

variable "trends_min_authors" {
  description = "TRENDS_MIN_AUTHORS (ADR-0028 note 2026-10-31, W4-26): the fewest distinct established authors (ACTIVE, account at least TRENDS_MIN_ACCOUNT_AGE, 72 h, old) a hashtag needs to trend. Read at the daily sweep. Prod launch value 5 (security review W4-22 M-2; the founder confirms it in the prod plan)."
  type        = number
  default     = 5

  validation {
    condition     = var.trends_min_authors >= 1 && floor(var.trends_min_authors) == var.trends_min_authors
    error_message = "trends_min_authors must be an integer >= 1."
  }
}
variable "trends_denylist" {
  description = "TRENDS_DENYLIST (ADR-0028 note 2026-10-31, W4-25): comma-separated hashtag bodies (no leading #) that never trend. GetTrends drops them at serve time (live on the new revision within the 10 min instance copy) and the sweep drops them too. Entries are matched after NFKC, lower-casing and removing U+200C, U+200D and underscores, so one entry covers its variants. Not a secret. Default empty. To remove a tag at once without a deploy use `opsctl trends hide`.3)."
  type        = string
  default     = ""
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

variable "feature_crash_reporting" {
  description = "FEATURE_CRASH_REPORTING rollout mode for client crash reporting (client-only, ADR-0032 D11; gates the crash switch and Firebase Crashlytics collection in the Android app, no RPC): off | allowlist | percent | on. Default off."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_crash_reporting)
    error_message = "feature_crash_reporting must be one of: off, allowlist, percent, on."
  }
}

variable "feature_crash_reporting_allowlist" {
  description = "FEATURE_CRASH_REPORTING_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_crash_reporting_percent" {
  description = "FEATURE_CRASH_REPORTING_PERCENT: 0-100, only meaningful when feature_crash_reporting = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_crash_reporting_percent >= 0 && var.feature_crash_reporting_percent <= 100 && floor(var.feature_crash_reporting_percent) == var.feature_crash_reporting_percent
    error_message = "feature_crash_reporting_percent must be an integer 0-100."
  }
}

variable "feature_analytics" {
  description = "FEATURE_ANALYTICS rollout mode for client usage analytics (client-only, ADR-0032 D11; gates the usage switch and Google Analytics for Firebase collection in the Android app, no RPC): off | allowlist | percent | on. Default off."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_analytics)
    error_message = "feature_analytics must be one of: off, allowlist, percent, on."
  }
}

variable "feature_analytics_allowlist" {
  description = "FEATURE_ANALYTICS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_analytics_percent" {
  description = "FEATURE_ANALYTICS_PERCENT: 0-100, only meaningful when feature_analytics = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_analytics_percent >= 0 && var.feature_analytics_percent <= 100 && floor(var.feature_analytics_percent) == var.feature_analytics_percent
    error_message = "feature_analytics_percent must be an integer 0-100."
  }
}

variable "feature_community_member_search" {
  description = "FEATURE_COMMUNITY_MEMBER_SEARCH rollout mode for CommunityService SearchCommunityMembers (F36), checked after FEATURE_COMMUNITIES; never ramp ahead of it: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_community_member_search)
    error_message = "feature_community_member_search must be one of: off, allowlist, percent, on."
  }
}

variable "feature_community_member_search_allowlist" {
  description = "FEATURE_COMMUNITY_MEMBER_SEARCH_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_community_member_search_percent" {
  description = "FEATURE_COMMUNITY_MEMBER_SEARCH_PERCENT: 0-100, only meaningful when feature_community_member_search = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_community_member_search_percent >= 0 && var.feature_community_member_search_percent <= 100 && floor(var.feature_community_member_search_percent) == var.feature_community_member_search_percent
    error_message = "feature_community_member_search_percent must be an integer 0-100."
  }
}

variable "feature_post_beacon_embed" {
  description = "FEATURE_POST_BEACON_EMBED rollout mode for sharing a plan on a root post (CreatePostRequest.beacon_id; Post.beacon stripped while globally off); needs FEATURE_BEACONS on for the caller: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_post_beacon_embed)
    error_message = "feature_post_beacon_embed must be one of: off, allowlist, percent, on."
  }
}

variable "feature_post_beacon_embed_allowlist" {
  description = "FEATURE_POST_BEACON_EMBED_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_post_beacon_embed_percent" {
  description = "FEATURE_POST_BEACON_EMBED_PERCENT: 0-100, only meaningful when feature_post_beacon_embed = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_post_beacon_embed_percent >= 0 && var.feature_post_beacon_embed_percent <= 100 && floor(var.feature_post_beacon_embed_percent) == var.feature_post_beacon_embed_percent
    error_message = "feature_post_beacon_embed_percent must be an integer 0-100."
  }
}

variable "feature_chat_shared_plans" {
  description = "FEATURE_CHAT_SHARED_PLANS rollout mode for BeaconService.ListSharedBeacons, the 'plans you share' strip of a chat; needs FEATURE_BEACONS not globally off: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_chat_shared_plans)
    error_message = "feature_chat_shared_plans must be one of: off, allowlist, percent, on."
  }
}

variable "feature_chat_shared_plans_allowlist" {
  description = "FEATURE_CHAT_SHARED_PLANS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_chat_shared_plans_percent" {
  description = "FEATURE_CHAT_SHARED_PLANS_PERCENT: 0-100, only meaningful when feature_chat_shared_plans = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_chat_shared_plans_percent >= 0 && var.feature_chat_shared_plans_percent <= 100 && floor(var.feature_chat_shared_plans_percent) == var.feature_chat_shared_plans_percent
    error_message = "feature_chat_shared_plans_percent must be an integer 0-100."
  }
}

variable "feature_beacon_quick_join" {
  description = "FEATURE_BEACON_QUICK_JOIN rollout mode for the one-tap join of a beacon: RequestToJoin with an empty note only when the organiser follows the caller (else note_required), and GetBeacon's quick_join_allowed; needs FEATURE_BEACONS on for the caller: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_beacon_quick_join)
    error_message = "feature_beacon_quick_join must be one of: off, allowlist, percent, on."
  }
}

variable "feature_beacon_quick_join_allowlist" {
  description = "FEATURE_BEACON_QUICK_JOIN_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_beacon_quick_join_percent" {
  description = "FEATURE_BEACON_QUICK_JOIN_PERCENT: 0-100, only meaningful when feature_beacon_quick_join = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_beacon_quick_join_percent >= 0 && var.feature_beacon_quick_join_percent <= 100 && floor(var.feature_beacon_quick_join_percent) == var.feature_beacon_quick_join_percent
    error_message = "feature_beacon_quick_join_percent must be an integer 0-100."
  }
}

variable "feature_read_receipts" {
  description = "FEATURE_READ_RECEIPTS rollout mode for read receipts (F3): UpdateProfile.read_receipts=true, the MarkConversationRead receipt and ListMessages peer_read_at; needs messaging for any effect: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_read_receipts)
    error_message = "feature_read_receipts must be one of: off, allowlist, percent, on."
  }
}

variable "feature_read_receipts_allowlist" {
  description = "FEATURE_READ_RECEIPTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_read_receipts_percent" {
  description = "FEATURE_READ_RECEIPTS_PERCENT: 0-100, only meaningful when feature_read_receipts = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_read_receipts_percent >= 0 && var.feature_read_receipts_percent <= 100 && floor(var.feature_read_receipts_percent) == var.feature_read_receipts_percent
    error_message = "feature_read_receipts_percent must be an integer 0-100."
  }
}

variable "feature_dm_policy" {
  description = "FEATURE_DM_POLICY rollout mode for the 'Who can message me' setting (F9): UpdateProfile.dm_policy=FOLLOWING_ONLY and SendMessage applying it; needs messaging for any effect: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_dm_policy)
    error_message = "feature_dm_policy must be one of: off, allowlist, percent, on."
  }
}

variable "feature_dm_policy_allowlist" {
  description = "FEATURE_DM_POLICY_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_dm_policy_percent" {
  description = "FEATURE_DM_POLICY_PERCENT: 0-100, only meaningful when feature_dm_policy = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_dm_policy_percent >= 0 && var.feature_dm_policy_percent <= 100 && floor(var.feature_dm_policy_percent) == var.feature_dm_policy_percent
    error_message = "feature_dm_policy_percent must be an integer 0-100."
  }
}

variable "feature_notification_prefs" {
  description = "FEATURE_NOTIFICATION_PREFS rollout mode for GetNotificationPrefs/UpdateNotificationPrefs; needs notifications for any effect: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_notification_prefs)
    error_message = "feature_notification_prefs must be one of: off, allowlist, percent, on."
  }
}

variable "feature_notification_prefs_allowlist" {
  description = "FEATURE_NOTIFICATION_PREFS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_notification_prefs_percent" {
  description = "FEATURE_NOTIFICATION_PREFS_PERCENT: 0-100, only meaningful when feature_notification_prefs = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_notification_prefs_percent >= 0 && var.feature_notification_prefs_percent <= 100 && floor(var.feature_notification_prefs_percent) == var.feature_notification_prefs_percent
    error_message = "feature_notification_prefs_percent must be an integer 0-100."
  }
}

variable "feature_dm_post_share" {
  description = "FEATURE_DM_POST_SHARE rollout mode for sending a post in a direct message (SendMessageRequest.shared_post_id; every Message.shared_post card is unavailable while globally off); needs FEATURE_MESSAGING and FEATURE_POSTS on for the caller: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_dm_post_share)
    error_message = "feature_dm_post_share must be one of: off, allowlist, percent, on."
  }
}

variable "feature_dm_post_share_allowlist" {
  description = "FEATURE_DM_POST_SHARE_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_dm_post_share_percent" {
  description = "FEATURE_DM_POST_SHARE_PERCENT: 0-100, only meaningful when feature_dm_post_share = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_dm_post_share_percent >= 0 && var.feature_dm_post_share_percent <= 100 && floor(var.feature_dm_post_share_percent) == var.feature_dm_post_share_percent
    error_message = "feature_dm_post_share_percent must be an integer 0-100."
  }
}

variable "feature_share_count" {
  description = "FEATURE_SHARE_COUNT rollout mode for EngagementService.RecordPostShare (on for the caller) and the direct-message share record of Post.share_count (while not globally off); clients show the count only when it is on for the viewer: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_share_count)
    error_message = "feature_share_count must be one of: off, allowlist, percent, on."
  }
}

variable "feature_share_count_allowlist" {
  description = "FEATURE_SHARE_COUNT_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_share_count_percent" {
  description = "FEATURE_SHARE_COUNT_PERCENT: 0-100, only meaningful when feature_share_count = percent."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_share_count_percent >= 0 && var.feature_share_count_percent <= 100 && floor(var.feature_share_count_percent) == var.feature_share_count_percent
    error_message = "feature_share_count_percent must be an integer 0-100."
  }
}

variable "feature_handle_suggestions" {
  description = "FEATURE_HANDLE_SUGGESTIONS rollout mode for free handle suggestions when a chosen handle is taken: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_handle_suggestions)
    error_message = "feature_handle_suggestions must be one of: off, allowlist, percent, on."
  }
}

variable "feature_handle_suggestions_allowlist" {
  description = "FEATURE_HANDLE_SUGGESTIONS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_handle_suggestions_percent" {
  description = "FEATURE_HANDLE_SUGGESTIONS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_handle_suggestions_percent >= 0 && var.feature_handle_suggestions_percent <= 100 && floor(var.feature_handle_suggestions_percent) == var.feature_handle_suggestions_percent
    error_message = "feature_handle_suggestions_percent must be an integer 0-100."
  }
}

variable "feature_list_follows" {
  description = "FEATURE_LIST_FOLLOWS rollout mode for following a public List, its follower count and Discover lists: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_list_follows)
    error_message = "feature_list_follows must be one of: off, allowlist, percent, on."
  }
}

variable "feature_list_follows_allowlist" {
  description = "FEATURE_LIST_FOLLOWS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_list_follows_percent" {
  description = "FEATURE_LIST_FOLLOWS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_list_follows_percent >= 0 && var.feature_list_follows_percent <= 100 && floor(var.feature_list_follows_percent) == var.feature_list_follows_percent
    error_message = "feature_list_follows_percent must be an integer 0-100."
  }
}

variable "feature_list_suggestions" {
  description = "FEATURE_LIST_SUGGESTIONS rollout mode for suggested members on a List the caller owns: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_list_suggestions)
    error_message = "feature_list_suggestions must be one of: off, allowlist, percent, on."
  }
}

variable "feature_list_suggestions_allowlist" {
  description = "FEATURE_LIST_SUGGESTIONS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_list_suggestions_percent" {
  description = "FEATURE_LIST_SUGGESTIONS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_list_suggestions_percent >= 0 && var.feature_list_suggestions_percent <= 100 && floor(var.feature_list_suggestions_percent) == var.feature_list_suggestions_percent
    error_message = "feature_list_suggestions_percent must be an integer 0-100."
  }
}

variable "feature_bookmark_history" {
  description = "FEATURE_BOOKMARK_HISTORY rollout mode for the Bookmarks History tab (recently opened posts): off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_bookmark_history)
    error_message = "feature_bookmark_history must be one of: off, allowlist, percent, on."
  }
}

variable "feature_bookmark_history_allowlist" {
  description = "FEATURE_BOOKMARK_HISTORY_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_bookmark_history_percent" {
  description = "FEATURE_BOOKMARK_HISTORY_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_bookmark_history_percent >= 0 && var.feature_bookmark_history_percent <= 100 && floor(var.feature_bookmark_history_percent) == var.feature_bookmark_history_percent
    error_message = "feature_bookmark_history_percent must be an integer 0-100."
  }
}

variable "feature_article_images" {
  description = "FEATURE_ARTICLE_IMAGES rollout mode for image blocks inside articles: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_article_images)
    error_message = "feature_article_images must be one of: off, allowlist, percent, on."
  }
}

variable "feature_article_images_allowlist" {
  description = "FEATURE_ARTICLE_IMAGES_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_article_images_percent" {
  description = "FEATURE_ARTICLE_IMAGES_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_article_images_percent >= 0 && var.feature_article_images_percent <= 100 && floor(var.feature_article_images_percent) == var.feature_article_images_percent
    error_message = "feature_article_images_percent must be an integer 0-100."
  }
}

variable "feature_export_zip" {
  description = "FEATURE_EXPORT_ZIP rollout mode for data export delivered as one ZIP archive: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_export_zip)
    error_message = "feature_export_zip must be one of: off, allowlist, percent, on."
  }
}

variable "feature_export_zip_allowlist" {
  description = "FEATURE_EXPORT_ZIP_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_export_zip_percent" {
  description = "FEATURE_EXPORT_ZIP_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_export_zip_percent >= 0 && var.feature_export_zip_percent <= 100 && floor(var.feature_export_zip_percent) == var.feature_export_zip_percent
    error_message = "feature_export_zip_percent must be an integer 0-100."
  }
}

variable "feature_message_search" {
  description = "FEATURE_MESSAGE_SEARCH rollout mode for searching the caller's own direct messages: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_message_search)
    error_message = "feature_message_search must be one of: off, allowlist, percent, on."
  }
}

variable "feature_message_search_allowlist" {
  description = "FEATURE_MESSAGE_SEARCH_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_message_search_percent" {
  description = "FEATURE_MESSAGE_SEARCH_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_message_search_percent >= 0 && var.feature_message_search_percent <= 100 && floor(var.feature_message_search_percent) == var.feature_message_search_percent
    error_message = "feature_message_search_percent must be an integer 0-100."
  }
}

variable "feature_search_lists" {
  description = "FEATURE_SEARCH_LISTS rollout mode for searching public lists and communities by name: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_search_lists)
    error_message = "feature_search_lists must be one of: off, allowlist, percent, on."
  }
}

variable "feature_search_lists_allowlist" {
  description = "FEATURE_SEARCH_LISTS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_search_lists_percent" {
  description = "FEATURE_SEARCH_LISTS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_search_lists_percent >= 0 && var.feature_search_lists_percent <= 100 && floor(var.feature_search_lists_percent) == var.feature_search_lists_percent
    error_message = "feature_search_lists_percent must be an integer 0-100."
  }
}

variable "feature_search_filters" {
  description = "FEATURE_SEARCH_FILTERS rollout mode for the search \"People you follow\" filter on SearchPosts: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_search_filters)
    error_message = "feature_search_filters must be one of: off, allowlist, percent, on."
  }
}

variable "feature_search_filters_allowlist" {
  description = "FEATURE_SEARCH_FILTERS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_search_filters_percent" {
  description = "FEATURE_SEARCH_FILTERS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_search_filters_percent >= 0 && var.feature_search_filters_percent <= 100 && floor(var.feature_search_filters_percent) == var.feature_search_filters_percent
    error_message = "feature_search_filters_percent must be an integer 0-100."
  }
}

variable "feature_dm_suggestions" {
  description = "FEATURE_DM_SUGGESTIONS rollout mode for message recipient suggestions on the new-message screen: off | allowlist | percent | on. Default off in every environment; ramp deliberately."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_dm_suggestions)
    error_message = "feature_dm_suggestions must be one of: off, allowlist, percent, on."
  }
}

variable "feature_dm_suggestions_allowlist" {
  description = "FEATURE_DM_SUGGESTIONS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_dm_suggestions_percent" {
  description = "FEATURE_DM_SUGGESTIONS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_dm_suggestions_percent >= 0 && var.feature_dm_suggestions_percent <= 100 && floor(var.feature_dm_suggestions_percent) == var.feature_dm_suggestions_percent
    error_message = "feature_dm_suggestions_percent must be an integer 0-100."
  }
}

variable "feature_post_views" {
  description = "FEATURE_POST_VIEWS rollout mode for F1 post view counts (EngagementService.RecordImpressions on for the caller; Post.view_count on every read while not globally off): off | allowlist | percent | on. Default off in every environment. Ceiling in scripts/promotion/flag-ceiling.json: dev allowlist of at most 6, prod off. Ramp ahead of FEATURE_CREATOR_INSIGHTS."
  type        = string
  default     = "off"

  validation {
    condition     = contains(["off", "allowlist", "percent", "on"], var.feature_post_views)
    error_message = "feature_post_views must be one of: off, allowlist, percent, on."
  }
}

variable "feature_post_views_allowlist" {
  description = "FEATURE_POST_VIEWS_ALLOWLIST: comma-separated Firebase uids (not a secret). Applies in allowlist and percent modes."
  type        = string
  default     = ""
}

variable "feature_post_views_percent" {
  description = "FEATURE_POST_VIEWS_PERCENT: integer 0-100, the share of users enabled in percent mode."
  type        = number
  default     = 0

  validation {
    condition     = var.feature_post_views_percent >= 0 && var.feature_post_views_percent <= 100 && floor(var.feature_post_views_percent) == var.feature_post_views_percent
    error_message = "feature_post_views_percent must be an integer 0-100."
  }
}
