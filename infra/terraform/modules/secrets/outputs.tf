output "secret_ids" {
  value = [for s in google_secret_manager_secret.secrets : s.secret_id]
}

output "generated_secret_ids" {
  description = "Map of requested name => actual Secret Manager secret_id, for the Terraform-generated secrets."
  value       = { for k, s in google_secret_manager_secret.generated : k => s.secret_id }
}
