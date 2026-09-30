// Service accounts + Workload Identity Federation for GitHub Actions.
// No service-account keys anywhere — WIF only (CLAUDE.md rule).

// ---------------------------------------------------------------------------
// Runtime service account — used by the Cloud Run `api` service.
// ---------------------------------------------------------------------------
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "api-runtime"
  display_name = "Cloud Run api runtime (${var.env})"
}

resource "google_project_iam_member" "runtime_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

// No project-wide roles/secretmanager.secretAccessor here — grant it per
// secret instead (see the `secrets` module's `runtime_accessor` /
// `generated_runtime_accessor` resources), so the runtime SA can only read
// the specific secrets this env actually has (e.g. cursor-hmac-key).

resource "google_project_iam_member" "runtime_logwriter" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_metricwriter" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_errorreporting" {
  project = var.project_id
  role    = "roles/errorreporting.writer"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

// The runtime SA signs GCS V4 upload URLs for itself (ADC signing needs this
// even when the code never impersonates another identity).
resource "google_service_account_iam_member" "runtime_self_token_creator" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.runtime.email}"
}

// ---------------------------------------------------------------------------
// Pub/Sub push service account — the OIDC identity Pub/Sub uses to call
// `/internal/*` push endpoints on the api service. Deliberately has no other
// permissions: Cloud Run IAM (module) grants it `roles/run.invoker` only.
// ---------------------------------------------------------------------------
resource "google_service_account" "pubsub_push" {
  project      = var.project_id
  account_id   = "pubsub-push"
  display_name = "Pub/Sub + Scheduler push OIDC identity (${var.env})"
}

// ---------------------------------------------------------------------------
// CI deploy service account — used by GitHub Actions (via WIF) to build and
// ship this environment: push images, deploy Cloud Run revisions, deploy
// Firestore rules/indexes and Firebase Hosting.
// ---------------------------------------------------------------------------
resource "google_service_account" "ci_deploy" {
  project      = var.project_id
  account_id   = "ci-deploy"
  display_name = "GitHub Actions deployer (${var.env})"
}

// roles/run.developer (not roles/run.admin): deploy revisions + shift traffic,
// but cannot change the service's IAM policy (can't grant itself/others
// run.invoker or otherwise escalate). Combined with the actAs grant below,
// scoped to the single runtime SA, this is the minimum CI needs.
resource "google_project_iam_member" "ci_deploy_run_developer" {
  project = var.project_id
  role    = "roles/run.developer"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

resource "google_project_iam_member" "ci_deploy_ar_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

// Deploying a new Cloud Run revision that runs as `runtime` requires the
// deployer to be able to actAs it. Scoped to that single SA, not project-wide.
resource "google_service_account_iam_member" "ci_deploy_actas_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.ci_deploy.email}"
}

resource "google_project_iam_member" "ci_deploy_firestore_index_admin" {
  project = var.project_id
  role    = "roles/datastore.indexAdmin"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

resource "google_project_iam_member" "ci_deploy_firebaserules_admin" {
  project = var.project_id
  role    = "roles/firebaserules.admin"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

resource "google_project_iam_member" "ci_deploy_hosting_admin" {
  project = var.project_id
  role    = "roles/firebasehosting.admin"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

// Needed to read Firebase web app config during `flutter build web` in CI.
resource "google_project_iam_member" "ci_deploy_firebase_viewer" {
  project = var.project_id
  role    = "roles/firebase.viewer"
  member  = "serviceAccount:${google_service_account.ci_deploy.email}"
}

// ---------------------------------------------------------------------------
// Terraform plan-only service account — used by `terraform.yml` for
// `fmt`/`validate`/`plan` on PRs. Read-only by design: this repo's CI never
// applies Terraform (see gcp-terraform skill + release-rollout skill).
// `terraform apply` is a deliberate, human-run action until an ADR adds a
// gated apply pipeline.
// ---------------------------------------------------------------------------
resource "google_service_account" "tf_plan" {
  project      = var.project_id
  account_id   = "tf-plan"
  display_name = "Terraform plan (read-only, ${var.env})"
}

resource "google_project_iam_member" "tf_plan_viewer" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.tf_plan.email}"
}

resource "google_project_iam_member" "tf_plan_security_reviewer" {
  project = var.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.tf_plan.email}"
}

