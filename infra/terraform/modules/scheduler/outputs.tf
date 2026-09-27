output "job_names" {
  value = [for j in google_cloud_scheduler_job.jobs : j.name]
}
