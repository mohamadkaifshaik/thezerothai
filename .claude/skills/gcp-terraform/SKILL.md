---
name: gcp-terraform
description: Terraform conventions, module list and environment layout for the free-tier GCP + Firebase infrastructure, including budgets and cost caps. Use for any infra change.
---

# Terraform on GCP (Stage 0, free tier)

```
infra/terraform/
  modules/
    project-services   # enable only the APIs we use (run, firestore, storage, pubsub, cloudscheduler, secretmanager,
                       #   artifactregistry, iamcredentials, vision, firebase, identitytoolkit, billingbudgets, monitoring)
    firestore          # google_firestore_database "(default)", location asia-south1, type FIRESTORE_NATIVE,
                       #   delete_protection_state = DELETE_PROTECTION_ENABLED; TTL policies (notifications.expireAt, media.expireAt)
    cloud-run-api      # google_cloud_run_v2_service: min 0, max 3, 1 vCPU, 512Mi, concurrency 80, cpu_idle = true,
                       #   startup_cpu_boost = true, timeout 30s, ingress all, allUsers invoker (app auth is in Go)
    media-buckets      # upload (private, lifecycle 2d, CORS) + media (public-read) in us-central1
    pubsub             # topics + push subscriptions to /internal/* with OIDC SA, DLQ topic, max 5 delivery attempts
    scheduler          # ≤ 3 jobs total per billing account (e.g., daily-maintenance, weekly-snapshot-refresh)
    artifact-registry  # docker repo asia-south1 with cleanup policy: keep 3 most recent, delete untagged after 1d
    iam                # runtime SA, pubsub-push SA, CI deployer SA, Workload Identity Federation pool for GitHub
    secrets            # only what can't be env config (≤ 6 active versions across the project)
    budget             # google_billing_budget: $5, thresholds 0.25/0.5/0.9/1.0 + forecast 1.0, pubsub topic billing-alerts
    monitoring         # 1 dashboard (reads, writes, requests, instances, egress), 1 uptime check on /healthz, ≤ 3 alert policies
    firebase           # google_firebase_project, web/android/ios apps, hosting site; App Check config
  envs/{dev,prod}/{main.tf,variables.tf,terraform.tfvars,backend.tf}
```

## Conventions
- Provider pinned (`google`/`google-beta` ~> 6.x), `required_version` pinned.
- Remote state: one small GCS bucket (us-central1, versioning on, lifecycle keep 10 versions) — within free storage.
- One project per env (dev, prod) on **one billing account**. Remember Cloud Run free tier is shared across both.
- Labels on everything: `env, module, cost-center`.
- Deletion protection on Firestore and the media bucket (`force_destroy = false`).
- CI: `terraform fmt -check && terraform validate && tflint && checkov -d . --soft-fail-on MEDIUM`; plan on PR, apply on main (prod requires GitHub environment approval).

## Forbidden without an Accepted ADR (fixed monthly cost) — enforced by `.claude/hooks/cost-guard.sh`
`google_container_cluster`, `google_container_node_pool`, `google_spanner_instance`, `google_redis_instance`,
`google_redis_cluster`, `google_sql_database_instance`, `google_alloydb_*`, `google_compute_instance` (except the documented
e2-micro option), `google_compute_global_forwarding_rule`, `google_compute_forwarding_rule`, `google_compute_security_policy`,
`google_compute_router_nat`, `google_vpc_access_connector`, `google_kms_crypto_key`, `google_clouddeploy_*`,
`google_filestore_instance`, `google_vertex_ai_*`, `google_discovery_engine_*`, Cloud Run `min_instance_count > 0`.
To use one, add `# cost-approved: ADR-NNNN` on the resource line and reference the ADR in the PR.

## Rules
- Never `terraform destroy` or replace Firestore/buckets without explicit human confirmation.
- Firestore location is permanent — confirm `asia-south1` (or chosen region) with the human before first apply.
- Firebase Auth providers: Email/Password, Google, Apple. Do **not** enable Phone.
- Keep the Cloud Run service public (`allUsers` invoker) — authentication is Firebase ID tokens in the app; this avoids needing an LB/IAP.
