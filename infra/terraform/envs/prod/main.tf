locals {
  env          = "prod"
  service_name = "api"
  labels = {
    env         = "prod"
    cost-center = "stage0"
  }

  # Deterministic Cloud Run v2 URL, computed from the project number instead
  # of read from `module.cloud_run_api.url` — that output only exists after
  # the service is created, and this same value has to be fed back INTO the
  # cloud_run_api module as INTERNAL_OIDC_AUDIENCE, which would otherwise be
  # a dependency cycle (a module's input can't depend on its own output).
  # Also used as the pubsub/scheduler OIDC audience so all three agree
  # byte-for-byte without any module depending on cloud_run_api's output.
  api_url = "https://${local.service_name}-${data.google_project.this.number}.${var.region}.run.app"
}

data "google_project" "this" {
  project_id = var.project_id
}

module "project_services" {
  source     = "../../modules/project-services"
  project_id = var.project_id
}

// Cloud Vision consumer-quota caps (security review of PR #449, M-A): a stolen CI plan token must not be able to bill
// the Vision API at the 1,800 requests/minute default. Sized from the app's peak; no fixed cost. See the module header.
module "vision_quota" {
  source     = "../../modules/vision-quota"
  project_id = var.project_id

  depends_on = [module.project_services]
}

module "iam" {
  source          = "../../modules/iam"
  project_id      = var.project_id
  billing_account = var.billing_account
  env             = local.env
  github_repo     = var.github_repo

  # ci_deploy_can_move_ar_tags is intentionally left at its default (false): prod's ci-deploy does not move AR tags (promote-prod only
  # reads them, release-prod only creates new ones) and must not be able to delete the v* release tags.

  # prod deploys ONLY from version tags — see release-rollout skill
  # (tag v* -> --no-traffic --tag candidate -> smoke -> VERDICT: GO -> founder dispatches promote-prod 10% then 100%).
  deploy_ref_condition   = "assertion.ref.startsWith('refs/tags/v')"
  deploy_ref_description = "version tags only (refs/tags/v*)"

  # M6: pin the deploy WIF token to the exact release/promote workflow files (a
  # modified/forked copy on some other ref can't mint a usable token even if
  # it satisfies repository+ref) and to the `prod` GitHub Environment both
  # workflows declare on every job that needs GCP credentials.
  #
  # Free-plan trust model (GitHub Free, private repo, single collaborator):
  # there are no required reviewers and no tag rulesets available, so the
  # `prod` Environment's deployment policy (tags matching `v*` only) plus
  # this WIF pin are the whole machine-enforced boundary — the human gate is
  # the founder running promote-prod.yml deliberately, plus the
  # production-reviewer `VERDICT: GO` file check inside that workflow. See
  # docs/runbooks/cloud-bootstrap.md §6/6a; revisit with GitHub Pro/Team
  # (required reviewers, tag rulesets) via an ADR if collaborators are added.
  deploy_extra_conditions = [
    "assertion.job_workflow_ref.startsWith('${var.github_repo}/.github/workflows/release-prod.yml@refs/tags/v') || assertion.job_workflow_ref.startsWith('${var.github_repo}/.github/workflows/promote-prod.yml@refs/tags/v')",
    "assertion.environment == 'prod'",
  ]

  depends_on = [module.project_services]
}

module "artifact_registry" {
  source        = "../../modules/artifact-registry"
  project_id    = var.project_id
  region        = var.region
  repository_id = "api"
  env           = local.env
  labels        = merge(local.labels, { module = "artifact-registry" })

  depends_on = [module.project_services]
}

module "firestore" {
  source     = "../../modules/firestore"
  project_id = var.project_id
  location   = var.firestore_location # PERMANENT — see variables.tf warning; confirm before apply

  weekly_backup_enabled = true # ADR-0007: weekly, 14-day retention (founder-approved 2026-09-27)

  depends_on = [module.project_services]
}

module "media_buckets" {
  source                        = "../../modules/media-buckets"
  project_id                    = var.project_id
  region                        = var.media_bucket_region
  runtime_service_account_email = module.iam.runtime_service_account_email
  cors_origins                  = var.cors_origins
  labels                        = merge(local.labels, { module = "media-buckets" })

  depends_on = [module.project_services]
}

module "secrets" {
  source                        = "../../modules/secrets"
  project_id                    = var.project_id
  runtime_service_account_email = module.iam.runtime_service_account_email
  secret_ids                    = []
  # cursor-hmac-key: pure random HMAC signing material (ADR-0003 cursors) —
  # Terraform generates and seeds it; nothing to set manually. Prod gets its
  # own independent secret/value from dev's (separate module instance).
  generated_secret_ids = ["cursor-hmac-key"]
  labels               = merge(local.labels, { module = "secrets" })

