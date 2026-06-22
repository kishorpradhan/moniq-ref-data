from __future__ import annotations

import argparse
import csv
import gzip
import io
import logging
import os
from contextlib import closing
from datetime import date, datetime, timedelta
from typing import Iterable
from zoneinfo import ZoneInfo

import boto3
import psycopg2
from botocore.exceptions import ClientError
from psycopg2 import sql


RAW_COLUMNS = ("ticker", "volume", "open", "close", "high", "low", "window_start", "transactions")


def env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    return int(value) if value else default


def env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "y", "on"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load Massive daily aggregate files from S3 into Cloud SQL Postgres.")
    parser.add_argument("--aws-profile", default=os.getenv("AWS_PROFILE"), help="Optional AWS profile for local runs.")
    parser.add_argument("--aws-region", default=os.getenv("AWS_REGION", "us-east-1"), help="AWS region for S3.")
    parser.add_argument("--s3-bucket", default=os.getenv("S3_BUCKET", "moniq-lake"), help="Source S3 bucket.")
    parser.add_argument(
        "--s3-prefix",
        default=os.getenv("S3_PREFIX", "raw/massive/day_aggs_v1"),
        help="Source S3 prefix for partitioned Massive files.",
    )
    parser.add_argument(
        "--s3-key",
        default=os.getenv("S3_KEY"),
        help="Exact S3 key to load. If set, date/prefix lookups are skipped.",
    )
    parser.add_argument(
        "--trade-date",
        default=os.getenv("TRADE_DATE"),
        help="Specific trade date to load in YYYY-MM-DD format. Defaults to today minus --days-ago.",
    )
    parser.add_argument(
        "--days-ago",
        type=int,
        default=env_int("DAYS_AGO", 1),
        help="Date offset used when --trade-date is omitted.",
    )
    parser.add_argument(
        "--lookback-days",
        type=int,
        default=env_int("LOOKBACK_DAYS", 1),
        help="Number of dates to check ending at the target date.",
    )
    parser.add_argument(
        "--timezone",
        default=os.getenv("JOB_TIMEZONE", "America/New_York"),
        help="Timezone used to calculate the default target date.",
    )
    parser.add_argument(
        "--require-data",
        action="store_true",
        default=env_bool("REQUIRE_DATA", False),
        help="Exit nonzero if no S3 files are found.",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=env_int("BATCH_SIZE", 50_000),
        help="Rows to COPY into the staging table at a time.",
    )
    parser.add_argument("--db-name", default=os.getenv("DB_NAME"), help="Cloud SQL Postgres database name.")
    parser.add_argument("--db-user", default=os.getenv("DB_USER"), help="Cloud SQL Postgres user.")
    parser.add_argument("--db-password", default=os.getenv("DB_PASSWORD"), help="Cloud SQL Postgres password.")
    parser.add_argument("--db-host", default=os.getenv("DB_HOST"), help="Database host or Cloud SQL Unix socket path.")
    parser.add_argument("--db-port", type=int, default=env_int("DB_PORT", 5432), help="Database port.")
    parser.add_argument("--db-sslmode", default=os.getenv("DB_SSLMODE"), help="Optional Postgres sslmode.")
    parser.add_argument("--db-schema", default=os.getenv("DB_SCHEMA", "public"), help="Target Postgres schema.")
    parser.add_argument("--target-table", default=os.getenv("TARGET_TABLE", "daily_pricing"), help="Target table name.")
    parser.add_argument(
        "--ensure-schema-only",
        action="store_true",
        default=env_bool("ENSURE_SCHEMA_ONLY", False),
        help="Create the target schema/table and exit without loading S3 data.",
    )
    return parser.parse_args()


def configure_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", force=True)


def require_args(args: argparse.Namespace) -> None:
    missing = [name for name in ("db_name", "db_user") if not getattr(args, name)]
    if not (args.db_host or os.getenv("CLOUD_SQL_CONNECTION_NAME")):
        missing.append("db_host or CLOUD_SQL_CONNECTION_NAME")
    if missing:
        raise ValueError(f"Missing required database settings: {', '.join(missing)}")


