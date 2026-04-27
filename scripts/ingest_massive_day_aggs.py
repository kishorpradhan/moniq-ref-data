from __future__ import annotations

import argparse
import datetime as dt
import logging
import os
import sys
from typing import Iterator

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from utils.aws import get_aws_profile

MASSIVE_ENDPOINT_URL = "https://files.massive.com"
MASSIVE_BUCKET_NAME = "flatfiles"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stream Massive day aggregates directly into an AWS S3 raw zone."
    )
    parser.add_argument("--region", default="us-east-1", help="AWS region for the destination S3 bucket.")
    parser.add_argument("--profile", default=get_aws_profile(), help="AWS profile for the destination S3 bucket.")
    parser.add_argument("--bucket", required=True, help="Destination AWS S3 bucket.")
    parser.add_argument(
        "--raw-prefix",
        default="raw/massive/day_aggs_v1",
        help="Destination S3 prefix for the raw files, without leading or trailing slash.",
    )
    parser.add_argument("--start-date", required=True, help="Inclusive start date in YYYY-MM-DD format.")
    parser.add_argument("--end-date", required=True, help="Inclusive end date in YYYY-MM-DD format.")
    parser.add_argument(
        "--massive-access-key-id",
        default=os.getenv("MASSIVE_ACCESS_KEY_ID"),
        help="Massive access key ID. Defaults to MASSIVE_ACCESS_KEY_ID.",
    )
    parser.add_argument(
        "--massive-secret-access-key",
        default=os.getenv("MASSIVE_SECRET_ACCESS_KEY"),
        help="Massive secret access key. Defaults to MASSIVE_SECRET_ACCESS_KEY.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite destination objects if they already exist.",
    )
    return parser.parse_args()


def configure_logging() -> logging.Logger:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", force=True)
    return logging.getLogger("ingest_massive_day_aggs")


def parse_date(value: str) -> dt.date:
    return dt.datetime.strptime(value, "%Y-%m-%d").date()


def iter_dates(start_date: dt.date, end_date: dt.date) -> Iterator[dt.date]:
    current = start_date
    while current <= end_date:
        yield current
        current += dt.timedelta(days=1)


def normalize_prefix(prefix: str) -> str:
    return prefix.strip("/")


def build_massive_object_key(day: dt.date) -> str:
    return f"us_stocks_sip/day_aggs_v1/{day:%Y/%m}/{day:%Y-%m-%d}.csv.gz"


def build_destination_key(raw_prefix: str, day: dt.date) -> str:
    clean_prefix = normalize_prefix(raw_prefix)
    return f"{clean_prefix}/year={day:%Y}/month={day:%m}/{day:%Y-%m-%d}.csv.gz"


def object_exists(s3_client: boto3.client, bucket: str, key: str) -> bool:
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code")
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def build_massive_client(access_key_id: str, secret_access_key: str) -> boto3.client:
    session = boto3.Session(
        aws_access_key_id=access_key_id,
        aws_secret_access_key=secret_access_key,
    )
    return session.client(
        "s3",
        endpoint_url=MASSIVE_ENDPOINT_URL,
        config=Config(signature_version="s3v4"),
    )


def build_destination_client(profile: str, region: str) -> boto3.client:
    session = boto3.Session(profile_name=profile, region_name=region)
    return session.client("s3")


def stream_one_file(
    massive_client: boto3.client,
    destination_client: boto3.client,
    destination_bucket: str,
    raw_prefix: str,
    day: dt.date,
    overwrite: bool,
    logger: logging.Logger,
) -> None:
    source_key = build_massive_object_key(day)
    destination_key = build_destination_key(raw_prefix, day)

    if not overwrite and object_exists(destination_client, destination_bucket, destination_key):
        logger.info("Skipping existing s3://%s/%s", destination_bucket, destination_key)
        return

    logger.info(
        "Streaming %s/%s to s3://%s/%s",
        MASSIVE_BUCKET_NAME,
        source_key,
        destination_bucket,
        destination_key,
    )

    try:
        response = massive_client.get_object(Bucket=MASSIVE_BUCKET_NAME, Key=source_key)
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code")
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            logger.info("Skipping missing source %s/%s", MASSIVE_BUCKET_NAME, source_key)
            return
        raise

    body = response["Body"]

    try:
        destination_client.upload_fileobj(body, destination_bucket, destination_key)
    finally:
        body.close()


def main() -> None:
    args = parse_args()
    logger = configure_logging()

    if not args.massive_access_key_id or not args.massive_secret_access_key:
        raise ValueError(
            "Massive credentials are required. Set MASSIVE_ACCESS_KEY_ID and "
            "MASSIVE_SECRET_ACCESS_KEY or pass them as command arguments."
        )

    start_date = parse_date(args.start_date)
    end_date = parse_date(args.end_date)
    if end_date < start_date:
        raise ValueError("end-date must be on or after start-date")

    massive_client = build_massive_client(args.massive_access_key_id, args.massive_secret_access_key)
    destination_client = build_destination_client(args.profile, args.region)

    for day in iter_dates(start_date, end_date):
        stream_one_file(
            massive_client=massive_client,
            destination_client=destination_client,
            destination_bucket=args.bucket,
            raw_prefix=args.raw_prefix,
            day=day,
            overwrite=args.overwrite,
            logger=logger,
        )


if __name__ == "__main__":
    main()