  depends_on = [module.project_services]
}

// Graph slice (T23, ADR-0008 D6/D7). Names and defaults mirror backend/pkg/platform/config/config.go and
// backend/pkg/platform/flags; caps are code, so a change here needs a cost note in the PR.
// FEATURE_GRAPH: off | allowlist | percent | on. The rollout (allowlist -> percent -> on) is driven by
// changing var.feature_graph* here, not by ad-hoc `gcloud run services update`, so state never drifts.
locals {
  graph_env_vars = [
    { name = "FEATURE_GRAPH", value = var.feature_graph },
    { name = "FEATURE_GRAPH_ALLOWLIST", value = var.feature_graph_allowlist },
    { name = "FEATURE_GRAPH_PERCENT", value = tostring(var.feature_graph_percent) },
    { name = "QUOTA_BLOCKS_PER_DAY", value = "200" },
    { name = "QUOTA_NEW_ACCOUNT_BLOCKS_PER_DAY", value = "50" },
    { name = "LIST_CALLS_PER_DAY", value = "100" },
    { name = "GRAPH_MUTATIONS_PER_DAY", value = "500" },
    # ADR-0010 D5 read budget (rule 11: caps are config). Must match the config.go defaults.
    { name = "READ_BUDGET_PER_UID_PER_DAY", value = "2000" },
    { name = "READ_BUDGET_PER_IP_NO_PROFILE_PER_DAY", value = "500" },
    { name = "CHECK_HANDLE_CALLS_PER_DAY", value = "100" },
    { name = "ACCOUNT_OPS_CALLS_PER_DAY", value = "20" },
    { name = "RATE_LIMIT_GRAPH_FOLLOW_PER_MIN", value = "30" },
    { name = "RATE_LIMIT_GRAPH_BLOCK_PER_MIN", value = "20" },
    { name = "RATE_LIMIT_GRAPH_LIST_PER_MIN", value = "20" },
    { name = "RATE_LIMIT_CHECK_HANDLE_PER_MIN", value = "20" },
  ]
}

// Posts + timeline slice (T26, ADR-0010 Handoff). Names and defaults mirror backend/pkg/platform/config/config.go;
// caps are code, so a change here needs a cost note in the PR. FEATURE_POSTS is set explicitly in both envs so the
// environment does not depend on the code default (on in dev/local, off in prod). The rollout (off -> allowlist ->
// percent -> on) is driven by var.feature_posts*, not by ad-hoc `gcloud run services update`.
locals {
  posts_env_vars = [
    { name = "FEATURE_POSTS", value = var.feature_posts },
    { name = "FEATURE_POSTS_ALLOWLIST", value = var.feature_posts_allowlist },
    { name = "FEATURE_POSTS_PERCENT", value = tostring(var.feature_posts_percent) },
    { name = "TIMELINE_SETTLE_WINDOW", value = "15s" }, # validated >= 15s at startup (3 x the 5 s CreatePost deadline)
    { name = "TIMELINE_TOKEN_TTL", value = "720h" },
    { name = "CACHE_POSTS_ENTRIES", value = "20000" },
    { name = "CACHE_AUTHOR_RECENT_ENTRIES", value = "1000" },
    { name = "RATE_LIMIT_TIMELINE_PER_MIN", value = "6" },
    { name = "RATE_LIMIT_USER_TIMELINE_PER_MIN", value = "30" },
    { name = "RATE_LIMIT_POST_CREATE_PER_MIN", value = "10" },
    { name = "RATE_LIMIT_POST_DELETE_PER_MIN", value = "20" },
    { name = "QUOTA_POSTS_PER_DAY", value = "100" },
    { name = "QUOTA_NEW_ACCOUNT_POSTS_PER_DAY", value = "20" },
  ]
}

// Account lifecycle slice (P8, ADR-0011). Names and defaults mirror backend/pkg/platform/config/config.go; caps are
// code, so a change here needs a cost note in the PR. FEATURE_ACCOUNT_LIFECYCLE is set explicitly in both envs
// (dev on, prod off) and rolled out via var.feature_account_lifecycle*. EXPORT_RETENTION must equal the exports
// bucket lifecycle age (7 days) in modules/media-buckets.
locals {
  account_lifecycle_env_vars = [
    { name = "FEATURE_ACCOUNT_LIFECYCLE", value = var.feature_account_lifecycle },
    { name = "FEATURE_ACCOUNT_LIFECYCLE_ALLOWLIST", value = var.feature_account_lifecycle_allowlist },
    { name = "FEATURE_ACCOUNT_LIFECYCLE_PERCENT", value = tostring(var.feature_account_lifecycle_percent) },
    { name = "EXPORT_BUCKET", value = module.media_buckets.exports_bucket_name },
    { name = "EXPORT_URL_TTL", value = "15m" },
    { name = "EXPORT_RETENTION", value = "168h" },
    { name = "ACCOUNT_DELETE_REAUTH_MAX_AGE", value = "5m" },
    { name = "JOBS_TOPIC", value = "jobs" },
  ]
}

