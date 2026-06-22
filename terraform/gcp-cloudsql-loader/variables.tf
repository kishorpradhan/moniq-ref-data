variable "gcp_project_id" {
  description = "GCP project that owns the Cloud Run Job, Scheduler job, and Cloud SQL instance."
  type        = string
  default     = "moniq-490803"
}

variable "gcp_region" {
  description = "GCP region for Cloud Run and Cloud Scheduler."
  type        = string
  default     = "us-central1"
}

variable "image_uri" {
  description = "Container image URI to deploy to the Cloud Run Job."
  type        = string
}

variable "cloud_run_job_name" {
  description = "Cloud Run Job name for the S3 to Cloud SQL loader."
  type        = string
  default     = "s3-to-cloudsql-daily-pricing"
}

variable "schema_job_name" {
  description = "Cloud Run Job name for one-off schema/table initialization."
  type        = string
  default     = "s3-to-cloudsql-schema-init"
}

variable "scheduler_job_name" {
  description = "Cloud Scheduler job name that triggers the Cloud Run Job."
  type        = string
  default     = "daily-s3-to-cloudsql-pricing"
}

variable "scheduler_cron" {
  description = "Cloud Scheduler cron expression."
  type        = string
  default     = "0 20 * * *"
}

variable "scheduler_time_zone" {
  description = "Cloud Scheduler timezone."
  type        = string
  default     = "America/New_York"
}

variable "runtime_service_account_email" {
  description = "Runtime service account used by the Cloud Run Job."
  type        = string
  default     = "s3-to-cloudsql-loader@moniq-490803.iam.gserviceaccount.com"
}

variable "scheduler_service_account_email" {
  description = "Service account used by Cloud Scheduler for OAuth when invoking the Cloud Run Job API."
  type        = string
  default     = "s3-to-cloudsql-scheduler@moniq-490803.iam.gserviceaccount.com"
}

variable "cloud_sql_connection_name" {
  description = "Cloud SQL connection name mounted into Cloud Run."
  type        = string
  default     = "moniq-490803:us-central1:moniq-postgres"
}

variable "cloud_sql_instance_name" {
  description = "Cloud SQL instance name that owns the target database."
  type        = string
  default     = "moniq-postgres"
}

variable "runtime_env" {
  description = "Non-secret runtime configuration for the S3 to Cloud SQL loader."
  type = object({
    s3_bucket     = string
    s3_prefix     = string
    days_ago      = number
    lookback_days = number
    job_timezone  = string
    db_name       = string
    db_user       = string
    db_schema     = string
    target_table  = string
    require_data  = bool
    batch_size    = number
  })
  default = {
    s3_bucket     = "moniq-lake"
    s3_prefix     = "raw/massive/day_aggs_v1"
    days_ago      = 1
    lookback_days = 5
    job_timezone  = "America/New_York"
    db_name       = "moniq_stocks"
    db_user       = "moniq_upload"
    db_schema     = "public"
    target_table  = "daily_pricing"
    require_data  = false
    batch_size    = 50000
  }
}

variable "secret_ids" {
  description = "Secret Manager secret IDs mounted into the Cloud Run Job. Values are secret names, not secret payloads."
  type = object({
    aws_access_key_id     = string
    aws_secret_access_key = string
    db_password           = string
  })
  default = {
    aws_access_key_id     = "aws-access-key-id"
    aws_secret_access_key = "aws-secret-access-key"
    db_password           = "moniq-upload-db-password"
  }
}

variable "cloud_run_resources" {
  description = "Cloud Run Job task resource limits."
  type = object({
    cpu    = string
    memory = string
  })
  default = {
    cpu    = "1"
    memory = "1Gi"
  }
}

variable "cloud_run_max_retries" {
  description = "Maximum retry attempts for one Cloud Run Job task."
  type        = number
  default     = 1
}

variable "cloud_run_task_timeout" {
  description = "Cloud Run Job task timeout."
  type        = string
  default     = "3600s"
}

variable "schema_job_task_timeout" {
  description = "Cloud Run Job task timeout for schema/table initialization."
  type        = string
  default     = "600s"
}

variable "labels" {
  description = "Labels applied to managed GCP resources."
  type        = map(string)
  default = {
    managed-by = "terraform"
    workload   = "s3-to-cloudsql-loader"
  }
}
