variable "project_id" {
  type = string
}

variable "env" {
  type = string
}

variable "android_package_name" {
  type    = string
  default = "ai.thezeroth.app"
}

variable "ios_bundle_id" {
  type    = string
  default = "ai.thezeroth.app"
}

variable "hosting_site_id" {
  description = "Firebase Hosting site ID. Must be globally unique across all Firebase projects."
  type        = string
}

variable "enable_recaptcha_app_check" {
  description = "Set true once a reCAPTCHA v3 site key/secret has been registered (manual, one-time)."
  type        = bool
  default     = false
}

variable "recaptcha_v3_site_secret" {
  description = "reCAPTCHA v3 secret key, from https://www.google.com/recaptcha/admin. Only needed if enable_recaptcha_app_check = true."
  type        = string
  default     = ""
  sensitive   = true
}

variable "custom_domains" {
  description = "Custom domains for the Hosting site: domain => { redirect_to = null (serve the site) or another domain to 301 to }."
  type = map(object({
    redirect_to = optional(string)
  }))
  default = {}
}
