output "runtime_service_account_email" {
  value = google_service_account.runtime.email
}

output "pubsub_push_service_account_email" {
  value = google_service_account.pubsub_push.email
}

output "ci_deploy_service_account_email" {
  value = google_service_account.ci_deploy.email
}

output "tf_plan_service_account_email" {
  value = google_service_account.tf_plan.email
}

output "deploy_workload_identity_provider" {
  description = "Full resource name to pass as `workload_identity_provider` in google-github-actions/auth for deploy workflows."
  value       = google_iam_workload_identity_pool_provider.deploy.name
}

output "plan_workload_identity_provider" {
  description = "Full resource name to pass as `workload_identity_provider` in google-github-actions/auth for the terraform-plan workflow."
  value       = google_iam_workload_identity_pool_provider.plan.name
}
