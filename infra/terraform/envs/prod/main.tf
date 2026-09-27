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
  source      = "../../modules/iam"
  project_id  = var.project_id
  env         = local.env
  github_repo = var.github_repo

  # prod deploys ONLY from version tags — see release-rollout skill
  # (tag v* -> --no-traffic --tag rc -> smoke -> manual GO -> traffic shift).
  deploy_ref_condition   = "assertion.ref.startsWith('refs/tags/v')"
  deploy_ref_description = "version tags only (refs/tags/v*)"

  # M6: pin the deploy WIF token to the exact release workflow file (a
  # modified/forked copy on some other ref can't mint a usable token even if
  # it satisfies repository+ref) and to the GitHub Environments this release
  # workflow actually uses — including the two with required reviewers, so a
  # token can never be minted for a job that skips the approval gates.
  deploy_extra_conditions = [
    "assertion.job_workflow_ref.startsWith('${var.github_repo}/.github/workflows/release-prod.yml@refs/tags/v')",
    "assertion.environment in ['prod', 'production-traffic-10', 'production-traffic-100']",
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

  extra_env_vars = [
    { name = "MEDIA_UPLOAD_BUCKET", value = module.media_buckets.upload_bucket_name },
    { name = "MEDIA_BUCKET", value = module.media_buckets.media_bucket_name },
  ]

  depends_on = [module.project_services, module.secrets]
}

module "pubsub" {
  source                            = "../../modules/pubsub"
  project_id                        = var.project_id
  push_base_url                     = local.api_url
  pubsub_push_service_account_email = module.iam.pubsub_push_service_account_email
  pubsub_service_agent_email        = "service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
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
  env                      = local.env
  billing_account          = var.billing_account
  amount_usd               = var.budget_amount_usd
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

  depends_on = [module.project_services]
}
