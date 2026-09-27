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

  depends_on = [module.project_services]
}