// Reports and moderation (P7, ADR-0016). FEATURE_REPORTS is off in both envs until the founder ramps it
// (var.feature_reports*); no code path or apply turns it on. Quotas mirror backend/pkg/platform/config/config.go.
locals {
  reports_env_vars = [
    { name = "FEATURE_REPORTS", value = var.feature_reports },
    { name = "FEATURE_REPORTS_ALLOWLIST", value = var.feature_reports_allowlist },
    { name = "FEATURE_REPORTS_PERCENT", value = tostring(var.feature_reports_percent) },
    // ADR-0016 D10: the moderation removal log read on since_token refreshes. Off = no log reads and no feed reset.
    { name = "FEATURE_REMOVED_IDS", value = var.feature_removed_ids },
    { name = "FEATURE_REMOVED_IDS_ALLOWLIST", value = var.feature_removed_ids_allowlist },
    { name = "FEATURE_REMOVED_IDS_PERCENT", value = tostring(var.feature_removed_ids_percent) },
    // ADR-0028 D8 (W4-3): search and trends. Default off; dev ceiling allowlist 6, no prod raise.
    { name = "FEATURE_SEARCH", value = var.feature_search },
    { name = "FEATURE_SEARCH_ALLOWLIST", value = var.feature_search_allowlist },
    { name = "FEATURE_SEARCH_PERCENT", value = tostring(var.feature_search_percent) },
    { name = "FEATURE_TRENDS", value = var.feature_trends },
    { name = "FEATURE_TRENDS_ALLOWLIST", value = var.feature_trends_allowlist },
    { name = "FEATURE_TRENDS_PERCENT", value = tostring(var.feature_trends_percent) },
    // ADR-0029 D12 (W6-4): polls, drafts (client only) and GIF. Default off; dev ceiling allowlist 6, no prod raise.
    { name = "FEATURE_POLLS", value = var.feature_polls },
    { name = "FEATURE_POLLS_ALLOWLIST", value = var.feature_polls_allowlist },
    { name = "FEATURE_POLLS_PERCENT", value = tostring(var.feature_polls_percent) },
    { name = "FEATURE_DRAFTS", value = var.feature_drafts },
    { name = "FEATURE_DRAFTS_ALLOWLIST", value = var.feature_drafts_allowlist },
    { name = "FEATURE_DRAFTS_PERCENT", value = tostring(var.feature_drafts_percent) },
    { name = "FEATURE_GIF", value = var.feature_gif },
    { name = "FEATURE_GIF_ALLOWLIST", value = var.feature_gif_allowlist },
    { name = "FEATURE_GIF_PERCENT", value = tostring(var.feature_gif_percent) },
    { name = "QUOTA_REPORTS_PER_DAY", value = "20" },
    { name = "QUOTA_NEW_ACCOUNT_REPORTS_PER_DAY", value = "5" },
  ]
}

// Notifications slice (P6, ADR-0017). FEATURE_NOTIFICATIONS is off in every environment until the founder rolls it
// out via var.feature_notifications*. No new resource: the topic, push subscription and DLQ already exist in
// modules/pubsub and the runtime SA's publish binding is in runtime_publisher_topics. The device-call cap mirrors
// config.go (NOTIFICATION_DEVICES_CALLS_PER_DAY, default 10); caps are code, so a change needs a cost note.
locals {
  notifications_env_vars = [
    { name = "FEATURE_NOTIFICATIONS", value = var.feature_notifications },
    { name = "FEATURE_NOTIFICATIONS_ALLOWLIST", value = var.feature_notifications_allowlist },
    { name = "FEATURE_NOTIFICATIONS_PERCENT", value = tostring(var.feature_notifications_percent) },
    { name = "NOTIFICATIONS_TOPIC", value = "notifications-fanout" },
    { name = "NOTIFICATIONS_DELIVERY", value = "pubsub" },
    { name = "NOTIFICATION_DEVICES_CALLS_PER_DAY", value = "10" },
    { name = "NOTIFICATION_SEEN_CALLS_PER_DAY", value = "200" },
  ]
}

