variable "project_id" {
  type = string
}

variable "env" {
  description = "Environment name, e.g. \"dev\" or \"prod\"."
  type        = string
}

variable "github_repo" {
  description = "GitHub repo allowed to federate, as \"owner/name\" (e.g. \"acme/thezerothai\")."
  type        = string
}

variable "deploy_ref_condition" {
  description = <<-EOT
    CEL fragment (no surrounding parens) that, together with the repository
    check, gates who can mint a deploy token for this env. Examples:
      dev:  "assertion.ref == 'refs/heads/main'"
      prod: "assertion.ref.startsWith('refs/tags/v')"
  EOT
  type        = string
}

variable "deploy_ref_description" {
  description = "Human-readable summary of deploy_ref_condition, for the WIF provider display name."
  type        = string
  default     = "restricted ref"
}

variable "deploy_extra_conditions" {
  description = <<-EOT
    Additional CEL fragments ANDed into the deploy WIF provider's attribute_condition, beyond the
    repository + ref checks. Use this to pin `assertion.job_workflow_ref` (so only the exact
    reusable workflow file — not a modified copy on some other ref — can mint a token) and
    `assertion.environment` (so a token can only be minted for a job that declares one of the
    GitHub Environments this deploy actually uses, including the ones with required reviewers).
    Example (prod):
      [
        "assertion.job_workflow_ref.startsWith('org/repo/.github/workflows/release-prod.yml@refs/tags/v')",
        "assertion.environment in ['prod', 'production-traffic-10', 'production-traffic-100']",
      ]
  EOT
  type        = list(string)
  default     = []
}
