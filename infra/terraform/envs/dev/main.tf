locals {
  env          = "dev"
  service_name = "api"
  labels = {
    env         = "dev"
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

module "iam" {
  source          = "../../modules/iam"
  project_id      = var.project_id
  billing_account = var.billing_account
  env             = local.env
  github_repo     = var.github_repo

  # dev deploys on every push to main.
  deploy_ref_condition   = "assertion.ref == 'refs/heads/main'"
  deploy_ref_description = "push to main"

  # Defense in depth, same idea as prod (M6): only a token minted for this
  # exact workflow file, on main, for the `dev` GitHub Environment can deploy.
  deploy_extra_conditions = [
    "assertion.job_workflow_ref == '${var.github_repo}/.github/workflows/deploy-dev.yml@refs/heads/main'",
    "assertion.environment == 'dev'",
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
  # Terraform generates and seeds it; nothing to set manually.
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

  # dev + prod combined must stay <= 3 jobs (Cloud Scheduler free tier is per
  # billing account). Keep dev empty by default; run cron for real in prod
  # only, and use `gcloud scheduler jobs run` manually to test in dev.
  jobs = {}

  depends_on = [module.project_services, module.cloud_run_api]
}

module "monitoring" {
  source         = "../../modules/monitoring"
  project_id     = var.project_id
  env            = local.env
  founder_emails = var.founder_emails
  api_hostname   = replace(module.cloud_run_api.url, "https://", "")

  # ADR-0011 C4 alert is prod only (~$0.40/month); dev relies on log inspection. The log-based metric still exists.
  enable_auth_admin_alert = false

  # R4 (founder 2026-10-10, ADR-0007 amendment): ops alert policies are billable, so prod only. Dev relies on the dashboard.
  enable_ops_alerts = false

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

module "firebase" {
  source               = "../../modules/firebase"
  project_id           = var.project_id
  env                  = local.env
  android_package_name = var.android_package_name
  ios_bundle_id        = var.ios_bundle_id
  hosting_site_id      = var.hosting_site_id

  # dev.dzeroth.com serves the dev web app. DNS is at Squarespace (manual); see the
  # custom_domain_dns_records output and docs/runbooks/cloud-bootstrap.md section 7.
  custom_domains = {
    "dev.dzeroth.com" = {}
  }

  depends_on = [module.project_services]
}

// Security audit M3: restrict the three Firebase-auto-created API keys
// (imported by UID, see import_apikeys.tf) instead of leaving them open to
// any referrer/app/API. See docs/runbooks/cloud-bootstrap.md section 9.
module "apikeys" {
  source         = "../../modules/apikeys"
  project_number = data.google_project.this.number

  browser_key_uid = var.browser_key_uid
  android_key_uid = var.android_key_uid
  ios_key_uid     = var.ios_key_uid

  # dev.dzeroth.com is the real domain; the *.web.app / *.firebaseapp.com
  # fallbacks stay allowed (Firebase Auth's popup/iframe runs on
  # firebaseapp.com, and .web.app is the Hosting default URL). localhost
  # entries are dev-only, for `flutter run -d chrome` / `flutter build web`
  # served locally -- ports match cors_origins' default
  # (http://localhost:5000, http://localhost:8080).
  #
  # NOTE: "http://localhost:*" (a port wildcard) does NOT work -- verified
  # live against identitytoolkit 2026-09-27: it returns
  # API_KEY_HTTP_REFERRER_BLOCKED for http://localhost:5000/, same as an
  # origin not in the list at all. Google's referrer matcher only wildcards
  # a trailing path segment (the "/*" suffix seen on every other entry here),
  # not a port number -- list every dev port explicitly instead.
  browser_allowed_referrers = [
    "https://dev.dzeroth.com/*",
    "https://dzeroth-dev.web.app/*",
    "https://dzeroth-dev.firebaseapp.com/*",
    "http://localhost:5000/*",
    "http://localhost:8080/*",
  ]

  # Baseline every Firebase app needs (Identity Toolkit + Token Service for
  # Auth, Installations for anonymous install IDs — required by App Check,
  # which Android/iOS activate; harmless, no PII, if unused). Everything else
  # Firebase auto-added (Firestore, Realtime DB, Storage, ML Kit, Remote
  # Config, sqladmin, ...) is dropped: the app's pubspec.yaml only depends on
  # firebase_core + firebase_auth + firebase_app_check (verified against
  # app/pubspec.yaml and app/lib/app/bootstrap.dart 2026-09-27) — Firestore is
  # server-side only (Go Admin SDK), and media uploads go straight to plain
  # GCS via signed URLs, never through the Firebase Storage SDK.
  browser_api_targets = [
    "identitytoolkit.googleapis.com",
    "securetoken.googleapis.com",
    "firebaseinstallations.googleapis.com",
  ]

  # Same baseline plus App Check: Android/iOS call FirebaseAppCheck.activate()
  # with real attestation providers in release builds (bootstrap.dart) —
  # unlike web, which defers App Check until a reCAPTCHA Enterprise key exists
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
