locals {
  stage_massive_day_aggs_lambda_name = "${local.name_prefix}-stage-massive-day-aggs"
  stage_massive_day_aggs_secret_name = "${local.name_prefix}/massive/flatfiles"

  daily_pricing_load_state_machine_name = coalesce(
    var.daily_pricing_load_state_machine_name,
    "${local.name_prefix}-daily-pricing-load",
  )
  daily_pricing_load_role_name      = "${local.daily_pricing_load_state_machine_name}-sfn"
  daily_pricing_load_log_group_name = "/aws/vendedlogs/states/${local.daily_pricing_load_state_machine_name}"
  daily_pricing_load_schedule_name  = "${local.daily_pricing_load_state_machine_name}-schedule"
}

data "archive_file" "stage_massive_day_aggs_lambda" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/stage_massive_day_aggs.py"
  output_path = "${path.module}/stage_massive_day_aggs_lambda.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_secretsmanager_secret" "massive_flatfiles" {
  name                    = local.stage_massive_day_aggs_secret_name
  description             = "Massive flat files S3-compatible credentials for daily reference data ingestion."
  recovery_window_in_days = 0
}

data "aws_iam_policy_document" "stage_massive_day_aggs_access" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}/${trim(var.daily_pricing_raw_prefix, "/")}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.massive_flatfiles.arn]
  }
}

resource "aws_iam_role" "stage_massive_day_aggs" {
  name               = "${local.stage_massive_day_aggs_lambda_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy" "stage_massive_day_aggs" {
  name   = "${local.stage_massive_day_aggs_lambda_name}-inline"
  role   = aws_iam_role.stage_massive_day_aggs.id
  policy = data.aws_iam_policy_document.stage_massive_day_aggs_access.json
}

resource "aws_cloudwatch_log_group" "stage_massive_day_aggs" {
  name              = "/aws/lambda/${local.stage_massive_day_aggs_lambda_name}"
  retention_in_days = 30
}

resource "aws_lambda_function" "stage_massive_day_aggs" {
  function_name    = local.stage_massive_day_aggs_lambda_name
  role             = aws_iam_role.stage_massive_day_aggs.arn
  runtime          = "python3.12"
  handler          = "stage_massive_day_aggs.handler"
  filename         = data.archive_file.stage_massive_day_aggs_lambda.output_path
  source_code_hash = data.archive_file.stage_massive_day_aggs_lambda.output_base64sha256
  timeout          = var.stage_massive_day_aggs_lambda_timeout_seconds
  memory_size      = var.stage_massive_day_aggs_lambda_memory_mb

  environment {
    variables = {
      TARGET_BUCKET         = var.data_bucket_name
      RAW_PREFIX            = var.daily_pricing_raw_prefix
      MASSIVE_SECRET_ID     = aws_secretsmanager_secret.massive_flatfiles.arn
      DEFAULT_LOOKBACK_DAYS = tostring(var.daily_pricing_load_lookback_days)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.stage_massive_day_aggs,
    aws_iam_role_policy.stage_massive_day_aggs
  ]
}

data "aws_iam_policy_document" "daily_pricing_load_access" {
  statement {
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [aws_lambda_function.stage_massive_day_aggs.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "emr-serverless:StartJobRun",
      "emr-serverless:GetJobRun",
      "emr-serverless:CancelJobRun"
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [local.emr_serverless_execution_role_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["emr-serverless.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "events:DescribeRule",
      "events:PutRule",
      "events:PutTargets"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:CreateLogStream",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutLogEvents",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups"
    ]
    resources = ["*"]
  }
}

resource "aws_cloudwatch_log_group" "daily_pricing_load" {
  name              = local.daily_pricing_load_log_group_name
  retention_in_days = 30
}

resource "aws_iam_role" "daily_pricing_load" {
  name               = local.daily_pricing_load_role_name
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume_role.json
}

resource "aws_iam_role_policy" "daily_pricing_load" {
  name   = "${local.daily_pricing_load_role_name}-inline"
  role   = aws_iam_role.daily_pricing_load.id
  policy = data.aws_iam_policy_document.daily_pricing_load_access.json
}

resource "aws_sfn_state_machine" "daily_pricing_load" {
  name     = local.daily_pricing_load_state_machine_name
  role_arn = aws_iam_role.daily_pricing_load.arn

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.daily_pricing_load.arn}:*"
  }

  definition = jsonencode({
    StartAt = "StageMassiveDayAggs"
    States = {
      StageMassiveDayAggs = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.stage_massive_day_aggs.arn
          "Payload.$"  = "$"
        }
        ResultSelector = {
          "status.$"           = "$.Payload.status"
          "available_dates.$"  = "$.Payload.available_dates"
          "missing_dates.$"    = "$.Payload.missing_dates"
          "raw_paths.$"        = "$.Payload.raw_paths"
          "input_path.$"       = "$.Payload.input_path"
          "daily_start_date.$" = "$.Payload.daily_start_date"
          "daily_end_date.$"   = "$.Payload.daily_end_date"
        }
        ResultPath = "$.stage"
        Next       = "HasStagedData"
      }
      HasStagedData = {
        Type = "Choice"
        Choices = [
          {
            Variable     = "$.stage.status"
            StringEquals = "NO_DATA"
            Next         = "NoData"
          }
        ]
        Default = "LoadDailyPricing"
      }
      NoData = {
        Type = "Succeed"
      }
      LoadDailyPricing = {
        Type       = "Task"
        Resource   = "arn:aws:states:::emr-serverless:startJobRun.sync"
        ResultPath = "$.daily_pricing_job"
        Parameters = {
          ApplicationId    = local.emr_serverless_application_id
          ExecutionRoleArn = local.emr_serverless_execution_role_arn
          JobDriver = {
            SparkSubmit = {
              EntryPoint              = local.emr_serverless_job_script_s3_uri
              SparkSubmitParameters   = "--py-files ${local.emr_serverless_common_zip_s3_uri}"
              "EntryPointArguments.$" = "States.Array('--input-path', $.stage.input_path, '--warehouse-path', '${var.daily_pricing_warehouse_path}', '--database', '${var.glue_database_name}', '--table', 'daily_pricing', '--start-date', $.stage.daily_start_date, '--end-date', $.stage.daily_end_date, '--write-disposition', 'overwrite_partitions')"
            }
          }
          ConfigurationOverrides = {
            MonitoringConfiguration = {
              S3MonitoringConfiguration = {
                LogUri = local.emr_serverless_log_uri
              }
            }
          }
        }
        Next = "LoadPricing52WeekMetrics"
      }
      LoadPricing52WeekMetrics = {
        Type       = "Task"
        Resource   = "arn:aws:states:::emr-serverless:startJobRun.sync"
        ResultPath = "$.pricing_52_week_metrics_job"
        Parameters = {
          ApplicationId    = local.emr_serverless_application_id
          ExecutionRoleArn = local.emr_serverless_execution_role_arn
          JobDriver = {
            SparkSubmit = {
              EntryPoint              = local.emr_serverless_metrics_job_script_s3_uri
              SparkSubmitParameters   = "--py-files ${local.emr_serverless_common_zip_s3_uri}"
              "EntryPointArguments.$" = "States.Array('--warehouse-path', '${var.daily_pricing_warehouse_path}', '--database', '${var.glue_database_name}', '--source-table', 'daily_pricing', '--target-table', 'pricing_52_week_metrics', '--start-date', $.stage.daily_start_date, '--end-date', $.stage.daily_end_date, '--date-range-mode', 'daily_impacted')"
            }
          }
          ConfigurationOverrides = {
            MonitoringConfiguration = {
              S3MonitoringConfiguration = {
                LogUri = local.emr_serverless_log_uri
              }
            }
          }
        }
        End = true
      }
    }
  })
}

