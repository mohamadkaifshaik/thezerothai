variable "project_id" {
  type = string
}

variable "runtime_service_account_email" {
  type = string
}

variable "secret_ids" {
  description = "Secret container names to create. Values are set manually (gcloud secrets versions add) — never in Terraform/state."
  type        = list(string)
  default     = []
}

variable "generated_secret_ids" {
  description = "Secret container names whose initial value Terraform generates (random_password, >= 32 bytes) and seeds as v1 — pure random material only, e.g. HMAC keys. See secret_ids for values set manually instead."
  type        = set(string)
  default     = []
}

variable "labels" {
  type    = map(string)
  default = {}
}
