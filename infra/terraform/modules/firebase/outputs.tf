output "web_app_id" {
  value = google_firebase_web_app.default.app_id
}

output "android_app_id" {
  value = google_firebase_android_app.default.app_id
}

output "ios_app_id" {
  value = google_firebase_apple_app.default.app_id
}

output "hosting_site_id" {
  value = google_firebase_hosting_site.default.site_id
}

output "hosting_default_url" {
  value = "https://${google_firebase_hosting_site.default.site_id}.web.app"
}
