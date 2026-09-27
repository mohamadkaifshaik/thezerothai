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

output "custom_domain_dns_records" {
  description = "DNS records to create at the registrar (Squarespace) for each custom domain."
  value       = module.firebase.custom_domain_dns_records
}

output "custom_domain_status" {
  value = module.firebase.custom_domain_status
}
