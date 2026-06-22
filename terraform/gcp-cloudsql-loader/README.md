# GCP Cloud SQL Loader

This Terraform module owns the runtime deployment for the S3 to Cloud SQL reference-data loader:

- Cloud SQL database `moniq_stocks`
- Cloud Run Job `s3-to-cloudsql-daily-pricing`
- Cloud Run Job `s3-to-cloudsql-schema-init`
- Cloud Scheduler Job `daily-s3-to-cloudsql-pricing`
- non-secret runtime environment variables
- Secret Manager references for AWS credentials and the Cloud SQL password

The Cloud SQL database resource uses Terraform `prevent_destroy` lifecycle protection so an accidental destroy plan cannot delete the Postgres database. The provider `deletion_policy` field is ignored because changing it causes a Cloud SQL database update call, which is not supported for Postgres databases.

The schema-init job runs the loader image with `--ensure-schema-only`. It creates:

```text
moniq_stocks.public.daily_pricing
```

The job is executed from Terraform through `gcloud run jobs execute` whenever the image URI or schema/table configuration changes. This keeps the database password out of Terraform state while making database/table initialization part of Terraform apply.

Secret payloads are not stored in Terraform. They stay in GCP Secret Manager:

```text
aws-access-key-id
aws-secret-access-key
moniq-upload-db-password
```

## State

State uses the GCS backend:

```text
gs://moniq-490803-terraform-state/moniq-reference-data/gcp-cloudsql-loader
```

The bucket was created out of band because Terraform cannot use a backend bucket before it exists.

## Import Existing Resources

The initial Cloud Run Job, Scheduler, and Cloud SQL database were created before Terraform owned them. They have been imported into the GCS-backed state for the current `moniq-490803` environment.

If this state ever needs to be rebuilt, import them once:

```bash
terraform init

terraform import google_cloud_run_v2_job.loader \
  projects/moniq-490803/locations/us-central1/jobs/s3-to-cloudsql-daily-pricing

terraform import google_cloud_scheduler_job.loader \
  projects/moniq-490803/locations/us-central1/jobs/daily-s3-to-cloudsql-pricing

terraform import google_sql_database.loader \
  projects/moniq-490803/instances/moniq-postgres/databases/moniq_stocks
```

After import, plan with the image to deploy:

```bash
terraform plan \
  -var image_uri=us-central1-docker.pkg.dev/moniq-490803/moniq/s3-to-cloudsql:TAG
```

GitHub Actions now passes the freshly built image URI into Terraform and runs `terraform apply`.
