locals {
  cloud_run_env = {
    S3_BUCKET                 = var.runtime_env.s3_bucket
    S3_PREFIX                 = var.runtime_env.s3_prefix
    DAYS_AGO                  = tostring(var.runtime_env.days_ago)
    LOOKBACK_DAYS             = tostring(var.runtime_env.lookback_days)
    JOB_TIMEZONE              = var.runtime_env.job_timezone
    CLOUD_SQL_CONNECTION_NAME = var.cloud_sql_connection_name
    DB_NAME                   = var.runtime_env.db_name
    DB_USER                   = var.runtime_env.db_user
    DB_SCHEMA                 = var.runtime_env.db_schema
    TARGET_TABLE              = var.runtime_env.target_table
    REQUIRE_DATA              = tostring(var.runtime_env.require_data)
    BATCH_SIZE                = tostring(var.runtime_env.batch_size)
  }

  scheduler_uri = "https://${var.gcp_region}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${var.gcp_project_id}/jobs/${var.cloud_run_job_name}:run"

  schema_job_trigger = sha256(jsonencode({
    image_uri                 = var.image_uri
    cloud_sql_connection_name = var.cloud_sql_connection_name
    db_name                   = var.runtime_env.db_name
    db_user                   = var.runtime_env.db_user
    db_schema                 = var.runtime_env.db_schema
    target_table              = var.runtime_env.target_table
    db_password_secret        = var.secret_ids.db_password
  }))
}

resource "google_sql_database" "loader" {
  project  = var.gcp_project_id
  instance = var.cloud_sql_instance_name
  name     = var.runtime_env.db_name

  deletion_policy = "ABANDON"
}

resource "google_cloud_run_v2_job" "loader" {
  name                = var.cloud_run_job_name
  project             = var.gcp_project_id
  location            = var.gcp_region
  deletion_protection = false
  labels              = var.labels

  template {
    task_count = 1

    template {
      service_account = var.runtime_service_account_email
      max_retries     = var.cloud_run_max_retries
      timeout         = var.cloud_run_task_timeout

      containers {
        image = var.image_uri

        resources {
          limits = {
            cpu    = var.cloud_run_resources.cpu
            memory = var.cloud_run_resources.memory
          }
        }

        dynamic "env" {
          for_each = local.cloud_run_env

          content {
            name  = env.key
            value = env.value
          }
        }

        env {
          name = "AWS_ACCESS_KEY_ID"
          value_source {
            secret_key_ref {
              secret  = var.secret_ids.aws_access_key_id
              version = "latest"
            }
          }
        }

        env {
          name = "AWS_SECRET_ACCESS_KEY"
          value_source {
            secret_key_ref {
              secret  = var.secret_ids.aws_secret_access_key
              version = "latest"
            }
          }
        }

        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = var.secret_ids.db_password
              version = "latest"
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }

      volumes {
        name = "cloudsql"

        cloud_sql_instance {
          instances = [var.cloud_sql_connection_name]
        }
      }
    }
  }
}

resource "google_cloud_run_v2_job" "schema" {
  name                = var.schema_job_name
  project             = var.gcp_project_id
  location            = var.gcp_region
  deletion_protection = false
  labels              = var.labels

  template {
    task_count = 1

    template {
      service_account = var.runtime_service_account_email
      max_retries     = 0
      timeout         = var.schema_job_task_timeout

      containers {
        image = var.image_uri
        args  = ["--ensure-schema-only"]

        resources {
          limits = {
            cpu    = var.cloud_run_resources.cpu
            memory = var.cloud_run_resources.memory
          }
        }

        env {
          name  = "CLOUD_SQL_CONNECTION_NAME"
          value = var.cloud_sql_connection_name
        }

        env {
          name  = "DB_NAME"
          value = var.runtime_env.db_name
        }

        env {
          name  = "DB_USER"
          value = var.runtime_env.db_user
        }

        env {
          name  = "DB_SCHEMA"
          value = var.runtime_env.db_schema
        }

        env {
          name  = "TARGET_TABLE"
          value = var.runtime_env.target_table
        }

        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = var.secret_ids.db_password
              version = "latest"
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }

      volumes {
        name = "cloudsql"

        cloud_sql_instance {
          instances = [var.cloud_sql_connection_name]
        }
      }
    }
  }

  depends_on = [
    google_sql_database.loader,
  ]
}

resource "null_resource" "schema_apply" {
  triggers = {
    schema_job_trigger = local.schema_job_trigger
  }

  provisioner "local-exec" {
    command = "gcloud run jobs execute ${var.schema_job_name} --project ${var.gcp_project_id} --region ${var.gcp_region} --wait"
  }

  depends_on = [
    google_cloud_run_v2_job.schema,
  ]
}

resource "google_cloud_scheduler_job" "loader" {
  name        = var.scheduler_job_name
  project     = var.gcp_project_id
  region      = var.gcp_region
  description = "Runs ${var.cloud_run_job_name} daily to load S3 reference data into Cloud SQL."
  schedule    = var.scheduler_cron
  time_zone   = var.scheduler_time_zone

  http_target {
    http_method = "POST"
    uri         = local.scheduler_uri

    oauth_token {
      service_account_email = var.scheduler_service_account_email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  retry_config {
    retry_count          = 0
    max_retry_duration   = "0s"
    min_backoff_duration = "5s"
    max_backoff_duration = "3600s"
    max_doublings        = 5
  }

  depends_on = [
    google_cloud_run_v2_job.loader,
    null_resource.schema_apply,
  ]
}
