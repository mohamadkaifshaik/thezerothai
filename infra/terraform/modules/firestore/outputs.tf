output "database_name" {
  description = "Firestore database name (always \"(default)\" at Stage 0)."
  value       = google_firestore_database.default.name
}

output "location" {
  value = google_firestore_database.default.location_id
}
