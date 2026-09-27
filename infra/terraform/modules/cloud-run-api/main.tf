// Cloud Run v2 service `api` — the entire backend modular monolith.
// Request-based billing only: min 0 (scales to zero), max 3 (cost cap +
// blast-radius cap), 1 vCPU / 512Mi, CPU allocated only during requests,
// concurrency 80, 30s timeout. Public invoker: authn is Firebase ID tokens
// checked in Go, not IAM — this is what lets us skip a load balancer/IAP.

resource "google_cloud_run_v2_service" "api" {
  project  = var.project_id
  name     = var.service_name
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  # cost-guard: min_instance_count must stay 0 at Stage 0 (see gcp-terraform skill).
  # Bumping this to 1+ is the documented Stage 1 trigger and needs an ADR +
  # `# cost-approved: ADR-NNNN` on this block.
  template {
    service_account = var.runtime_service_account_email
    timeout         = "${var.request_timeout_seconds}s"

    max_instance_request_concurrency = var.concurrency

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instance_count
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      ports {
        container_port = var.container_port
      }

      dynamic "env" {
        for_each = local.env_vars
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      // Secret Manager-backed env vars (e.g. CURSOR_HMAC_KEY) — resolved by the
      // runtime service account at container start, never written to state as
      // plaintext, never a Terraform diff when the secret value rotates.
      dynamic "env" {
        for_each = var.secret_env_vars
        content {
          name = env.value.name
          value_source {
            secret_key_ref {
              secret  = env.value.secret
              version = env.value.version
            }
          }
        }
      }

      startup_probe {
        http_get {
          path = "/health"
        }
        initial_delay_seconds = 0
        period_seconds        = 2
        failure_threshold     = 5
        timeout_seconds       = 2
      }

      liveness_probe {
        http_get {
          path = "/health"
        }
        period_seconds = 10
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  labels = var.labels

  lifecycle {
    ignore_changes = [
      # Deploys happen via `gcloud run deploy` / `google-github-actions/deploy-cloudrun`
      # in CI (see release-rollout skill); Terraform owns shape/caps, not the
      # image digest or the live traffic split (tagged-revision rollouts).
      template[0].containers[0].image,
      traffic,
      # Service-level `scaling` is unset here; the API echoes back zero defaults, causing a permanent
      # no-op diff. The real caps are template.scaling (min 0 / max 3), which stays managed.
      scaling,
      # Stamped by every `gcloud run deploy` (client = "gcloud"); pure metadata, would show as drift forever.
      client,
      client_version,
    ]
  }
}

// Exact shared env contract (see cloud-bootstrap.md / release-rollout skill):
// ENV, FIREBASE_PROJECT_ID, DEGRADED_MODE, APP_CHECK_MODE, INTERNAL_OIDC_AUDIENCE,
// INTERNAL_OIDC_ALLOWED_EMAILS, plus CURSOR_HMAC_KEY via secret_env_vars above and
// any module-specific plain vars via extra_env_vars (e.g. MEDIA_UPLOAD_BUCKET).
// No GCP_PROJECT_ID: backend/pkg/platform/config reads FIREBASE_PROJECT_ID /
// GOOGLE_CLOUD_PROJECT / GCP_PROJECT, and nothing reads GCP_PROJECT_ID.
locals {
  env_vars = concat(
    [
      { name = "ENV", value = var.env },
      { name = "FIREBASE_PROJECT_ID", value = var.project_id },
      { name = "DEGRADED_MODE", value = var.degraded_mode },
      { name = "APP_CHECK_MODE", value = var.app_check_mode },
      { name = "INTERNAL_OIDC_AUDIENCE", value = var.internal_oidc_audience },
      { name = "INTERNAL_OIDC_ALLOWED_EMAILS", value = join(",", var.internal_oidc_allowed_emails) },
    ],
    var.extra_env_vars,
  )
}

// Public invoker — see comment above. Abuse is bounded by App Check +
// per-user quotas in Firestore + max-instances, not IAM.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

// The Pub/Sub + Scheduler push identity may call the service (Go code
// enforces that only `/internal/*` accepts it and verifies the OIDC token's
// audience/issuer/service-account itself; this grant is just "can invoke").
resource "google_cloud_run_v2_service_iam_member" "pubsub_push_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.pubsub_push_service_account_email}"
}