// Media, engagement, replies and profile snapshot (P3/P4/P5, ADR-0005). All four flags are off in every
// environment until the founder ramps them via var.feature_*; nothing here turns one on. The non-flag values below
// are the config.go defaults written out so they are reviewed as code (caps are code); changing one needs a cost note.
// VISION_MONTHLY_CAP is the runaway-bill guard (ADR-0005); it and VISION_EXHAUSTED_POLICY are variables since ADR-0022
// (credit mode: 20000 and reject until 2026-12-22; the committed defaults are the Stage 0 values). vision.googleapis.com is already enabled in
// modules/project-services.
locals {
  media_engagement_env_vars = [
    { name = "FEATURE_MEDIA", value = var.feature_media },
    { name = "FEATURE_MEDIA_ALLOWLIST", value = var.feature_media_allowlist },
    { name = "FEATURE_MEDIA_PERCENT", value = tostring(var.feature_media_percent) },
    { name = "VISION_MONTHLY_CAP", value = tostring(var.vision_monthly_cap) }, # ADR-0022 until:2026-12-22 (default 10000 = Stage 0)
    { name = "VISION_EXHAUSTED_POLICY", value = var.vision_exhausted_policy }, # ADR-0022 until:2026-12-22 (default unscreened_established = Stage 0)
    { name = "VISION_SCREEN_THUMB", value = "true" },
    { name = "MEDIA_PUBLIC_BASE_URL", value = "https://storage.googleapis.com/${module.media_buckets.media_bucket_name}" },
    { name = "QUOTA_MEDIA_PER_DAY", value = "20" },
    { name = "QUOTA_NEW_ACCOUNT_MEDIA_PER_DAY", value = "5" },
    { name = "FEATURE_ENGAGEMENT", value = var.feature_engagement },
    { name = "FEATURE_ENGAGEMENT_ALLOWLIST", value = var.feature_engagement_allowlist },
    { name = "FEATURE_ENGAGEMENT_PERCENT", value = tostring(var.feature_engagement_percent) },
    { name = "QUOTA_LIKES_PER_DAY", value = "500" },
    { name = "QUOTA_NEW_ACCOUNT_LIKES_PER_DAY", value = "100" },
    { name = "FEATURE_QUOTES", value = var.feature_quotes },
    { name = "FEATURE_QUOTES_ALLOWLIST", value = var.feature_quotes_allowlist },
    { name = "FEATURE_QUOTES_PERCENT", value = tostring(var.feature_quotes_percent) },
    { name = "FEATURE_BOOKMARKS", value = var.feature_bookmarks },
    { name = "FEATURE_BOOKMARKS_ALLOWLIST", value = var.feature_bookmarks_allowlist },
    { name = "FEATURE_BOOKMARKS_PERCENT", value = tostring(var.feature_bookmarks_percent) },
    { name = "FEATURE_MESSAGING", value = var.feature_messaging },
    { name = "FEATURE_MESSAGING_ALLOWLIST", value = var.feature_messaging_allowlist },
    { name = "FEATURE_MESSAGING_PERCENT", value = tostring(var.feature_messaging_percent) },
    # W7-24: the messaging limits as explicit config (rule 11), each equal to its backend/pkg/platform/config default, as in envs/dev. Inert
    # while FEATURE_MESSAGING is off (prod's flag stays off; nothing here is applied until the held prod apply, credit runbook dated step 1.2).
    { name = "RATE_LIMIT_MESSAGES_SEND_PER_MIN", value = "20" },
    { name = "RATE_LIMIT_MESSAGES_READ_PER_MIN", value = "30" },
    { name = "MESSAGES_SENDS_PER_DAY", value = "300" },
    { name = "MESSAGES_NEW_ACCOUNT_SENDS_PER_DAY", value = "50" },
    # W7-29 (security review W7-22 M-1): MarkConversationRead's own daily cap (limit_name messages_mark_read_daily) and one cap shared by
    # AcceptMessageRequest + DeleteConversation (limit_name messages_mutation_daily). Must match the config.go defaults (500 and 500).
    { name = "MESSAGES_MARK_READ_PER_DAY", value = "500" },
    { name = "MESSAGES_MUTATIONS_PER_DAY", value = "500" },
    { name = "QUOTA_DM_NEW_CONVERSATIONS_PER_DAY", value = "20" },
    { name = "QUOTA_NEW_ACCOUNT_DM_NEW_CONVERSATIONS_PER_DAY", value = "5" },
    { name = "MESSAGES_REQUEST_MAX_UNANSWERED", value = "3" },
    { name = "MESSAGES_PUSHES_PER_RECIPIENT_PER_HOUR", value = "20" },
    { name = "CACHE_MESSAGING_CONVERSATION_ENTRIES", value = "5000" },
    { name = "QUOTA_BOOKMARKS_PER_DAY", value = "200" },
    { name = "QUOTA_NEW_ACCOUNT_BOOKMARKS_PER_DAY", value = "50" },
    { name = "BOOKMARKS_MAX_PER_USER", value = "1000" },
    { name = "RATE_LIMIT_BOOKMARKS_PER_MIN", value = "30" },
    { name = "RATE_LIMIT_BOOKMARKS_LIST_PER_MIN", value = "10" },
    # W2-14 M-1: shared AddBookmark + RemoveBookmark daily call cap (limit_name bookmark_mutation_daily). Must match the config.go default.
    { name = "BOOKMARK_MUTATIONS_PER_DAY", value = "1500" },
    { name = "FEATURE_PROFILE_EXTRAS", value = var.feature_profile_extras },
    { name = "FEATURE_PROFILE_EXTRAS_ALLOWLIST", value = var.feature_profile_extras_allowlist },
    { name = "FEATURE_PROFILE_EXTRAS_PERCENT", value = tostring(var.feature_profile_extras_percent) },
    { name = "FEATURE_PROFILE_TABS", value = var.feature_profile_tabs },
    { name = "FEATURE_PROFILE_TABS_ALLOWLIST", value = var.feature_profile_tabs_allowlist },
    { name = "FEATURE_PROFILE_TABS_PERCENT", value = tostring(var.feature_profile_tabs_percent) },
    { name = "FEATURE_LIKES_LIST", value = var.feature_likes_list },
    { name = "FEATURE_LIKES_LIST_ALLOWLIST", value = var.feature_likes_list_allowlist },
    { name = "FEATURE_LIKES_LIST_PERCENT", value = tostring(var.feature_likes_list_percent) },
    { name = "FEATURE_FOLLOW_SUGGESTIONS", value = var.feature_follow_suggestions },
    { name = "FEATURE_FOLLOW_SUGGESTIONS_ALLOWLIST", value = var.feature_follow_suggestions_allowlist },
    { name = "FEATURE_FOLLOW_SUGGESTIONS_PERCENT", value = tostring(var.feature_follow_suggestions_percent) },
    { name = "FEATURE_PRIVATE_ACCOUNTS", value = var.feature_private_accounts },
    { name = "FEATURE_PRIVATE_ACCOUNTS_ALLOWLIST", value = var.feature_private_accounts_allowlist },
    { name = "FEATURE_PRIVATE_ACCOUNTS_PERCENT", value = tostring(var.feature_private_accounts_percent) },
    # W3-25b (ADR-0025 D2, D3, D8, D13): private-accounts limits. Must match the config.go defaults; config.Load rejects a toggle quota <= 0,
    # a protected-set cap outside 1..20000 and a stale window outside 1s..1h.
    { name = "QUOTA_PRIVACY_TOGGLES_PER_DAY", value = "4" },
    { name = "PROTECTED_AUTHORS_MAX", value = "20000" },
    { name = "PROTECTED_SET_MAX_STALE", value = "10m" },
    { name = "RATE_LIMIT_FOLLOW_REQUESTS_RESPOND_PER_MIN", value = "60" },
    # W3-4 (ADR-0024 D8, D10): per-instance rate limits (effective x max-instances), the suggestions daily call cap and read caps, and the
    # curated fallback list. Must match the config.go defaults; config.Load rejects edge > 50, hydrate > 50, sample > 30 and max results > 5.
    { name = "RATE_LIMIT_SUGGESTIONS_PER_MIN", value = "10" },
    { name = "RATE_LIMIT_LIKES_LIST_PER_MIN", value = "10" },
    { name = "RATE_LIMIT_PROFILE_RELATIONSHIP_PER_MIN", value = "60" },
    { name = "SUGGESTIONS_CALLS_PER_DAY", value = "50" },
    # W3-22 L-4: UpdateProfile daily call cap (limit_name profile_update_daily). Must match the config.go default; config.Load rejects a value <= 0.
    { name = "PROFILE_UPDATES_PER_DAY", value = "100" },
    # ADR-0024 Amendment 1 A4: delete replaced or removed profile images 24-48 h after the change. Per-project retention, default off: raise it to banner only after the media bucket's customTime lifecycle rule is applied here, to all only after the avatar placeholder app release. Must match config.Load's accepted values.
    { name = "PROFILE_MEDIA_RETIRE", value = var.profile_media_retire },
    { name = "SUGGESTIONS_SAMPLE_FOLLOWEES", value = "30" },
    { name = "SUGGESTIONS_EDGE_LIMIT", value = "20" },
    { name = "SUGGESTIONS_HYDRATE_MAX", value = "10" },
    { name = "SUGGESTIONS_MAX_RESULTS", value = "5" },
    { name = "SUGGESTIONS_CACHE_TTL", value = "1h" },
    { name = "SUGGESTED_USER_IDS", value = var.suggested_user_ids },
    { name = "FEATURE_UI_SHELL", value = var.feature_ui_shell },
    { name = "FEATURE_UI_SHELL_ALLOWLIST", value = var.feature_ui_shell_allowlist },
    { name = "FEATURE_UI_SHELL_PERCENT", value = tostring(var.feature_ui_shell_percent) },
    { name = "FEATURE_SHELLS", value = var.feature_shells },
    { name = "FEATURE_SHELLS_ALLOWLIST", value = var.feature_shells_allowlist },
    { name = "FEATURE_SHELLS_PERCENT", value = tostring(var.feature_shells_percent) },
    { name = "FEATURE_CONTENT_DISCLOSURE", value = var.feature_content_disclosure },
    { name = "FEATURE_CONTENT_DISCLOSURE_ALLOWLIST", value = var.feature_content_disclosure_allowlist },
    { name = "FEATURE_CONTENT_DISCLOSURE_PERCENT", value = tostring(var.feature_content_disclosure_percent) },
    { name = "FEATURE_REPLY_AUDIENCE", value = var.feature_reply_audience },
    { name = "FEATURE_REPLY_AUDIENCE_ALLOWLIST", value = var.feature_reply_audience_allowlist },
    { name = "FEATURE_REPLY_AUDIENCE_PERCENT", value = tostring(var.feature_reply_audience_percent) },
    { name = "FEATURE_SCHEDULED_POSTS", value = var.feature_scheduled_posts },
    { name = "FEATURE_SCHEDULED_POSTS_ALLOWLIST", value = var.feature_scheduled_posts_allowlist },
    { name = "FEATURE_SCHEDULED_POSTS_PERCENT", value = tostring(var.feature_scheduled_posts_percent) },
    { name = "FEATURE_REPLIES", value = var.feature_replies },
    { name = "FEATURE_REPLIES_ALLOWLIST", value = var.feature_replies_allowlist },
    { name = "FEATURE_REPLIES_PERCENT", value = tostring(var.feature_replies_percent) },
    { name = "FEATURE_PROFILE_SNAPSHOT", value = var.feature_profile_snapshot },
    { name = "FEATURE_PROFILE_SNAPSHOT_ALLOWLIST", value = var.feature_profile_snapshot_allowlist },
    { name = "FEATURE_PROFILE_SNAPSHOT_PERCENT", value = tostring(var.feature_profile_snapshot_percent) },
    { name = "QUOTA_SNAPSHOT_EDITS_PER_DAY", value = "5" },
  ]
}

