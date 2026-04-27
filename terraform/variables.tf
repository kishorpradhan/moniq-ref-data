variable "aws_region" {
  description = "AWS region for Glue, S3, and IAM resources."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional AWS CLI profile name to use locally."
  type        = string
  default     = null
}

variable "project_name" {
  description = "Short project identifier used in resource names."
  type        = string
  default     = "moniq-reference-data"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "dev"
}

variable "glue_database_name" {
  description = "Glue database name. Glue stores this as lowercase for Hive compatibility."
  type        = string
}

variable "glue_catalog_id" {
  description = "Optional Glue catalog ID. If null, AWS uses the current account ID."
  type        = string
  default     = null
}

variable "glue_database_description" {
  description = "Description for the Glue database."
  type        = string
  default     = "Glue database for Iceberg-backed reference data tables."
}

variable "glue_database_location_uri" {
  description = "Base S3 URI for the Glue database, for example s3://bucket/lake/database_name/."
  type        = string
}

variable "create_data_bucket" {
  description = "Whether Terraform should create the S3 bucket used by the Glue database base path."
  type        = bool
  default     = false
}

variable "data_bucket_name" {
  description = "S3 bucket name that stores the lake data."
  type        = string
}

variable "data_bucket_force_destroy" {
  description = "Whether to allow Terraform to delete a non-empty bucket."
  type        = bool
  default     = false
}

variable "enable_crawler_role" {
  description = "Whether to create an IAM role that AWS Glue crawlers can assume."
  type        = bool
  default     = true
}

variable "enable_job_role" {
  description = "Whether to create an IAM role for Glue jobs or boto3-driven catalog operations."
  type        = bool
  default     = true
}

variable "crawler_role_name" {
  description = "Optional explicit name for the Glue crawler IAM role."
  type        = string
  default     = null
}

variable "job_role_name" {
  description = "Optional explicit name for the Glue job IAM role."
  type        = string
  default     = null
}

variable "enable_emr_serverless" {
  description = "Whether to create EMR Serverless resources for Spark jobs."
  type        = bool
  default     = true
}

variable "emr_serverless_release_label" {
  description = "EMR Serverless release label for the Spark application."
  type        = string
  default     = "emr-7.12.0"
}

variable "emr_serverless_application_name" {
  description = "Optional explicit name for the EMR Serverless Spark application."
  type        = string
  default     = null
}

variable "emr_serverless_execution_role_name" {
  description = "Optional explicit name for the EMR Serverless runtime role."
  type        = string
  default     = null
}

variable "emr_serverless_auto_stop_idle_timeout_minutes" {
  description = "Auto-stop idle timeout for the EMR Serverless application."
  type        = number
  default     = 15
}

variable "emr_serverless_maximum_cpu" {
  description = "Maximum aggregate CPU capacity for the EMR Serverless application."
  type        = string
  default     = "16 vCPU"
}

variable "emr_serverless_maximum_memory" {
  description = "Maximum aggregate memory capacity for the EMR Serverless application."
  type        = string
  default     = "64 GB"
}

variable "emr_serverless_job_prefix" {
  description = "S3 prefix for uploaded EMR Serverless job artifacts."
  type        = string
  default     = "artifacts/emr-serverless/jobs"
}

variable "emr_serverless_log_prefix" {
  description = "S3 prefix for EMR Serverless application and job logs."
  type        = string
  default     = "logs/emr-serverless"
}

variable "daily_pricing_raw_input_path" {
  description = "Raw Massive daily aggregate input path passed to the daily pricing Spark job."
  type        = string
  default     = "s3://moniq-lake/raw/massive/day_aggs_v1/"
}

variable "daily_pricing_raw_prefix" {
  description = "Raw Massive daily aggregate S3 prefix without leading or trailing slash."
  type        = string
  default     = "raw/massive/day_aggs_v1"
}

variable "daily_pricing_warehouse_path" {
  description = "Iceberg warehouse path passed to the daily pricing Spark job."
  type        = string
  default     = "s3://moniq-lake/curated/"
}

variable "daily_pricing_backfill_max_concurrency" {
  description = "Maximum number of monthly daily pricing Spark jobs the Step Function runs concurrently."
  type        = number
  default     = 1
}

variable "daily_pricing_backfill_state_machine_name" {
  description = "Optional explicit name for the daily pricing backfill Step Functions state machine."
  type        = string
  default     = null
}

variable "daily_pricing_load_state_machine_name" {
  description = "Optional explicit name for the daily pricing load Step Functions state machine."
  type        = string
  default     = null
}

variable "daily_pricing_load_lookback_days" {
  description = "Default number of recent calendar days the daily staging Lambda checks for available Massive files."
  type        = number
  default     = 5
}

variable "enable_daily_pricing_load_schedule" {
  description = "Whether to schedule the daily pricing load Step Functions state machine."
  type        = bool
  default     = true
}

variable "daily_pricing_load_schedule_expression" {
  description = "EventBridge Scheduler expression for the daily pricing load state machine."
  type        = string
  default     = "cron(0 8 * * ? *)"
}

variable "daily_pricing_load_schedule_timezone" {
  description = "Timezone for the daily pricing load schedule."
  type        = string
  default     = "America/New_York"
}

variable "stage_massive_day_aggs_lambda_timeout_seconds" {
  description = "Timeout for the Lambda that stages Massive daily aggregate files."
  type        = number
  default     = 300
}

variable "stage_massive_day_aggs_lambda_memory_mb" {
  description = "Memory size for the Lambda that stages Massive daily aggregate files."
  type        = number
  default     = 512
}

variable "tags" {
  description = "Tags applied to supported AWS resources."
  type        = map(string)
  default = {
    managed_by = "terraform"
  }
}
