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

variable "protected_tag_prefixes" {
  description = "Tag prefixes whose images are never deleted by cleanup (KEEP wins over DELETE). `last-good` is the rollback image the promotion workflow tags; `v` keeps release images (vX.Y.Z). Each kept image costs roughly 14-27 MB of the 0.5 GB free storage (dev average incl. SBOM: ~13.5 MB)."
  type        = list(string)
  default     = ["last-good", "v"]
}