def target_dates(args: argparse.Namespace) -> list[date]:
    if args.trade_date:
        end_date = date.fromisoformat(args.trade_date)
    else:
        today = datetime.now(ZoneInfo(args.timezone)).date()
        end_date = today - timedelta(days=args.days_ago)

    start_date = end_date - timedelta(days=max(args.lookback_days, 1) - 1)
    return [start_date + timedelta(days=offset) for offset in range((end_date - start_date).days + 1)]


def key_for_date(prefix: str, trade_date: date) -> str:
    clean_prefix = prefix.strip("/")
    return f"{clean_prefix}/year={trade_date:%Y}/month={trade_date:%m}/{trade_date:%Y-%m-%d}.csv.gz"


def source_keys(args: argparse.Namespace) -> list[str]:
    if args.s3_key:
        return [args.s3_key.lstrip("/")]
    return [key_for_date(args.s3_prefix, trade_date) for trade_date in target_dates(args)]


def build_s3_client(args: argparse.Namespace):
    if args.aws_profile:
        session = boto3.Session(profile_name=args.aws_profile, region_name=args.aws_region)
    else:
        session = boto3.Session(region_name=args.aws_region)
    return session.client("s3")


def open_s3_gzip_text(s3_client, bucket: str, key: str):
    response = s3_client.get_object(Bucket=bucket, Key=key)
    gzip_file = gzip.GzipFile(fileobj=response["Body"])
    return io.TextIOWrapper(gzip_file, encoding="utf-8", newline="")


def db_host(args: argparse.Namespace) -> str:
    if args.db_host:
        return args.db_host
    return f"/cloudsql/{os.environ['CLOUD_SQL_CONNECTION_NAME']}"


def connect(args: argparse.Namespace):
    connect_args = {
        "dbname": args.db_name,
        "user": args.db_user,
        "password": args.db_password,
        "host": db_host(args),
        "port": args.db_port,
    }
    if args.db_sslmode:
        connect_args["sslmode"] = args.db_sslmode
    return psycopg2.connect(**connect_args)


def ensure_target_table(conn, schema_name: str, table_name: str) -> None:
    with conn.cursor() as cursor:
        cursor.execute(sql.SQL("CREATE SCHEMA IF NOT EXISTS {}").format(sql.Identifier(schema_name)))
        cursor.execute(
            sql.SQL(
                """
                CREATE TABLE IF NOT EXISTS {}.{} (
                  ticker text NOT NULL,
                  trade_date date NOT NULL,
                  window_start bigint,
                  volume bigint,
                  open double precision,
                  close double precision,
                  high double precision,
                  low double precision,
                  transactions bigint,
                  loaded_at timestamptz NOT NULL DEFAULT now(),
                  PRIMARY KEY (ticker, trade_date)
                )
                """
            ).format(sql.Identifier(schema_name), sql.Identifier(table_name))
        )
    conn.commit()


def create_stage_table(cursor) -> None:
    cursor.execute(
        """
        CREATE TEMP TABLE daily_pricing_stage (
          ticker text,
          volume text,
          open text,
          close text,
          high text,
          low text,
          window_start text,
          transactions text
        ) ON COMMIT DROP
        """
    )


def copy_rows(cursor, rows: list[dict[str, str]]) -> int:
    buffer = io.StringIO()
    writer = csv.writer(buffer, lineterminator="\n")
    for row in rows:
        writer.writerow([row.get(column, "") for column in RAW_COLUMNS])
    buffer.seek(0)
    cursor.copy_expert(
        """
        COPY daily_pricing_stage (
          ticker, volume, open, close, high, low, window_start, transactions
        )
        FROM STDIN WITH (FORMAT CSV, NULL '')
        """,
        buffer,
    )
    return len(rows)


def copy_csv_to_stage(cursor, text_stream, batch_size: int) -> int:
    reader = csv.DictReader(text_stream)
    if not reader.fieldnames:
        raise ValueError("Source file has no CSV header row")

    missing_columns = sorted(set(RAW_COLUMNS) - set(reader.fieldnames))
    if missing_columns:
        raise ValueError(f"Source file is missing expected columns: {', '.join(missing_columns)}")

    staged = 0
    batch: list[dict[str, str]] = []
    for row in reader:
        batch.append(row)
        if len(batch) >= batch_size:
            staged += copy_rows(cursor, batch)
            batch.clear()

    if batch:
        staged += copy_rows(cursor, batch)
    return staged


