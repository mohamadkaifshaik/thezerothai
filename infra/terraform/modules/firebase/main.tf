// Adds Firebase to the GCP project (Firebase IS a GCP project, this just
// turns on the Firebase-specific surface: Auth, Hosting, FCM, Crashlytics,
// App Check) plus the client app registrations and one Hosting site.
// Auth providers (Email/Password, Google, Apple — NOT phone/SMS, it's
// billed per SMS) are enabled once via the Firebase console/CLI, not
// Terraform — the identitytoolkit Terraform surface for provider config is
// still limited/beta and not worth fighting for a one-time setting.

resource "google_firebase_project" "default" {
  provider = google-beta
  project  = var.project_id
}

resource "google_firebase_web_app" "default" {
  provider     = google-beta
  project      = var.project_id
  display_name = "dzeroth web (${var.env})"

  depends_on = [google_firebase_project.default]
}

resource "google_firebase_android_app" "default" {
  provider     = google-beta
  project      = var.project_id
  display_name = "dzeroth android (${var.env})"
  package_name = var.android_package_name

  depends_on = [google_firebase_project.default]
}

resource "google_firebase_apple_app" "default" {
  provider     = google-beta
  project      = var.project_id
  display_name = "dzeroth ios (${var.env})"
  bundle_id    = var.ios_bundle_id

  depends_on = [google_firebase_project.default]
}

resource "google_firebase_hosting_site" "default" {
  provider = google-beta
  project  = var.project_id
  site_id  = var.hosting_site_id

  depends_on = [google_firebase_project.default]
}

// Custom domains on the Hosting site: $0, with a managed TLS certificate on the same CDN. DNS
// for dzeroth.com lives at Squarespace, which has no API, so records are added by hand from the
// `custom_domain_dns_records` output. wait_dns_verification = false keeps `apply` from blocking
// while DNS propagates; Hosting keeps checking and issues the certificate once records resolve.
resource "google_firebase_hosting_custom_domain" "this" {
  provider = google-beta
  for_each = var.custom_domains

  project               = var.project_id
  site_id               = google_firebase_hosting_site.default.site_id
  custom_domain         = each.key
  redirect_target       = each.value.redirect_to
  wait_dns_verification = false
}

// App Check: register the web app for reCAPTCHA v3 enforcement, once a site
// key/secret exists (register at https://www.google.com/recaptcha/admin
// first — a one-time manual step, see handoff notes). Disabled by default so
// bootstrap `apply` doesn't require a secret that can't exist yet.
// Android (Play Integrity) / iOS (App Attest) providers are attached
// client-side via the Firebase SDK + console toggle; those Terraform
// resources need enrollment tokens that don't exist until the client apps
// first build, so they stay a manual console step too.
resource "google_firebase_app_check_recaptcha_v3_config" "web" {
  count = var.enable_recaptcha_app_check ? 1 : 0

  provider    = google-beta
  project     = var.project_id
  app_id      = google_firebase_web_app.default.app_id
  site_secret = var.recaptcha_v3_site_secret
  token_ttl   = "3600s"
}
