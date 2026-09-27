variable "project_number" {
  description = <<-EOT
    GCP project NUMBER (not the project ID string) that owns these keys, e.g.
    data.google_project.this.number. google_apikeys_key.project reads/stores
    the numeric project number and is ForceNew — passing the project ID
    string here would plan a destroy+recreate of a live, already-shipped key.
  EOT
  type        = string
}

# Firebase auto-creates these three keys the first time you add a web/Android/iOS
# app to a project. Terraform can't create or discover them (there is no
# google_apikeys_key data source, and creating a *new* key would leave the
# already-shipped app builds pointing at the old, still-unrestricted one) — it
# only brings the existing ones under management via `import` blocks in the
# calling env. Find the UIDs with:
#   gcloud services api-keys list --project=<project_id> --format="table(uid,displayName)"
variable "browser_key_uid" {
  description = "UID of the Firebase-auto-created browser API key."
  type        = string
}

variable "android_key_uid" {
  description = "UID of the Firebase-auto-created Android API key."
  type        = string
}

variable "ios_key_uid" {
  description = "UID of the Firebase-auto-created iOS API key."
  type        = string
}

variable "browser_allowed_referrers" {
  description = "HTTP referrer patterns allowed to use the browser key (e.g. \"https://example.com/*\")."
  type        = list(string)
}

variable "browser_api_targets" {
  description = "Google API service names the browser key may call. Keep this to what the web app's Firebase SDKs actually use (security audit M3)."
  type        = list(string)
}

variable "android_api_targets" {
  description = "Google API service names the Android key may call."
  type        = list(string)
}

variable "ios_api_targets" {
  description = "Google API service names the iOS key may call."
  type        = list(string)
}

variable "ios_bundle_id" {
  description = "iOS bundle ID allowed to use the iOS key."
  type        = string
}

variable "android_allowed_applications" {
  description = <<-EOT
    (package_name, sha1_fingerprint) pairs allowed to use the Android key.
    Empty by default: we don't have a Play App Signing certificate yet (no Play
    Console listing exists to sign a release build). Fill this in once one
    does. Note this is the SHA-1 fingerprint, NOT the SHA-256 Firebase asks for
    elsewhere (google-services.json / App Check) — API key Android
    restrictions are SHA-1 only:
      - Play App Signing cert (after the app is created in Play Console):
        Play Console -> Setup -> App integrity -> App signing key certificate.
      - Local debug builds (for testing only, never for the restriction itself):
        keytool -list -v -keystore %USERPROFILE%\.android\debug.keystore -alias androiddebugkey -storepass android
    Until this is set, the Android key has NO app restriction — only the
    api_targets trim applies (see docs/runbooks/cloud-bootstrap.md).
  EOT
  type = list(object({
    package_name     = string
    sha1_fingerprint = string
  }))
  default = []
}