data "aws_iam_policy_document" "daily_pricing_load_schedule_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "daily_pricing_load_schedule_access" {
  statement {
    effect = "Allow"
    actions = [
      "states:StartExecution"
    ]
    resources = [aws_sfn_state_machine.daily_pricing_load.arn]
  }
}

resource "aws_iam_role" "daily_pricing_load_schedule" {
  count = var.enable_daily_pricing_load_schedule ? 1 : 0

  name               = "${local.daily_pricing_load_schedule_name}-role"
  assume_role_policy = data.aws_iam_policy_document.daily_pricing_load_schedule_assume_role.json
}

resource "aws_iam_role_policy" "daily_pricing_load_schedule" {
  count = var.enable_daily_pricing_load_schedule ? 1 : 0

  name   = "${local.daily_pricing_load_schedule_name}-inline"
  role   = aws_iam_role.daily_pricing_load_schedule[0].id
  policy = data.aws_iam_policy_document.daily_pricing_load_schedule_access.json
}

resource "aws_scheduler_schedule" "daily_pricing_load" {
  count = var.enable_daily_pricing_load_schedule ? 1 : 0

  name                         = local.daily_pricing_load_schedule_name
  description                  = "Runs the daily pricing load workflow at 8 AM Eastern time."
  schedule_expression          = var.daily_pricing_load_schedule_expression
  schedule_expression_timezone = var.daily_pricing_load_schedule_timezone
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_sfn_state_machine.daily_pricing_load.arn
    role_arn = aws_iam_role.daily_pricing_load_schedule[0].arn
    input = jsonencode({
      lookback_days = var.daily_pricing_load_lookback_days
    })
  }
}
