output "cloud_run_job_name" {
  description = "Cloud Run Job name."
  value       = google_cloud_run_v2_job.loader.name
}

output "cloud_run_job_location" {
  description = "Cloud Run Job region."
  value       = google_cloud_run_v2_job.loader.location
}

output "schema_job_name" {
  description = "Cloud Run Job name used to initialize the target schema/table."
  value       = google_cloud_run_v2_job.schema.name
}

output "database_name" {
  description = "Terraform-managed Cloud SQL database name."
  value       = google_sql_database.loader.name
}

output "target_table" {
  description = "Target table created by the schema initialization job."
  value       = "${var.runtime_env.db_schema}.${var.runtime_env.target_table}"
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
