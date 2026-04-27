from __future__ import annotations

import argparse
import logging
import os
import sys
import time

import boto3

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from utils.aws import get_aws_profile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create one-off Glue-backed Iceberg tables via Athena DDL.")
    parser.add_argument("--region", default="us-east-1", help="AWS region for Athena and Glue.")
    parser.add_argument("--profile", default=get_aws_profile(), help="AWS profile name.")
    parser.add_argument("--database", required=True, help="Glue database name.")
    parser.add_argument("--bucket", required=True, help="S3 bucket that stores the Iceberg tables.")
    parser.add_argument(
        "--base-prefix",
        default="curated/us_reference_data",
        help="Base S3 prefix under the bucket for the database tables, without leading or trailing slash.",
    )
    parser.add_argument(
        "--athena-results-prefix",
        default="athena-results",
        help="S3 prefix under the bucket for Athena query results.",
    )
    parser.add_argument("--workgroup", default="primary", help="Athena workgroup to run the DDL in.")
    return parser.parse_args()


def configure_logging() -> logging.Logger:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", force=True)
    return logging.getLogger("create_glue_tables")


def normalize_prefix(prefix: str) -> str:
    return prefix.strip("/")


def build_s3_location(bucket: str, prefix: str) -> str:
    clean_prefix = normalize_prefix(prefix)
    return f"s3://{bucket}/{clean_prefix}/"


def build_table_location(bucket: str, base_prefix: str, table_name: str) -> str:
    return build_s3_location(bucket, f"{normalize_prefix(base_prefix)}/{table_name}")


def build_results_location(bucket: str, athena_results_prefix: str) -> str:
    return build_s3_location(bucket, athena_results_prefix)


def build_daily_pricing_ddl(database_name: str, bucket: str, base_prefix: str) -> str:
    location = build_table_location(bucket, base_prefix, "daily_pricing")
    return f"""
CREATE TABLE IF NOT EXISTS {database_name}.daily_pricing (
  ticker string,
  trade_date date,
  window_start bigint,
  volume bigint,
  open double,
  close double,
  high double,
  low double,
  transactions bigint
)
PARTITIONED BY (day(trade_date))
LOCATION '{location}'
TBLPROPERTIES (
  'table_type' = 'ICEBERG',
  'format' = 'parquet'
)
""".strip()


def build_pricing_52_week_metrics_ddl(database_name: str, bucket: str, base_prefix: str) -> str:
    location = build_table_location(bucket, base_prefix, "pricing_52_week_metrics")
    return f"""
CREATE TABLE IF NOT EXISTS {database_name}.pricing_52_week_metrics (
  ticker string,
  trade_date date,
  window_start bigint,
  volume bigint,
  open double,
  close double,
  high double,
  low double,
  transactions bigint,
  past_high_52_weeks double,
  past_low_52_weeks double,
  future_high_52_weeks double,
  future_low_52_weeks double
)
LOCATION '{location}'
TBLPROPERTIES (
  'table_type' = 'ICEBERG',
  'format' = 'parquet'
)
""".strip()


def build_set_write_data_path_ddl(database_name: str, table_name: str, bucket: str, base_prefix: str) -> str:
    location = build_table_location(bucket, base_prefix, table_name)
    data_location = f"{location}data"
    return f"""
ALTER TABLE {database_name}.{table_name} SET TBLPROPERTIES (
  'write.data.path' = '{data_location}'
)
""".strip()


def build_unset_write_object_storage_path_ddl(database_name: str, table_name: str) -> str:
    return f"""
ALTER TABLE {database_name}.{table_name} UNSET TBLPROPERTIES (
  'write.object-storage.path'
)
""".strip()


def run_ddl(
    athena_client: boto3.client,
    database_name: str,
    workgroup: str,
    results_location: str,
    ddl: str,
    logger: logging.Logger,
) -> None:
    response = athena_client.start_query_execution(
        QueryString=ddl,
        QueryExecutionContext={"Database": database_name},
        ResultConfiguration={"OutputLocation": results_location},
        WorkGroup=workgroup,
    )
    execution_id = response["QueryExecutionId"]
    logger.info("Started Athena query %s", execution_id)

    while True:
        result = athena_client.get_query_execution(QueryExecutionId=execution_id)
        status = result["QueryExecution"]["Status"]["State"]

        if status == "SUCCEEDED":
            logger.info("Athena query %s succeeded", execution_id)
            return

        if status in {"FAILED", "CANCELLED"}:
            reason = result["QueryExecution"]["Status"].get("StateChangeReason", "No error reason returned.")
            raise RuntimeError(f"Athena query {execution_id} {status.lower()}: {reason}")

        time.sleep(2)


def main() -> None:
    args = parse_args()
    logger = configure_logging()

    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    athena_client = session.client("athena")
    results_location = build_results_location(args.bucket, args.athena_results_prefix)

    ddls = [
        build_daily_pricing_ddl(args.database, args.bucket, args.base_prefix),
        build_pricing_52_week_metrics_ddl(args.database, args.bucket, args.base_prefix),
        build_set_write_data_path_ddl(args.database, "daily_pricing", args.bucket, args.base_prefix),
        build_unset_write_object_storage_path_ddl(args.database, "daily_pricing"),
        build_set_write_data_path_ddl(args.database, "pricing_52_week_metrics", args.bucket, args.base_prefix),
        build_unset_write_object_storage_path_ddl(args.database, "pricing_52_week_metrics"),
    ]

    for ddl in ddls:
        logger.info("Running DDL:\n%s", ddl)
        run_ddl(
            athena_client=athena_client,
            database_name=args.database,
            workgroup=args.workgroup,
            results_location=results_location,
            ddl=ddl,
            logger=logger,
        )


if __name__ == "__main__":
    main()
