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
  description = "Tag prefixes whose images are never deleted by cleanup (KEEP wins over DELETE). `last-good` is reserved for the rollback image the Option C promotion workflow will tag (no workflow creates it yet, so that policy is inert until PR 2); `serving` is a moving tag the promotion workflow will keep on the digest that currently serves (so dry-run pushes cannot push the serving image out of the repository, which the orchestrator requires before it will promote); `v` keeps release images (vX.Y.Z) forever, so prune old releases by hand when the repo nears the 0.5 GB free storage (measured dev average: ~13.5 MB per image incl. its SBOM manifest, i.e. roughly 35 kept releases)."
  type        = list(string)
  default     = ["last-good", "v", "serving"]

  validation {
    condition     = alltrue([for p in var.protected_tag_prefixes : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]*$", p))]) && length(distinct(var.protected_tag_prefixes)) == length(var.protected_tag_prefixes)
    error_message = "protected_tag_prefixes must be distinct, non-empty tag prefixes (an empty prefix would keep every tagged image and disable delete-tagged-after-30d)."
  }
}