module "cloud_run_api" {
  source                            = "../../modules/cloud-run-api"
  project_id                        = var.project_id
  env                               = local.env
  region                            = var.region
  service_name                      = local.service_name
  runtime_service_account_email     = module.iam.runtime_service_account_email
  pubsub_push_service_account_email = module.iam.pubsub_push_service_account_email
  image                             = var.image
  degraded_mode                     = "off"
  app_check_mode                    = "monitor" # ADR-0006: monitor in both envs for now
  internal_oidc_audience            = local.api_url
  internal_oidc_allowed_emails      = [module.iam.pubsub_push_service_account_email]
  labels                            = merge(local.labels, { module = "cloud-run-api" })

  # ADR-0022: SERVICE-level minimum instances (never revision-level). Default 0 = Stage 0; the real tfvars sets 1 in credit mode.
  min_instance_count = var.min_instance_count # cost-approved: ADR-0022 until:2026-12-22

  secret_env_vars = [
    { name = "CURSOR_HMAC_KEY", secret = module.secrets.generated_secret_ids["cursor-hmac-key"] },
  ]

  extra_env_vars = concat([
    { name = "MEDIA_UPLOAD_BUCKET", value = module.media_buckets.upload_bucket_name },
    { name = "MEDIA_BUCKET", value = module.media_buckets.media_bucket_name },
    ],
    local.graph_env_vars,
    local.posts_env_vars,
    local.account_lifecycle_env_vars,
    local.notifications_env_vars,
    local.reports_env_vars,
    local.media_engagement_env_vars,
  )

