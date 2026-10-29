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

// roles/pubsub.publisher is NOT granted project-wide: the runtime SA only publishes to the `jobs` topic, so the
// binding lives on that topic in modules/pubsub (runtime_publisher_topics).

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

// Account lifecycle (ADR-0011 IAM): the narrowest Firebase Auth role. roles/firebaseauth.admin is rejected (it also
// grants configs.getSecret, users.create, users.createSession, users.sendEmail). Deletion and export may only
// act on the caller's own uid; that is enforced in code (controls C1-C3) and watched by the C4 alert in the
// monitoring module. Emergency stop: remove this binding (all Auth mutations stop at once).
resource "google_project_iam_custom_role" "account_lifecycle_auth" {
  project     = var.project_id
  role_id     = "accountLifecycleAuth"
  title       = "Account lifecycle Firebase Auth (ADR-0011)"
  description = "Read, disable/revoke and delete a Firebase Auth user. Nothing else."
  permissions = [
    "firebaseauth.users.get",
    "firebaseauth.users.update",
    "firebaseauth.users.delete",
  ]
}

resource "google_project_iam_member" "runtime_account_lifecycle_auth" {
  project = var.project_id
  role    = google_project_iam_custom_role.account_lifecycle_auth.id
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

// Push notifications (ADR-0017 D6): FCM HTTP v1 send needs exactly one permission, cloudmessaging.messages.create.
// roles/firebasecloudmessaging.admin is rejected (it also manages campaigns/composer data), and the default Cloud
// Run runtime has no FCM access without a grant (review P6 M3). The API fcm.googleapis.com is enabled in the
// project-services module. Emergency stop: remove this binding (every push fails with PERMISSION_DENIED, rows
// keep being written).
resource "google_project_iam_custom_role" "fcm_send" {
  project     = var.project_id
  role_id     = "fcmSend"
  title       = "FCM send (ADR-0017)"
  description = "Send a message through Firebase Cloud Messaging. Nothing else."
  permissions = [
    "cloudmessaging.messages.create",
  ]
}

resource "google_project_iam_member" "runtime_fcm_send" {
  project = var.project_id
  role    = google_project_iam_custom_role.fcm_send.id
  member  = "serviceAccount:${google_service_account.runtime.email}"
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

// Moving an existing Artifact Registry tag (`gcloud artifacts docker tags add ... :last-good` / `:serving` in promote-dev.sh) needs
// artifactregistry.tags.delete, which roles/artifactregistry.writer does not carry (proven by deploy-dev run 39637856312, step 5/8:
// PERMISSION_DENIED artifactregistry.tags.delete). Least privilege: a custom role with that ONE permission, bound on the `api`
// repository only (not project-wide, not repoAdmin/admin), and ONLY where ci_deploy_can_move_ar_tags is true (dev). Prod
// intentionally does not get it: promote-prod only reads tags and release-prod only creates new ones, and tags.delete on prod's
// ci-deploy would let it de-protect the v* release tags. Emergency stop: remove the binding (tag moves fail, promotion refuses at
// step 5/8 before any traffic change). Residual risk where it is granted: ci-deploy can delete ANY tag in that repo (an IAM
// condition on the tag name was not verified, so none is used; see the PR that added this).
resource "google_project_iam_custom_role" "ar_tag_mover" {
  count = var.ci_deploy_can_move_ar_tags ? 1 : 0

  project     = var.project_id
  role_id     = "arTagMover"
  title       = "Artifact Registry tag mover"
  description = "Delete (and so re-point) an Artifact Registry tag. Nothing else."
  permissions = [
    "artifactregistry.tags.delete",
  ]
}

resource "google_artifact_registry_repository_iam_member" "ci_deploy_ar_tag_mover" {
  count = var.ci_deploy_can_move_ar_tags ? 1 : 0

  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = google_project_iam_custom_role.ar_tag_mover[0].id
  member     = "serviceAccount:${google_service_account.ci_deploy.email}"

  lifecycle {
    precondition {
      condition     = var.artifact_registry_repository_id != "" && var.artifact_registry_location != ""
      error_message = "ci_deploy_can_move_ar_tags needs artifact_registry_repository_id and artifact_registry_location."
    }
  }
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

// What `tf-plan` can read (W7-32, finding M-4 of the W7-22 messaging security review; supersedes the v0.1.0 / v0.2.0 M4
// acceptance). It used to hold roles/viewer AND roles/iam.securityReviewer. Between them they carry
// datastore.entities.get/list (viewer) and datastore.entities.list (securityReviewer); Firestore RunQuery and
// ListDocuments check entities.list, so EITHER role alone lets a plan token read every message, every report's
// evidence and users/{uid}/private. They also carry firebaseauth.users.get (viewer), logging.logEntries.list and
// logging.privateLogEntries.list, and object reads/lists on the user-content buckets. Pinning the WIF workflow would
// not help: a same-repo PR can edit the pinned workflow file. So the identity itself must be unable to read user data.
//
// `tfPlanReader` is a custom role that holds only the get / list / getIamPolicy METADATA permissions that
// `terraform plan` needs to refresh the resource types in infra/terraform. Deliberately NOT in it, never to be added:
//   datastore.entities.*                 any Firestore document (messages, reports, users/{uid}/private)
//   firebaseauth.users.*                 Firebase Auth user records
//   storage.objects.* (project-wide)     contents or names of the media / upload / exports buckets
//   secretmanager.versions.access        secret values (the provider's :access read is tolerated, see below)
//   logging.logEntries.*, logging.privateLogEntries.*, logging.views.*, logging.sinks.*, logging.buckets.*
//   any *.getIamPolicy that no managed resource needs
// Adding a resource type to infra/terraform means adding ITS read permissions here in the same PR; a reviewer checks the
// addition against the list above. If `terraform plan` as tf-plan fails with a 403 on a refresh, add exactly the
// permission the error names. Never bind a predefined *.viewer role instead: they include data reads.
//
// Known and accepted:
//  - google_secret_manager_secret_version reads the payload with :access on every plan. Without
//    secretmanager.versions.access that call returns 403 and the provider (checked at v8.8.1, the locked version) logs
//    it and keeps the value already in state, so plan still works. Expect one PERMISSION_DENIED audit line per generated
//    secret per plan (unverified until the dev impersonation run).
//  - monitoring.timeSeries.list still arrives through roles/serviceusage.serviceUsageConsumer below (metrics only).
//  - Reading Terraform state is a separate, bucket-level grant on the state bucket (see the note after the billing
//    binding). The state holds generated secrets (the cursor HMAC key), so that grant is the next thing to narrow.
resource "google_project_iam_custom_role" "tf_plan_reader" {
  project     = var.project_id
  role_id     = "tfPlanReader"
  title       = "Terraform plan reader (W7-32)"
  description = "Get/list/getIamPolicy metadata for the resource types in infra/terraform. No document, user, object, secret-value or log-entry reads."
  permissions = [
    // Project metadata and project IAM policy: data.google_project, every project-scoped resource,
    // google_project_iam_member (refreshes the project policy), google_project_iam_audit_config (dev).
    "resourcemanager.projects.get",
    "resourcemanager.projects.getIamPolicy",

    // google_project_service (project-services module). Also in serviceUsageConsumer; repeated so this role stands alone.
    "serviceusage.services.get",
    "serviceusage.services.list",

    // google_project_iam_custom_role (account_lifecycle_auth, fcm_send, ar_tag_mover, and this role itself).
    "iam.roles.get",
    "iam.roles.list",

    // google_service_account (runtime, pubsub-push, ci-deploy, tf-plan) and google_service_account_iam_member.
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.getIamPolicy",

    // google_iam_workload_identity_pool and _provider (github-deploy, github-plan). IAM reports these under two
    // permission spellings (the iam.googleapis.com/ form is the one roles/viewer carried); all are metadata only.
    "iam.workloadIdentityPools.get",
    "iam.workloadIdentityPools.list",
    "iam.workloadIdentityPoolProviders.get",
    "iam.workloadIdentityPoolProviders.list",
    "iam.googleapis.com/workloadIdentityPools.get",
    "iam.googleapis.com/workloadIdentityPools.list",
    "iam.googleapis.com/workloadIdentityPoolProviders.get",
    "iam.googleapis.com/workloadIdentityPoolProviders.list",

    // google_firestore_database, google_firestore_field (TTL policies, via the field/index admin API) and
    // google_firestore_backup_schedule. Metadata only: NEVER datastore.entities.*.
    "datastore.databases.get",
    "datastore.databases.getMetadata",
    "datastore.databases.list",
    "datastore.indexes.get",
    "datastore.indexes.list",
    "datastore.backupSchedules.get",
    "datastore.backupSchedules.list",

    // google_cloud_run_v2_service (api) and google_cloud_run_v2_service_iam_member (public and push invokers).
    "run.services.get",
    "run.services.list",
    "run.services.getIamPolicy",

    // google_pubsub_topic (jobs, dlq, billing-alerts), google_pubsub_subscription, and the topic and subscription
    // iam_member resources (dlq publisher, dlq ack, runtime publisher).
    "pubsub.topics.get",
    "pubsub.topics.list",
    "pubsub.topics.getIamPolicy",
    "pubsub.subscriptions.get",
    "pubsub.subscriptions.list",
    "pubsub.subscriptions.getIamPolicy",

    // google_cloud_scheduler_job. NOT cloudscheduler.jobs.fullView: no job sets a body or headers, and fullView would
    // expose them if one ever carried a credential.
    "cloudscheduler.jobs.get",
    "cloudscheduler.jobs.list",

    // google_secret_manager_secret, its iam_member, and google_secret_manager_secret_version (metadata via versions.get).
    // NEVER secretmanager.versions.access.
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.versions.get",
    "secretmanager.versions.list",

    // google_artifact_registry_repository (cleanup policy included) and google_artifact_registry_repository_iam_member (dev).
    "artifactregistry.repositories.get",
    "artifactregistry.repositories.list",
    "artifactregistry.repositories.getIamPolicy",

    // google_storage_bucket (upload, media, exports) and google_storage_bucket_iam_member. Bucket config and policy
    // only: NEVER storage.objects.* project-wide (the state bucket gets objectViewer at bucket level, not here).
    "storage.buckets.get",
    "storage.buckets.list",
    "storage.buckets.getIamPolicy",

    // google_monitoring_alert_policy, google_monitoring_dashboard, google_monitoring_uptime_check_config.
    // Notification channels use the predefined roles/monitoring.notificationChannelViewer binding below, because
    // monitoring.notificationChannels.get/list are still at "testing" level for custom roles.
    "monitoring.alertPolicies.get",
    "monitoring.alertPolicies.list",
    "monitoring.dashboards.get",
    "monitoring.dashboards.list",
    "monitoring.uptimeCheckConfigs.get",
    "monitoring.uptimeCheckConfigs.list",

    // google_logging_metric (auth_admin_mutations). Metric definitions only: NEVER logging.logEntries.* or logging.privateLogEntries.*.
    "logging.logMetrics.get",
    "logging.logMetrics.list",

    // google_apikeys_key (browser, android, ios; modules/apikeys). getKeyString because key_string is a computed
    // attribute. These are the Firebase client keys that ship in every app build (public by design, protected by the
    // key restrictions and App Check), not secrets.
    "apikeys.keys.get",
    "apikeys.keys.list",
    "apikeys.keys.getKeyString",

    // google_firebase_project, google_firebase_web_app / android_app / apple_app, google_firebase_hosting_site and
    // google_firebase_hosting_custom_domain (modules/firebase).
    "firebase.projects.get",
    "firebase.clients.get",
    "firebase.clients.list",
    "firebasehosting.sites.get",
    "firebasehosting.sites.list",
  ]
}

resource "google_project_iam_member" "tf_plan_reader" {
  project = var.project_id
  role    = google_project_iam_custom_role.tf_plan_reader.id
  member  = "serviceAccount:${google_service_account.tf_plan.email}"
}

// google_monitoring_notification_channel (email). The predefined role holds only notificationChannels get/list and
// notificationChannelDescriptors get/list (no verification codes, no writes).
resource "google_project_iam_member" "tf_plan_notification_channel_viewer" {
  project = var.project_id
  role    = "roles/monitoring.notificationChannelViewer"
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

// Read access to remote state. The state bucket (dzeroth-tfstate, in the prod project) is created manually and is not
// managed by Terraform, and a dev tf-plan SA could not refresh an IAM resource on a bucket in another project, so
// this grant is deliberately NOT a Terraform resource. It must exist as an explicit BUCKET-level binding for each
// env's tf-plan SA: `roles/storage.objectViewer` on gs://dzeroth-tfstate (the gcs backend needs objects.get and
// objects.list). Do not rely on the project-viewer convenience binding on buckets (it vanished from tf-plan with
// roles/viewer, W7-32). Steps: docs/runbooks/ci-enforcement.md section 13.

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
