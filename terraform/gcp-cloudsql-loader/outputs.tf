output "cloud_run_job_name" {
  description = "Cloud Run Job name."
  value       = google_cloud_run_v2_job.loader.name
}

output "cloud_run_job_location" {
  description = "Cloud Run Job region."
  value       = google_cloud_run_v2_job.loader.location
}

output "scheduler_job_name" {
  description = "Cloud Scheduler job name."
  value       = google_cloud_scheduler_job.loader.name
}

output "scheduler_uri" {
  description = "Cloud Scheduler target URI."
  value       = local.scheduler_uri
}

output "runtime_env" {
  description = "Non-secret runtime environment deployed to Cloud Run."
  value       = local.cloud_run_env
}
