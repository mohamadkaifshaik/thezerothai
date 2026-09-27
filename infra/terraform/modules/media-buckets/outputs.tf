output "upload_bucket_name" {
  value = google_storage_bucket.upload.name
}

output "media_bucket_name" {
  value = google_storage_bucket.media.name
}

output "media_bucket_public_url" {
  value = "https://storage.googleapis.com/${google_storage_bucket.media.name}"
}