  depends_on = [module.project_services, module.secrets]
}

// Google creates the Pub/Sub service agent lazily; force it into existence before granting it roles
// (DLQ publisher), otherwise the first apply fails with "service account does not exist".
resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"

  depends_on = [module.project_services]
}

module "pubsub" {
  source                            = "../../modules/pubsub"
  project_id                        = var.project_id
  push_base_url                     = local.api_url
  runtime_service_account_email     = module.iam.runtime_service_account_email
  pubsub_push_service_account_email = module.iam.pubsub_push_service_account_email
  pubsub_service_agent_email        = google_project_service_identity.pubsub.email
  labels                            = merge(local.labels, { module = "pubsub" })

  depends_on = [module.project_services, module.cloud_run_api]
}

module "scheduler" {
  source                            = "../../modules/scheduler"
  project_id                        = var.project_id
  region                            = var.region
  push_base_url                     = local.api_url
  pubsub_push_service_account_email = module.iam.pubsub_push_service_account_email

  # Cloud Scheduler's free tier is 3 jobs PER BILLING ACCOUNT, shared by dev and prod. Count today:
  #   prod: 2  (daily-maintenance, publish-scheduled)
  #   dev : 0  (envs/dev has jobs = {})
  #   total: 2 of 3 free. Keep the third slot free as headroom; any job beyond the third on the billing account is
  #   paid (about $0.10/month) and needs an ADR. ADR-0021 (founder decision 1) also assumes no Scheduler job lives
  #   outside dzeroth-dev and dzeroth-prod: confirm that before every prod apply that adds a job.
  # Dev stays empty on purpose: exercise a cron route in dev by calling it directly (ADR-0021 D1).
  jobs = {
    "daily-maintenance" = {
      schedule = "0 3 * * *"
      path     = "/internal/cron/daily-maintenance"
    }

    # ADR-0021 D1: the scheduled-post publish sweep. The route answers 204, or 500 only when its due query fails
    # (the module retries 3 times), and its handler runs under a 25 s deadline. The deadline chain is
    # handler 25 s < Cloud Run request timeout 30 s < this attempt deadline 60 s, so Scheduler never cancels an
    # attempt that Cloud Run would still finish. Overlapping runs (a retry and the next tick) are safe because the
    # publish is guarded by the PENDING state. Apply this job only after 100% of traffic serves a revision that has
    # the route; until then a tick reaches PlaceholderHandler and gets a harmless 202.
    "publish-scheduled" = {
      schedule                 = var.publish_scheduled_schedule
      path                     = "/internal/cron/publish-scheduled"
      attempt_deadline_seconds = 60
    }
  }

