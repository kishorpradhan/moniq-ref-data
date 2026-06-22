# GCP Cloud SQL Loader

This Terraform module owns the runtime deployment for the S3 to Cloud SQL reference-data loader:

- Cloud Run Job `s3-to-cloudsql-daily-pricing`
- Cloud Scheduler Job `daily-s3-to-cloudsql-pricing`
- non-secret runtime environment variables
- Secret Manager references for AWS credentials and the Cloud SQL password

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

The initial Cloud Run Job and Scheduler were created before Terraform owned them. They have been imported into the GCS-backed state for the current `moniq-490803` environment.

If this state ever needs to be rebuilt, import them once:

```bash
terraform init

terraform import google_cloud_run_v2_job.loader \
  projects/moniq-490803/locations/us-central1/jobs/s3-to-cloudsql-daily-pricing

terraform import google_cloud_scheduler_job.loader \
  projects/moniq-490803/locations/us-central1/jobs/daily-s3-to-cloudsql-pricing
```

After import, plan with the image to deploy:

```bash
terraform plan \
  -var image_uri=us-central1-docker.pkg.dev/moniq-490803/moniq/s3-to-cloudsql:TAG
```

GitHub Actions now passes the freshly built image URI into Terraform and runs `terraform apply`.
