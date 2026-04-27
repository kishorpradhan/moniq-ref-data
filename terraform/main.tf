locals {
  name_prefix = "${var.project_name}-${var.environment}"

  crawler_role_name               = coalesce(var.crawler_role_name, "${local.name_prefix}-glue-crawler")
  job_role_name                   = coalesce(var.job_role_name, "${local.name_prefix}-glue-job")
  emr_serverless_application_name = coalesce(var.emr_serverless_application_name, "${local.name_prefix}-spark")
  emr_serverless_execution_role_name = coalesce(
    var.emr_serverless_execution_role_name,
    "${local.name_prefix}-emr-serverless-runtime",
  )

  crawler_role_arn                         = var.enable_crawler_role ? aws_iam_role.glue_crawler[0].arn : null
  job_role_arn                             = var.enable_job_role ? aws_iam_role.glue_job[0].arn : null
  emr_serverless_application_id            = var.enable_emr_serverless ? aws_emrserverless_application.spark[0].id : null
  emr_serverless_execution_role_arn        = var.enable_emr_serverless ? aws_iam_role.emr_serverless_runtime[0].arn : null
  emr_serverless_job_script_key            = "${trim(var.emr_serverless_job_prefix, "/")}/load_daily_pricing.py"
  emr_serverless_job_script_s3_uri         = "s3://${var.data_bucket_name}/${local.emr_serverless_job_script_key}"
  emr_serverless_metrics_job_script_key    = "${trim(var.emr_serverless_job_prefix, "/")}/load_pricing_52_week_metrics.py"
  emr_serverless_metrics_job_script_s3_uri = "s3://${var.data_bucket_name}/${local.emr_serverless_metrics_job_script_key}"
  emr_serverless_common_zip_key            = "${trim(var.emr_serverless_job_prefix, "/")}/common.zip"
  emr_serverless_common_zip_s3_uri         = "s3://${var.data_bucket_name}/${local.emr_serverless_common_zip_key}"
  emr_serverless_log_uri                   = "s3://${var.data_bucket_name}/${trim(var.emr_serverless_log_prefix, "/")}/"
}

resource "aws_s3_bucket" "data" {
  count = var.create_data_bucket ? 1 : 0

  bucket        = var.data_bucket_name
  force_destroy = var.data_bucket_force_destroy
}

resource "aws_s3_bucket_versioning" "data" {
  count = var.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  count = var.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_glue_catalog_database" "this" {
  catalog_id   = var.glue_catalog_id
  name         = var.glue_database_name
  description  = var.glue_database_description
  location_uri = var.glue_database_location_uri
}

data "aws_iam_policy_document" "glue_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "emr_serverless_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["emr-serverless.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "crawler_access" {
  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchUpdatePartition"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}/*"
    ]
  }
}

data "aws_iam_policy_document" "job_access" {
  statement {
    effect = "Allow"
    actions = [
      "glue:CreateDatabase",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:UpdateDatabase",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchUpdatePartition",
      "glue:StartCrawler",
      "glue:GetCrawler",
      "glue:GetCrawlers"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}/*"
    ]
  }
}

data "aws_iam_policy_document" "emr_serverless_runtime_access" {
  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchCreatePartition",
      "glue:BatchDeletePartition",
      "glue:BatchUpdatePartition",
      "glue:CreateTable",
      "glue:DeleteTable",
      "glue:UpdateTable"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "arn:aws:s3:::${var.data_bucket_name}/*"
    ]
  }
}

resource "aws_iam_role" "glue_crawler" {
  count = var.enable_crawler_role ? 1 : 0

  name               = local.crawler_role_name
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}

resource "aws_iam_role_policy" "glue_crawler" {
  count = var.enable_crawler_role ? 1 : 0

  name   = "${local.crawler_role_name}-inline"
  role   = aws_iam_role.glue_crawler[0].id
  policy = data.aws_iam_policy_document.crawler_access.json
}

resource "aws_iam_role" "glue_job" {
  count = var.enable_job_role ? 1 : 0

  name               = local.job_role_name
  assume_role_policy = data.aws_iam_policy_document.glue_assume_role.json
}

resource "aws_iam_role_policy" "glue_job" {
  count = var.enable_job_role ? 1 : 0

  name   = "${local.job_role_name}-inline"
  role   = aws_iam_role.glue_job[0].id
  policy = data.aws_iam_policy_document.job_access.json
}

resource "aws_iam_role" "emr_serverless_runtime" {
  count = var.enable_emr_serverless ? 1 : 0

  name               = local.emr_serverless_execution_role_name
  assume_role_policy = data.aws_iam_policy_document.emr_serverless_assume_role.json
}

resource "aws_iam_role_policy" "emr_serverless_runtime" {
  count = var.enable_emr_serverless ? 1 : 0

  name   = "${local.emr_serverless_execution_role_name}-inline"
  role   = aws_iam_role.emr_serverless_runtime[0].id
  policy = data.aws_iam_policy_document.emr_serverless_runtime_access.json
}

resource "aws_emrserverless_application" "spark" {
  count = var.enable_emr_serverless ? 1 : 0

  name          = local.emr_serverless_application_name
  release_label = var.emr_serverless_release_label
  type          = "SPARK"

  auto_start_configuration {
    enabled = true
  }

  auto_stop_configuration {
    enabled              = true
    idle_timeout_minutes = var.emr_serverless_auto_stop_idle_timeout_minutes
  }

  maximum_capacity {
    cpu    = var.emr_serverless_maximum_cpu
    memory = var.emr_serverless_maximum_memory
  }
}

data "archive_file" "emr_serverless_common" {
  type        = "zip"
  output_path = "${path.module}/common.zip"

  source {
    content  = file("${path.module}/../common/__init__.py")
    filename = "common/__init__.py"
  }

  source {
    content  = file("${path.module}/../common/io.py")
    filename = "common/io.py"
  }

  source {
    content  = file("${path.module}/../common/spark.py")
    filename = "common/spark.py"
  }
}

resource "aws_s3_object" "emr_serverless_load_daily_pricing" {
  count = var.enable_emr_serverless ? 1 : 0

  bucket = var.data_bucket_name
  key    = local.emr_serverless_job_script_key
  source = "${path.module}/../jobs/load_daily_pricing.py"
  etag   = filemd5("${path.module}/../jobs/load_daily_pricing.py")
}

resource "aws_s3_object" "emr_serverless_load_pricing_52_week_metrics" {
  count = var.enable_emr_serverless ? 1 : 0

  bucket = var.data_bucket_name
  key    = local.emr_serverless_metrics_job_script_key
  source = "${path.module}/../jobs/load_pricing_52_week_metrics.py"
  etag   = filemd5("${path.module}/../jobs/load_pricing_52_week_metrics.py")
}

resource "aws_s3_object" "emr_serverless_common" {
  count = var.enable_emr_serverless ? 1 : 0

  bucket = var.data_bucket_name
  key    = local.emr_serverless_common_zip_key
  source = data.archive_file.emr_serverless_common.output_path
  etag   = data.archive_file.emr_serverless_common.output_md5
}