  depends_on = [module.project_services, module.cloud_run_api]
}

module "monitoring" {
  source         = "../../modules/monitoring"
  project_id     = var.project_id
  env            = local.env
  founder_emails = var.founder_emails
  api_hostname   = replace(module.cloud_run_api.url, "https://", "")

  # ADR-0011 C4 alert policy: ~$0.40/month, prod only.
  enable_auth_admin_alert = true # cost-approved: ADR-0011
  enable_ops_alerts       = true # R4: prod keeps uptime, 5xx and Firestore-reads alerts (ADR-0007 amendment 2026-10-10)

  # ADR-0022: credit-mode detectors. Stage 0 values by default (flood alert off, reads threshold 40k).
  enable_request_flood_alert    = var.enable_request_flood_alert    # ADR-0022 until:2026-12-26
  request_flood_per_hour        = var.request_flood_per_hour        # ADR-0022 until:2026-12-26
  firestore_reads_alert_per_day = var.firestore_reads_alert_per_day # ADR-0022 until:2026-12-22

  depends_on = [module.cloud_run_api]
}

module "budget" {
  source                   = "../../modules/budget"
  project_id               = var.project_id
  project_number           = data.google_project.this.number
  env                      = local.env
  billing_account          = var.billing_account
  amount                   = var.budget_amount
  currency_code            = var.budget_currency_code
  notification_channel_ids = module.monitoring.notification_channel_ids
  labels                   = merge(local.labels, { module = "budget" })

  depends_on = [module.project_services, module.monitoring]
}

