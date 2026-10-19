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

variable "keep_recent_versions" {
  description = "keep-last-N: the N newest versions per package are always kept. ko pushes an image and its SBOM manifest as two versions, so N counts both."
  type        = number
  default     = 3
  validation {
    condition     = var.keep_recent_versions >= 3 && floor(var.keep_recent_versions) == var.keep_recent_versions
    error_message = "keep_recent_versions must be an integer >= 3."
  }
}

variable "tagged_retention_days" {
  description = "Tagged versions older than this are deleted unless a KEEP policy matches (last-good, serving, v*, the newest N versions). 30 keeps the original behaviour."
  type        = number
  default     = 30
  validation {
    condition     = var.tagged_retention_days >= 1 && floor(var.tagged_retention_days) == var.tagged_retention_days
    error_message = "tagged_retention_days must be an integer >= 1."
  }
}

variable "cleanup_policy_dry_run" {
  description = "When true, cleanup policies are evaluated and logged (audit log) but nothing is deleted."
  type        = bool
  default     = false
}
