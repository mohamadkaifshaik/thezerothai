output "browser_key_name" {
  value = google_apikeys_key.browser.name
}

output "android_key_name" {
  value = google_apikeys_key.android.name
}

output "ios_key_name" {
  value = google_apikeys_key.ios.name
}
