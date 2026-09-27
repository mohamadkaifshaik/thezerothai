variable "project_id" {
  type = string
}

variable "region" {
  description = "Must be a US region for GCS Always Free storage (us-west1, us-central1, us-east1). See CLAUDE.md."
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-west1", "us-central1", "us-east1"], var.region)
    error_message = "Media bucket region must be a free-tier US region: us-west1, us-central1, or us-east1."
  }
}

variable "runtime_service_account_email" {
  type = string
}

variable "cors_origins" {
  description = <<-EOT
    Allowed origins for signed PUT uploads. GCS CORS matches exact origins
    (no wildcard ports) — list local dev ports and the real Firebase Hosting
    domain(s) per env in terraform.tfvars.
  EOT
  type        = list(string)
  default     = ["http://localhost:5000", "http://localhost:8080"]
}

variable "labels" {
  type    = map(string)
  default = {}
}
