output "cloud_run_url" {
  value = module.cloud_run_api.url
}

output "artifact_registry_url" {
  value = module.artifact_registry.repository_url
}

output "ci_deploy_service_account_email" {
  value = module.iam.ci_deploy_service_account_email
}

output "tf_plan_service_account_email" {
  value = module.iam.tf_plan_service_account_email
}

output "deploy_workload_identity_provider" {
  value = module.iam.deploy_workload_identity_provider
}

output "plan_workload_identity_provider" {
  value = module.iam.plan_workload_identity_provider
}

output "media_bucket_name" {
  value = module.media_buckets.media_bucket_name
}

output "upload_bucket_name" {
  value = module.media_buckets.upload_bucket_name
}

output "hosting_default_url" {
  value = module.firebase.hosting_default_url
}

output "firestore_location" {
  value = module.firestore.location
}