// The providers set user_project_override + billing_project (needed for the Budgets and Firebase APIs), so
// every API call is billed to this project and the caller needs serviceusage.services.use.
resource "google_project_iam_member" "tf_plan_serviceusage_consumer" {
  project = var.project_id
  role    = "roles/serviceusage.serviceUsageConsumer"
  member  = "serviceAccount:${google_service_account.tf_plan.email}"
}

// roles/billing.viewer only exists at billing-account level (not on projects). Lets the plan SA refresh
// the budget resource; read-only.
resource "google_billing_account_iam_member" "tf_plan_billing_viewer" {
  billing_account_id = var.billing_account
  role               = "roles/billing.viewer"
  member             = "serviceAccount:${google_service_account.tf_plan.email}"
}

// Read access to remote state. The state bucket itself is created manually
// (see gcp-terraform skill); grant this SA `roles/storage.objectViewer` on
// it as part of that one-time step.

// ---------------------------------------------------------------------------
// Workload Identity Federation — GitHub Actions OIDC, no JSON keys.
//
// Two SEPARATE pools (not two providers in one pool): principalSet IAM
// bindings are scoped to a pool + attribute value, and providers in the same
// pool share that attribute namespace. Two pools give each use case its own
// principal namespace, so a "plan" token (any branch/PR, no ref check) can
// never satisfy the IAM binding that authorizes "deploy" (which requires a
// specific ref pattern). Each provider's attribute_condition additionally
// pins it to this exact repo, so a fork can never mint a usable token.
// ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "deploy" {
  project                   = var.project_id
  workload_identity_pool_id = "github-deploy"
  display_name              = "GitHub deploy (${var.env})"
  description               = "Federated identity for ${var.github_repo} deploy workflows targeting ${var.env}."
}

resource "google_iam_workload_identity_pool_provider" "deploy" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.deploy.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  # display_name has a 32-character limit (N2) — keep it short and put the
  # human-readable detail (deploy_ref_description) in `description` instead.
  display_name = "CI deploy (${var.env})"
  description  = "GitHub Actions deploy identity for ${var.github_repo} (${var.env}): ${var.deploy_ref_description}."

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # e.g. dev: repository == 'org/repo' && ref == 'refs/heads/main'
  #      prod: repository == 'org/repo' && ref.startsWith('refs/tags/v') && job_workflow_ref
  #            starts with the exact release workflow file && environment is one this deploy uses.
  # deploy_extra_conditions (job_workflow_ref / environment pins) are ANDed in so a modified
  # workflow file, a different ref, or a job without the protected environment can never mint a
  # usable token even if it satisfies the base repository+ref check (M6).
  attribute_condition = join(" && ", concat(
    [
      "assertion.repository == '${var.github_repo}'",
      "(${var.deploy_ref_condition})",
    ],
    [for c in var.deploy_extra_conditions : "(${c})"],
  ))

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_iam_workload_identity_pool" "plan" {
  project                   = var.project_id
  workload_identity_pool_id = "github-plan"
  display_name              = "GitHub plan (${var.env})"
  description               = "Federated identity for ${var.github_repo} `terraform plan` on any branch/PR — read-only."
}

resource "google_iam_workload_identity_pool_provider" "plan" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.plan.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  # display_name has a 32-character limit (N2) — keep it short and put the
  # human-readable detail in `description` instead.
  display_name = "TF plan (read-only)"
  description  = "GitHub Actions terraform-plan identity for ${var.github_repo} (${var.env}): any branch/PR, read-only."

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # Plan tokens are for humans' PRs/dispatches in THIS repo only. Dependabot never gets one (any dependency or
  # workflow change it proposes would run with id-token: write), and only pull_request / workflow_dispatch events
  # qualify (no pull_request_target, push or schedule). Fork PRs never receive an OIDC token from GitHub and are
  # additionally skipped in terraform.yml. Applies to dev and prod alike.
  attribute_condition = join(" && ", [
    "assertion.repository == '${var.github_repo}'",
    "assertion.actor != 'dependabot[bot]'",
    "assertion.event_name in ['pull_request', 'workflow_dispatch']",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "ci_deploy_wif_binding" {
  service_account_id = google_service_account.ci_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.deploy.name}/attribute.repository/${var.github_repo}"
}

resource "google_service_account_iam_member" "tf_plan_wif_binding" {
  service_account_id = google_service_account.tf_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.plan.name}/attribute.repository/${var.github_repo}"
}