// ADR-0022 credit-runway budgets. Both are OFF by default (var.enable_credit_budgets = false), so CI's plan shows no
// new resource. The founder turns them on in the real tfvars after the credit checklist. Both module blocks are deleted
// (which destroys the budget: the founder confirms) once their until: date has passed.
//
// 1. Whole-billing-account GROSS view of the credit window: only Always Free is subtracted, so spend paid by the
//    promotional credit is visible and can alert. No project filter (dev and account-level charges included).
module "credit_runway_budget" { # ADR-0022 until:2026-12-26
  count                    = var.enable_credit_budgets ? 1 : 0
  source                   = "../../modules/budget"
  project_id               = var.project_id
  project_number           = data.google_project.this.number
  env                      = local.env
  billing_account          = var.billing_account
  display_name             = "ADR-0022 credit runway gross ${var.credit_spend_cap_inr} ${var.budget_currency_code}" # API limit: 60 chars
  amount                   = var.credit_spend_cap_inr
  currency_code            = var.budget_currency_code
  actual_thresholds        = [0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
  projects                 = []
  credit_types_treatment   = "INCLUDE_SPECIFIED_CREDITS"
  credit_types             = ["FREE_TIER"]
  custom_period            = { start = "2026-10-23", end = "2026-12-26" } # ADR-0022 until:2026-12-26
  pubsub_topic_id          = module.budget.billing_alerts_topic
  notification_channel_ids = module.monitoring.notification_channel_ids
  labels                   = merge(local.labels, { module = "budget" })

  depends_on = [module.project_services, module.monitoring]
}

// 2. Prod monthly GROSS budget: the tighter detector (about the 1k-DAU profile). Any alert means spend above that profile.
//    The existing net budget (module "budget", INR 500) stays: it detects charges the credit does not cover.
module "prod_gross_budget" { # ADR-0022 until:2026-12-26
  count                    = var.enable_credit_budgets ? 1 : 0
  source                   = "../../modules/budget"
  project_id               = var.project_id
  project_number           = data.google_project.this.number
  env                      = local.env
  billing_account          = var.billing_account
  display_name             = "ADR-0022 prod monthly gross ${var.prod_gross_budget_inr} ${var.budget_currency_code}"
  amount                   = var.prod_gross_budget_inr
  currency_code            = var.budget_currency_code
  actual_thresholds        = [0.5, 0.9, 1.0]
  credit_types_treatment   = "INCLUDE_SPECIFIED_CREDITS"
  credit_types             = ["FREE_TIER"]
  pubsub_topic_id          = module.budget.billing_alerts_topic
  notification_channel_ids = module.monitoring.notification_channel_ids
  labels                   = merge(local.labels, { module = "budget" })

  depends_on = [module.project_services, module.monitoring]
}

module "firebase" {
  source               = "../../modules/firebase"
  project_id           = var.project_id
  env                  = local.env
  android_package_name = var.android_package_name
  ios_bundle_id        = var.ios_bundle_id
  hosting_site_id      = var.hosting_site_id

  # dzeroth.com serves the prod web app; www redirects to it (301). DNS is at Squarespace
  # (manual); see the custom_domain_dns_records output and docs/runbooks/cloud-bootstrap.md section 7.
  custom_domains = {
    "dzeroth.com"     = {}
    "www.dzeroth.com" = { redirect_to = "dzeroth.com" }
  }

  depends_on = [module.project_services]
}

// Security audit M3: restrict the three Firebase-auto-created API keys
// (imported by UID, see import_apikeys.tf) instead of leaving them open to
// any referrer/app/API. See docs/runbooks/cloud-bootstrap.md section 9.
// PLAN ONLY until the founder reviews dev's verified result -- do not apply
// to prod without a separate, explicit go-ahead.
module "apikeys" {
  source         = "../../modules/apikeys"
  project_number = data.google_project.this.number

  browser_key_uid = var.browser_key_uid
  android_key_uid = var.android_key_uid
  ios_key_uid     = var.ios_key_uid

  # Real prod origins only -- no localhost. www redirects to the apex in
  # Hosting but still needs to be an allowed referrer since the browser sends
  # its own Referer header before the 301 completes. The *.web.app /
  # *.firebaseapp.com fallbacks stay allowed (Firebase Auth's popup/iframe
  # runs on firebaseapp.com, and .web.app is the Hosting default URL).
  browser_allowed_referrers = [
    "https://dzeroth.com/*",
    "https://www.dzeroth.com/*",
    "https://dzeroth-prod.web.app/*",
    "https://dzeroth-prod.firebaseapp.com/*",
  ]

  # See envs/dev/main.tf for the full rationale (identical set): Identity
  # Toolkit + Token Service for Auth, Installations as the harmless baseline
  # every Firebase app needs. Verified against app/pubspec.yaml and
  # app/lib/app/bootstrap.dart 2026-09-27 -- the web app has no Firestore,
  # Storage or Messaging client SDK.
  browser_api_targets = [
    "identitytoolkit.googleapis.com",
    "securetoken.googleapis.com",
    "firebaseinstallations.googleapis.com",
  ]

  # Plus App Check: Android/iOS activate real attestation providers
  # (Play Integrity / App Attest) in release builds. Web defers App Check
  # (ADR-0006 amendment).
  android_api_targets = [
    "identitytoolkit.googleapis.com",
    "securetoken.googleapis.com",
    "firebaseinstallations.googleapis.com",
    "firebaseappcheck.googleapis.com",
  ]
  ios_api_targets = [
    "identitytoolkit.googleapis.com",
    "securetoken.googleapis.com",
    "firebaseinstallations.googleapis.com",
    "firebaseappcheck.googleapis.com",
  ]

  ios_bundle_id = var.ios_bundle_id
  # android_allowed_applications left at its default ([]): no Play Console
  # signing cert yet. See docs/runbooks/cloud-bootstrap.md section 9.

  depends_on = [module.project_services]
}
