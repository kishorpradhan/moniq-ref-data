# Moniq Reference Data

This repository downloads US equity end-of-day pricing from Massive, a market data provider, into S3 and loads that reference data into managed databases that Moniq can query reliably.

The reference data powers the Moniq app. It gives the application a daily, queryable pricing dataset without requiring the app to call the market data provider or read raw S3 files directly.

The main problem this project solves is daily pricing ingestion. Massive daily aggregate files arrive as compressed CSV files, are staged into S3, and are then loaded into either:

- an AWS Glue/Iceberg lake for analytics and 52-week metric calculation
- a GCP Cloud SQL Postgres managed database for application-facing reads

## Data Flow

```text
Massive flat files
  -> AWS S3 raw zone
     s3://moniq-lake/raw/massive/day_aggs_v1/year=YYYY/month=MM/YYYY-MM-DD.csv.gz

  -> AWS analytics path
     EMR Serverless Spark
     -> Glue/Iceberg us_reference_data.daily_pricing
     -> Glue/Iceberg us_reference_data.pricing_52_week_metrics

  -> GCP application path
     GitHub Actions deploys image/job
     -> Artifact Registry
     -> Cloud Run Job
     -> Cloud Scheduler daily trigger
     -> Cloud SQL Postgres daily_pricing
```

The AWS path keeps a lakehouse copy and computes analytics metrics. The GCP path copies the daily pricing facts into Cloud SQL so GCP-hosted services can query them without reading across clouds at request time.

## Repository Layout

```text
.
├── .github/workflows/              # GitHub Actions deployment workflows
├── common/                         # Shared Spark helpers
├── configs/                        # Spark/logging configuration
├── jobs/                           # Batch jobs for Spark and Cloud SQL loading
├── lambdas/                        # AWS Lambda staging code
├── scripts/                        # One-off operational scripts
├── terraform/                      # AWS infrastructure and GCP secret containers
├── utils/                          # Shared utility code
├── Dockerfile.cloudsql-loader      # Cloud Run Job image for S3 -> Cloud SQL
├── cloudbuild.cloudsql-loader.yaml # Optional Cloud Build config
├── requirements.txt                # Local/Spark development dependencies
└── requirements-cloudsql-loader.txt
```

## Prerequisites

- Python 3.11
- Java 11 or newer for Spark jobs
- AWS CLI for AWS/S3/EMR operations
- GCP CLI for Cloud Run, Secret Manager, Cloud SQL, and Scheduler operations
- Terraform 1.5 or newer for infrastructure

## Local Setup

```bash
./setup.sh
source .venv/bin/activate
```

If `java` is not globally on your shell `PATH`, the setup script will automatically use a Homebrew-installed `openjdk@17` when available.

Configure AWS credentials if needed:

```bash
aws configure --profile dev
export AWS_PROFILE=dev
```

Run the sample Spark job:

```bash
source .venv/bin/activate
python3 -m jobs.sample_job
```

The sample reads:

```text
s3a://moniq-market-data/eod/2026-04-17.csv.gz
```

and writes application logs to `logs/driver/sample_job.log`.

## Source Ingestion Into S3

Use [scripts/ingest_massive_day_aggs.py](/Users/kishorpradhan/moniq-reference-data/scripts/ingest_massive_day_aggs.py) to stream Massive daily aggregate files into the AWS S3 raw zone without storing the files locally.

Store Massive credentials in `.env`:

```bash
AWS_PROFILE=dev
MASSIVE_ACCESS_KEY_ID=...
MASSIVE_SECRET_ACCESS_KEY=...
```

Load the file into your shell and run ingestion:

```bash
set -a
source .env
set +a

source .venv/bin/activate
python3 scripts/ingest_massive_day_aggs.py \
  --bucket moniq-lake \
  --raw-prefix raw/massive/day_aggs_v1 \
  --start-date 2025-01-01 \
  --end-date 2026-12-31 \
  --region us-east-1
```

This writes files such as:

- `s3://moniq-lake/raw/massive/day_aggs_v1/year=2025/month=01/2025-01-02.csv.gz`
- `s3://moniq-lake/raw/massive/day_aggs_v1/year=2026/month=04/2026-04-21.csv.gz`

The script skips destination files that already exist. Use `--overwrite` only when a source file should be replaced.

## AWS Lakehouse Path

The AWS path stages Massive files into S3, loads them into the curated `daily_pricing` Iceberg table, and calculates trailing/leading 52-week metrics into `pricing_52_week_metrics`.

### Glue Tables

