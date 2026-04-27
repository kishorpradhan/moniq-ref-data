# Terraform Infrastructure

This directory creates the baseline AWS infrastructure for a Glue-backed S3 data lake to store pricing and reference data:

- Glue catalog database
- Optional S3 bucket
- Optional IAM role for Glue crawlers
- Optional IAM role for Glue jobs or `boto3` catalog operations
- Optional EMR Serverless Spark application, runtime role, and uploaded job artifact

## What this does

The Glue database gets a `location_uri` such as:

```text
s3://your-data-bucket/lake/reference_data/
```

That path acts as the database base location. Your Iceberg tables should still use their own subpaths beneath it, for example:

```text
s3://your-data-bucket/lake/reference_data/orders/
s3://your-data-bucket/lake/reference_data/customers/
```

## Usage

1. Copy `terraform.tfvars.example` to `terraform.tfvars`
2. Fill in the placeholders
3. Run:

```bash
terraform init
terraform plan
terraform apply
```

## Notes

- `glue_catalog_id` is optional. Leave it `null` for the normal case, and AWS will use the current account's default Glue Data Catalog.
- Set `create_data_bucket = false` if the bucket already exists.
- The IAM policies here are a practical starting point. Tighten them if you want narrower access boundaries.
- This setup creates the database and access roles only. Create Iceberg tables later through `boto3` or Glue jobs.
- When `enable_emr_serverless = true`, Terraform also creates a Spark application and uploads [jobs/load_daily_pricing.py](/Users/kishorpradhan/moniq-reference-data/jobs/load_daily_pricing.py) into S3 for EMR Serverless submission.