def upsert_stage(cursor, schema_name: str, table_name: str) -> int:
    cursor.execute(
        sql.SQL(
            """
            WITH normalized AS (
              SELECT
                upper(nullif(ticker, '')) AS ticker,
                to_timestamp((nullif(window_start, '')::numeric / 1000000000))::date AS trade_date,
                nullif(window_start, '')::bigint AS window_start,
                nullif(volume, '')::bigint AS volume,
                nullif(open, '')::double precision AS open,
                nullif(close, '')::double precision AS close,
                nullif(high, '')::double precision AS high,
                nullif(low, '')::double precision AS low,
                nullif(transactions, '')::bigint AS transactions
              FROM daily_pricing_stage
              WHERE nullif(ticker, '') IS NOT NULL
                AND nullif(window_start, '') IS NOT NULL
            ),
            deduped AS (
              SELECT *,
                row_number() OVER (
                  PARTITION BY ticker, trade_date
                  ORDER BY window_start DESC
                ) AS row_number
              FROM normalized
            )
            INSERT INTO {}.{} (
              ticker,
              trade_date,
              window_start,
              volume,
              open,
              close,
              high,
              low,
              transactions,
              loaded_at
            )
            SELECT
              ticker,
              trade_date,
              window_start,
              volume,
              open,
              close,
              high,
              low,
              transactions,
              now()
            FROM deduped
            WHERE row_number = 1
            ON CONFLICT (ticker, trade_date)
            DO UPDATE SET
              window_start = EXCLUDED.window_start,
              volume = EXCLUDED.volume,
              open = EXCLUDED.open,
              close = EXCLUDED.close,
              high = EXCLUDED.high,
              low = EXCLUDED.low,
              transactions = EXCLUDED.transactions,
              loaded_at = now()
            """
        ).format(sql.Identifier(schema_name), sql.Identifier(table_name))
    )
    return cursor.rowcount


def load_key(conn, s3_client, args: argparse.Namespace, key: str) -> tuple[int, int]:
    logging.info("Loading s3://%s/%s", args.s3_bucket, key)
    with open_s3_gzip_text(s3_client, args.s3_bucket, key) as text_stream:
        with conn.cursor() as cursor:
            create_stage_table(cursor)
            staged_rows = copy_csv_to_stage(cursor, text_stream, args.batch_size)
            upserted_rows = upsert_stage(cursor, args.db_schema, args.target_table)
        conn.commit()
    logging.info("Loaded %s staged rows and upserted %s rows from %s", staged_rows, upserted_rows, key)
    return staged_rows, upserted_rows


def is_missing_s3_object(error: ClientError) -> bool:
    code = error.response.get("Error", {}).get("Code")
    return code in {"NoSuchKey", "404", "NotFound"}


def load_available_keys(conn, s3_client, args: argparse.Namespace, keys: Iterable[str]) -> tuple[int, int, int]:
    files_loaded = 0
    total_staged = 0
    total_upserted = 0

    for key in keys:
        try:
            staged_rows, upserted_rows = load_key(conn, s3_client, args, key)
        except ClientError as error:
            if is_missing_s3_object(error):
                logging.warning("Skipping missing source file s3://%s/%s", args.s3_bucket, key)
                continue
            raise
        files_loaded += 1
        total_staged += staged_rows
        total_upserted += upserted_rows

    return files_loaded, total_staged, total_upserted


def main() -> None:
    configure_logging()
    args = parse_args()
    require_args(args)

    keys = source_keys(args)
    logging.info("Checking %s source key(s)", len(keys))

    s3_client = build_s3_client(args)
    with closing(connect(args)) as conn:
        ensure_target_table(conn, args.db_schema, args.target_table)
        if args.ensure_schema_only:
            logging.info("Ensured target table %s.%s and exiting", args.db_schema, args.target_table)
            return
        files_loaded, staged_rows, upserted_rows = load_available_keys(conn, s3_client, args, keys)

    if files_loaded == 0 and args.require_data:
        raise RuntimeError("No source files were loaded")

    logging.info(
        "Finished Cloud SQL load: files_loaded=%s staged_rows=%s upserted_rows=%s",
        files_loaded,
        staged_rows,
        upserted_rows,
    )


if __name__ == "__main__":
    main()
