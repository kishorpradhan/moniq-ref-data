# PySpark Local Development Environment

This repository is set up for local PySpark development with:

- Python 3.11 virtual environment
- PySpark 3.5
- Local `s3a://` access using AWS credentials
- EMR Serverless-compatible project layout

## Project Structure

```text
.
├── common/
├── configs/
├── jobs/
├── terraform/
├── utils/
├── requirements.txt
└── setup.sh
```

## Prerequisites

- Python 3.11
- Java 11 or newer
- AWS CLI

## Setup

```bash
./setup.sh
source .venv/bin/activate
```

If `java` is not globally on your shell `PATH`, the setup script will automatically use a Homebrew-installed `openjdk@17` when available.

If AWS credentials are not configured yet:

```bash
aws configure
```

Or use a named profile:

```bash
aws configure --profile dev
export AWS_PROFILE=dev
```

## Run a Sample Job

```bash
source .venv/bin/activate
python3 -m jobs.sample_job
```

Default sample input:

```text
s3a://moniq-market-data/eod/2026-04-17.csv.gz
```

The job writes:

- application output to `logs/driver/sample_job.log`
- Spark driver logs to `logs/driver/spark-driver.log`
- Spark executor logs to `logs/executor/spark-executor.log`

## Create Glue Tables

Use the one-off script in [scripts/create_glue_tables.py](/Users/kishorpradhan/moniq-reference-data/scripts/create_glue_tables.py) after the Terraform infrastructure has been applied. The script submits Athena DDL that creates Glue-backed Iceberg tables in the `us_reference_data` database:

```bash
source .venv/bin/activate
AWS_PROFILE=dev python3 scripts/create_glue_tables.py \
  --database us_reference_data \
  --bucket moniq-lake \
  --base-prefix curated/us_reference_data \
  --region us-east-1
```

This creates:

- `daily_pricing` as an Iceberg table partitioned by `trade_date`
- `pricing_52_week_metrics` as an unpartitioned Iceberg table

The script also updates the Iceberg write-path properties so the tables are compatible with EMR Serverless Spark runtimes that reject the deprecated `write.object-storage.path` property.

## Ingest Massive Flat Files

Use the one-off script in [scripts/ingest_massive_day_aggs.py](/Users/kishorpradhan/moniq-reference-data/scripts/ingest_massive_day_aggs.py) to stream Massive daily aggregate files directly into your AWS S3 raw zone without saving them locally first.

Store the Massive credentials in [`.env`](/Users/kishorpradhan/moniq-reference-data/.env):

```bash
AWS_PROFILE=dev
MASSIVE_ACCESS_KEY_ID=...
MASSIVE_SECRET_ACCESS_KEY=...
```

Load the file into your shell and run the ingest:

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

That will write files like:

- `s3://moniq-lake/raw/massive/day_aggs_v1/year=2025/month=01/2025-01-02.csv.gz`
- `s3://moniq-lake/raw/massive/day_aggs_v1/year=2026/month=04/2026-04-21.csv.gz`

The script skips destination files that already exist. Use `--overwrite` if you want to force re-upload.

## EMR Serverless Notes

- Keep business logic in `jobs/`, `common/`, and `utils/`.
- Avoid local-only filesystem assumptions in job code.
- Use IAM roles in EMR Serverless instead of static credentials.
- Match the EMR Serverless Spark runtime to Spark 3.5.x when deploying.

## Daily Pricing Spark Workflow

The production workflow stages Massive daily aggregate files into S3, loads them into the curated `daily_pricing` Iceberg table, and then calculates trailing and leading 52-week pricing metrics into `pricing_52_week_metrics`.

Terraform deploys a daily Step Functions state machine that runs at 8 AM America/New_York. The state machine:

1. Invokes [lambdas/stage_massive_day_aggs.py](/Users/kishorpradhan/moniq-reference-data/lambdas/stage_massive_day_aggs.py) to copy available Massive files from the last 5 calendar days into raw S3.
2. Runs [jobs/load_daily_pricing.py](/Users/kishorpradhan/moniq-reference-data/jobs/load_daily_pricing.py) on EMR Serverless to load the staged raw files into `daily_pricing`.
3. Runs [jobs/load_pricing_52_week_metrics.py](/Users/kishorpradhan/moniq-reference-data/jobs/load_pricing_52_week_metrics.py) on EMR Serverless to upsert 52-week metrics into `pricing_52_week_metrics`.

Terraform uploads the job to:

- `s3://moniq-lake/artifacts/emr-serverless/jobs/load_daily_pricing.py`
- `s3://moniq-lake/artifacts/emr-serverless/jobs/load_pricing_52_week_metrics.py`
- `s3://moniq-lake/artifacts/emr-serverless/jobs/common.zip`

The EMR Serverless application writes logs to:

- `s3://moniq-lake/logs/emr-serverless/`

The daily state machine ARN is:

```text
arn:aws:states:us-east-1:195335759084:stateMachine:moniq-reference-data-dev-daily-pricing-load
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

The metrics job uses `--date-range-mode daily_impacted` in the scheduled workflow. In that mode, the job receives the newly staged pricing date range and internally updates metrics for:

```text
daily_start_date - 364 days through daily_end_date
```

That keeps the Lambda focused on staging only recent Massive files while the Spark metrics job owns the 52-week business logic.

Example direct EMR Serverless submission for the daily pricing Spark job:

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

For reruns on an existing date range, keep `--write-disposition overwrite_partitions` so the job replaces only the touched trade-date partitions.

## Terraform Infrastructure

Baseline Glue and S3 infrastructure now lives in [terraform/README.md](/Users/kishorpradhan/moniq-reference-data/terraform/README.md).

Use it to provision:

- a Glue database with a configurable S3 `location_uri`
- an optional data bucket
- IAM roles for Glue crawlers and Glue jobs or `boto3`-driven table creation
