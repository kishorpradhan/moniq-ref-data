output "glue_database_name" {
  description = "Glue database name."
  value       = aws_glue_catalog_database.this.name
}

output "glue_catalog_id" {
  description = "Effective Glue catalog ID."
  value       = aws_glue_catalog_database.this.catalog_id
}

output "glue_database_location_uri" {
  description = "Base S3 URI configured on the Glue database."
  value       = aws_glue_catalog_database.this.location_uri
}

output "data_bucket_name" {
  description = "S3 bucket storing the lake data."
  value       = var.data_bucket_name
}

output "glue_crawler_role_arn" {
  description = "IAM role ARN for Glue crawlers, if enabled."
  value       = local.crawler_role_arn
}

output "glue_job_role_arn" {
  description = "IAM role ARN for Glue jobs or boto3-driven catalog operations, if enabled."
  value       = local.job_role_arn
}

output "emr_serverless_application_id" {
  description = "EMR Serverless Spark application ID, if enabled."
  value       = local.emr_serverless_application_id
}

output "emr_serverless_execution_role_arn" {
  description = "EMR Serverless runtime role ARN, if enabled."
  value       = local.emr_serverless_execution_role_arn
}

output "emr_serverless_job_script_s3_uri" {
  description = "S3 URI for the uploaded EMR Serverless daily pricing job script."
  value       = local.emr_serverless_job_script_s3_uri
}

output "emr_serverless_metrics_job_script_s3_uri" {
  description = "S3 URI for the uploaded EMR Serverless 52-week pricing metrics job script."
  value       = local.emr_serverless_metrics_job_script_s3_uri
}

output "emr_serverless_common_zip_s3_uri" {
  description = "S3 URI for the uploaded EMR Serverless common Python package zip."
  value       = local.emr_serverless_common_zip_s3_uri
}

output "emr_serverless_log_uri" {
  description = "S3 URI prefix for EMR Serverless logs."
  value       = local.emr_serverless_log_uri
}

output "daily_pricing_backfill_state_machine_arn" {
  description = "ARN for the daily pricing backfill Step Functions state machine, if enabled."
  value       = var.enable_emr_serverless ? aws_sfn_state_machine.daily_pricing_backfill[0].arn : null
}

output "daily_pricing_backfill_log_group_name" {
  description = "CloudWatch Logs group for daily pricing backfill Step Functions execution history, if enabled."
  value       = var.enable_emr_serverless ? aws_cloudwatch_log_group.daily_pricing_backfill[0].name : null
}

output "stage_massive_day_aggs_lambda_name" {
  description = "Lambda function that stages Massive daily aggregate files into raw S3."
  value       = aws_lambda_function.stage_massive_day_aggs.function_name
}

output "massive_flatfiles_secret_name" {
  description = "Secrets Manager secret name that should contain Massive flat files credentials."
  value       = aws_secretsmanager_secret.massive_flatfiles.name
}

output "daily_pricing_load_state_machine_arn" {
  description = "ARN for the daily pricing load Step Functions state machine."
  value       = aws_sfn_state_machine.daily_pricing_load.arn
}

output "daily_pricing_load_log_group_name" {
  description = "CloudWatch Logs group for daily pricing load Step Functions execution history."
  value       = aws_cloudwatch_log_group.daily_pricing_load.name
}

output "daily_pricing_load_schedule_name" {
  description = "EventBridge Scheduler schedule for the daily pricing load state machine, if enabled."
  value       = var.enable_daily_pricing_load_schedule ? aws_scheduler_schedule.daily_pricing_load[0].name : null
}