Create Glue-backed Iceberg tables with [scripts/create_glue_tables.py](/Users/kishorpradhan/moniq-reference-data/scripts/create_glue_tables.py) after Terraform infrastructure has been applied:

```bash
source .venv/bin/activate
AWS_PROFILE=dev python3 scripts/create_glue_tables.py \
  --database us_reference_data \
  --bucket moniq-lake \
  --base-prefix curated/us_reference_data \
  --region us-east-1
```

This creates:

- `daily_pricing`, partitioned by `trade_date`
- `pricing_52_week_metrics`, unpartitioned

### Daily Spark Workflow

Terraform deploys a Step Functions state machine that runs daily at 8 AM America/New_York:

```text
arn:aws:states:us-east-1:195335759084:stateMachine:moniq-reference-data-dev-daily-pricing-load
```

The state machine:

1. Invokes [lambdas/stage_massive_day_aggs.py](/Users/kishorpradhan/moniq-reference-data/lambdas/stage_massive_day_aggs.py) to copy available Massive files from the last 5 calendar days into S3.
2. Runs [jobs/load_daily_pricing.py](/Users/kishorpradhan/moniq-reference-data/jobs/load_daily_pricing.py) on EMR Serverless to load staged files into `daily_pricing`.
3. Runs [jobs/load_pricing_52_week_metrics.py](/Users/kishorpradhan/moniq-reference-data/jobs/load_pricing_52_week_metrics.py) on EMR Serverless to upsert 52-week metrics into `pricing_52_week_metrics`.

Terraform uploads job artifacts to:

- `s3://moniq-lake/artifacts/emr-serverless/jobs/load_daily_pricing.py`
- `s3://moniq-lake/artifacts/emr-serverless/jobs/load_pricing_52_week_metrics.py`
- `s3://moniq-lake/artifacts/emr-serverless/jobs/common.zip`

EMR Serverless logs go to:

```text
s3://moniq-lake/logs/emr-serverless/
```

Manual state machine run:

```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:195335759084:stateMachine:moniq-reference-data-dev-daily-pricing-load \
  --name daily-pricing-load-test-$(date +%Y%m%d%H%M%S) \
  --input '{"lookback_days":5}' \
  --region us-east-1 \
  --profile dev
```

Manual run for a specific date:

```bash
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:us-east-1:195335759084:stateMachine:moniq-reference-data-dev-daily-pricing-load \
  --name daily-pricing-load-20260424 \
  --input '{"trade_date":"2026-04-24"}' \
  --region us-east-1 \
  --profile dev
```

The metrics job uses `--date-range-mode daily_impacted` in the scheduled workflow. It receives the newly staged date range and updates metrics for:

```text
daily_start_date - 364 days through daily_end_date
```

### Direct EMR Submission

For reruns, keep `--write-disposition overwrite_partitions` so only touched `trade_date` partitions are replaced.

```bash
aws emr-serverless start-job-run \
  --application-id 00g54r1tm25alc09 \
  --execution-role-arn arn:aws:iam::195335759084:role/moniq-reference-data-dev-emr-serverless-runtime \
  --job-driver '{
    "sparkSubmit": {
      "entryPoint": "s3://moniq-lake/artifacts/emr-serverless/jobs/load_daily_pricing.py",
      "sparkSubmitParameters": "--py-files s3://moniq-lake/artifacts/emr-serverless/jobs/common.zip",
      "entryPointArguments": [
        "--input-path", "s3://moniq-lake/raw/massive/day_aggs_v1/year=2026/month=04/",
        "--warehouse-path", "s3://moniq-lake/curated/",
        "--database", "us_reference_data",
        "--table", "daily_pricing",
        "--start-date", "2026-04-21",
        "--end-date", "2026-04-22",
        "--write-disposition", "overwrite_partitions"
      ]
    }
  }' \
  --configuration-overrides '{
    "monitoringConfiguration": {
      "s3MonitoringConfiguration": {
        "logUri": "s3://moniq-lake/logs/emr-serverless/"
      }
    }
  }' \
  --region us-east-1
```

## GCP Cloud SQL Path

Use [jobs/load_s3_to_cloudsql.py](/Users/kishorpradhan/moniq-reference-data/jobs/load_s3_to_cloudsql.py) when the target is a GCP Cloud SQL Postgres database instead of Glue/Iceberg.

The loader reads S3 files, creates the target Postgres table if needed, and upserts rows by `(ticker, trade_date)`:

```text
s3://moniq-lake/raw/massive/day_aggs_v1/year=2026/month=06/2026-06-14.csv.gz
  -> public.daily_pricing
```

Local run:

