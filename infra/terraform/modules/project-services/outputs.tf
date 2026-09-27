output "enabled_services" {
  description = "The set of API services enabled by this module, for use as a depends_on target elsewhere."
  value       = [for s in google_project_service.this : s.service]
}
