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

module "iam" {
  source          = "../../modules/iam"
  project_id      = var.project_id
  billing_account = var.billing_account
  env             = local.env
  github_repo     = var.github_repo

  # prod deploys ONLY from version tags — see release-rollout skill
  # (tag v* -> --no-traffic --tag rc -> smoke -> manual GO -> traffic shift).
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
  # billing account). Prod runs the real cron; dev's list is empty.
  jobs = {
    "daily-maintenance" = {
      schedule = "0 3 * * *"
      path     = "/internal/cron/daily-maintenance"
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