```bash
source .venv/bin/activate
python3 -m jobs.load_s3_to_cloudsql \
  --aws-profile dev \
  --s3-bucket moniq-lake \
  --s3-prefix raw/massive/day_aggs_v1 \
  --trade-date 2026-06-14 \
  --db-host 127.0.0.1 \
  --db-name pricing \
  --db-user postgres \
  --target-table daily_pricing
```

### Secrets

GCP Secret Manager stores the runtime secrets used by the Cloud Run Job:

```text
AWS_ACCESS_KEY_ID_SECRET=aws-access-key-id
AWS_SECRET_ACCESS_KEY_SECRET=aws-secret-access-key
DB_PASSWORD_SECRET=moniq-upload-db-password
```

`aws-access-key-id` and `aws-secret-access-key` contain the AWS IAM key for reading `s3://moniq-lake/raw/massive/day_aggs_v1/*`. `moniq-upload-db-password` is the existing Cloud SQL write-user password.

Terraform for creating the GCP Secret Manager secret containers and IAM bindings lives in [terraform/gcp-secret-manager](/Users/kishorpradhan/moniq-reference-data/terraform/gcp-secret-manager/README.md). It does not store secret values in Terraform state.

### GitHub Actions Deployment

[.github/workflows/deploy-cloudsql-loader.yml](/Users/kishorpradhan/moniq-reference-data/.github/workflows/deploy-cloudsql-loader.yml) deploys the GCP path. On push to `main`, or a manual workflow dispatch, it:

1. Authenticates to GCP with Workload Identity Federation.
2. Builds [Dockerfile.cloudsql-loader](/Users/kishorpradhan/moniq-reference-data/Dockerfile.cloudsql-loader).
3. Pushes the image to Artifact Registry.
4. Deploys or updates a Cloud Run Job.
5. Creates or updates a Cloud Scheduler trigger.

Required GitHub repository variables:

```text
GCP_PROJECT_ID
GCP_WORKLOAD_IDENTITY_PROVIDER
GCP_DEPLOY_SERVICE_ACCOUNT
GCP_REGION
ARTIFACT_REGISTRY_REPOSITORY
CLOUD_RUN_RUNTIME_SERVICE_ACCOUNT
CLOUD_SQL_CONNECTION_NAME
SCHEDULER_SERVICE_ACCOUNT
S3_BUCKET
S3_PREFIX
DB_NAME
DB_USER
AWS_ACCESS_KEY_ID_SECRET
AWS_SECRET_ACCESS_KEY_SECRET
DB_PASSWORD_SECRET
```

Optional variables:

```text
CLOUD_RUN_JOB_NAME
SCHEDULER_JOB_NAME
SCHEDULER_CRON
SCHEDULER_TIME_ZONE
DAYS_AGO
LOOKBACK_DAYS
JOB_TIMEZONE
DB_SCHEMA
TARGET_TABLE
REQUIRE_DATA
CLOUD_RUN_MEMORY
CLOUD_RUN_CPU
CLOUD_RUN_MAX_RETRIES
CLOUD_RUN_TASK_TIMEOUT
```

The runtime service account needs `roles/cloudsql.client` and Secret Manager access to the three secrets. The deploy service account needs permission to push Artifact Registry images, deploy Cloud Run Jobs, and create/update Cloud Scheduler jobs.

Manual Cloud Build image build:

```bash
gcloud builds submit . \
  --config cloudbuild.cloudsql-loader.yaml \
  --substitutions _IMAGE=us-central1-docker.pkg.dev/PROJECT_ID/REPOSITORY/s3-to-cloudsql:latest
```

## Terraform

AWS infrastructure lives under [terraform](/Users/kishorpradhan/moniq-reference-data/terraform/README.md). It creates the Glue database, optional S3 bucket, IAM roles, EMR Serverless app, Lambda staging function, Step Functions workflows, and EventBridge schedule.

GCP Secret Manager infrastructure lives under [terraform/gcp-secret-manager](/Users/kishorpradhan/moniq-reference-data/terraform/gcp-secret-manager/README.md). It creates only secret containers and IAM bindings, not secret values.

Typical AWS Terraform workflow:

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Typical GCP Secret Manager Terraform workflow:

```bash
cd terraform/gcp-secret-manager
terraform init
terraform plan
terraform apply
```

## Operational Notes

- Keep batch business logic in `jobs/`, `common/`, and `utils/`.
- Avoid local-only filesystem assumptions in code that runs on EMR Serverless or Cloud Run.
- Use IAM roles/service accounts and Secret Manager instead of committing credentials.
- Match EMR Serverless Spark runtime to Spark 3.5.x when deploying Spark jobs.
