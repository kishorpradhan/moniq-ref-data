data "aws_caller_identity" "current" {}

locals {
  daily_pricing_backfill_state_machine_name = coalesce(
    var.daily_pricing_backfill_state_machine_name,
    "${local.name_prefix}-daily-pricing-backfill",
  )
  daily_pricing_backfill_role_name      = "${local.daily_pricing_backfill_state_machine_name}-sfn"
  daily_pricing_backfill_log_group_name = "/aws/vendedlogs/states/${local.daily_pricing_backfill_state_machine_name}"
}

data "aws_iam_policy_document" "step_functions_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "daily_pricing_backfill_access" {
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

resource "aws_cloudwatch_log_group" "daily_pricing_backfill" {
  count = var.enable_emr_serverless ? 1 : 0

  name              = local.daily_pricing_backfill_log_group_name
  retention_in_days = 30
}

resource "aws_iam_role" "daily_pricing_backfill" {
  count = var.enable_emr_serverless ? 1 : 0

  name               = local.daily_pricing_backfill_role_name
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume_role.json
}

resource "aws_iam_role_policy" "daily_pricing_backfill" {
  count = var.enable_emr_serverless ? 1 : 0

  name   = "${local.daily_pricing_backfill_role_name}-inline"
  role   = aws_iam_role.daily_pricing_backfill[0].id
  policy = data.aws_iam_policy_document.daily_pricing_backfill_access.json
}

resource "aws_sfn_state_machine" "daily_pricing_backfill" {
  count = var.enable_emr_serverless ? 1 : 0

  name     = local.daily_pricing_backfill_state_machine_name
  role_arn = aws_iam_role.daily_pricing_backfill[0].arn

  logging_configuration {
    include_execution_data = true
    level                  = "ALL"
    log_destination        = "${aws_cloudwatch_log_group.daily_pricing_backfill[0].arn}:*"
  }

  definition = jsonencode({
    StartAt = "RunDailyPricingRanges"
    States = {
      RunDailyPricingRanges = {
        Type           = "Map"
        ItemsPath      = "$.months"
        MaxConcurrency = var.daily_pricing_backfill_max_concurrency
        Iterator = {
          StartAt = "RunDailyPricingRange"
          States = {
            RunDailyPricingRange = {
              Type       = "Task"
              Resource   = "arn:aws:states:::emr-serverless:startJobRun.sync"
              ResultPath = "$.job"
              Catch = [
                {
                  ErrorEquals = ["States.ALL"]
                  ResultPath  = "$.error"
                  Next        = "MarkDailyPricingRangeFailed"
                }
              ]
              Parameters = {
                ApplicationId    = local.emr_serverless_application_id
                ExecutionRoleArn = local.emr_serverless_execution_role_arn
                JobDriver = {
                  SparkSubmit = {
                    EntryPoint              = local.emr_serverless_job_script_s3_uri
                    SparkSubmitParameters   = "--py-files ${local.emr_serverless_common_zip_s3_uri}"
                    "EntryPointArguments.$" = "States.Array('--input-path', $.input_path, '--warehouse-path', '${var.daily_pricing_warehouse_path}', '--database', '${var.glue_database_name}', '--table', 'daily_pricing', '--start-date', $.start_date, '--end-date', $.end_date, '--write-disposition', 'overwrite_partitions')"
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
              Next = "MarkDailyPricingRangeSucceeded"
            }
            MarkDailyPricingRangeSucceeded = {
              Type = "Pass"
              Parameters = {
                status = "SUCCEEDED"
                range = {
                  "input_path.$" = "$.input_path"
                  "start_date.$" = "$.start_date"
                  "end_date.$"   = "$.end_date"
                }
                "job.$" = "$.job"
              }
              End = true
            }
            MarkDailyPricingRangeFailed = {
              Type = "Pass"
              Parameters = {
                status = "FAILED"
                range = {
                  "input_path.$" = "$.input_path"
                  "start_date.$" = "$.start_date"
                  "end_date.$"   = "$.end_date"
                }
                "error.$" = "$.error"
              }
              End = true
            }
          }
        }
        End = true
      }
    }
  })
}
