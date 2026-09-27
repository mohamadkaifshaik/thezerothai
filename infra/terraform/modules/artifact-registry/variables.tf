variable "project_id" {
  type = string
}

variable "region" {
  description = "Artifact Registry region (asia-south1 per CLAUDE.md, colocated with Cloud Run)."
  type        = string
  default     = "asia-south1"
}

variable "repository_id" {
  type    = string
  default = "api"
}

variable "env" {
  type = string
}

variable "labels" {
  type    = map(string)
  default = {}
}
