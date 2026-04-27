from __future__ import annotations

import datetime as dt
import json
import logging
import os
from typing import Any, Iterator
from zoneinfo import ZoneInfo

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

MASSIVE_BUCKET_NAME = "flatfiles"
MASSIVE_ENDPOINT_URL = "https://files.massive.com"
NEW_YORK = ZoneInfo("America/New_York")

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def parse_date(value: str) -> dt.date:
    return dt.datetime.strptime(value, "%Y-%m-%d").date()


def format_date(value: dt.date) -> str:
    return value.strftime("%Y-%m-%d")


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


def build_s3_uri(bucket: str, key: str) -> str:
    return f"s3://{bucket}/{key}"


def object_exists(s3_client: boto3.client, bucket: str, key: str) -> bool:
    try:
        s3_client.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code")
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def load_massive_credentials(secret_id: str) -> tuple[str, str]:
    secrets_client = boto3.client("secretsmanager")
    response = secrets_client.get_secret_value(SecretId=secret_id)
    secret = json.loads(response["SecretString"])

    access_key_id = secret.get("access_key_id") or secret.get("MASSIVE_ACCESS_KEY_ID")
    secret_access_key = secret.get("secret_access_key") or secret.get("MASSIVE_SECRET_ACCESS_KEY")

    if not access_key_id or not secret_access_key:
        raise ValueError("Massive secret must include access_key_id and secret_access_key.")

    return access_key_id, secret_access_key


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


def resolve_candidate_dates(event: dict[str, Any], default_lookback_days: int) -> list[dt.date]:
    if event.get("start_date") and event.get("end_date"):
        start_date = parse_date(event["start_date"])
        end_date = parse_date(event["end_date"])
    elif event.get("trade_date"):
        start_date = parse_date(event["trade_date"])
        end_date = start_date
    else:
        lookback_days = int(event.get("lookback_days", default_lookback_days))
        end_date = dt.datetime.now(NEW_YORK).date() - dt.timedelta(days=1)
        start_date = end_date - dt.timedelta(days=lookback_days - 1)

    if end_date < start_date:
        raise ValueError("end_date must be on or after start_date.")

    return list(iter_dates(start_date, end_date))


def copy_if_available(
    massive_client: boto3.client,
    destination_client: boto3.client,
    destination_bucket: str,
    raw_prefix: str,
    day: dt.date,
    overwrite: bool,
) -> dict[str, str]:
    source_key = build_massive_object_key(day)
    destination_key = build_destination_key(raw_prefix, day)
    destination_uri = build_s3_uri(destination_bucket, destination_key)

    if not overwrite and object_exists(destination_client, destination_bucket, destination_key):
        logger.info("Found existing %s", destination_uri)
        return {"status": "EXISTING", "date": format_date(day), "raw_path": destination_uri}

    try:
        response = massive_client.get_object(Bucket=MASSIVE_BUCKET_NAME, Key=source_key)
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code")
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            logger.info("Massive source file missing for %s", format_date(day))
            return {"status": "MISSING", "date": format_date(day)}
        raise

    body = response["Body"]
    try:
        destination_client.upload_fileobj(body, destination_bucket, destination_key)
    finally:
        body.close()

    logger.info("Copied %s/%s to %s", MASSIVE_BUCKET_NAME, source_key, destination_uri)
    return {"status": "COPIED", "date": format_date(day), "raw_path": destination_uri}


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    destination_bucket = os.environ["TARGET_BUCKET"]
    raw_prefix = os.environ.get("RAW_PREFIX", "raw/massive/day_aggs_v1")
    secret_id = os.environ["MASSIVE_SECRET_ID"]
    default_lookback_days = int(os.environ.get("DEFAULT_LOOKBACK_DAYS", "5"))
    overwrite = bool(event.get("overwrite", False))

    candidate_dates = resolve_candidate_dates(event, default_lookback_days)
    access_key_id, secret_access_key = load_massive_credentials(secret_id)
    massive_client = build_massive_client(access_key_id, secret_access_key)
    destination_client = boto3.client("s3")

    staged_results = [
        copy_if_available(
            massive_client=massive_client,
            destination_client=destination_client,
            destination_bucket=destination_bucket,
            raw_prefix=raw_prefix,
            day=day,
            overwrite=overwrite,
        )
        for day in candidate_dates
    ]

    available_dates = [
        result["date"]
        for result in staged_results
        if result["status"] in {"COPIED", "EXISTING"}
    ]
    missing_dates = [
        result["date"]
        for result in staged_results
        if result["status"] == "MISSING"
    ]
    raw_paths = [
        result["raw_path"]
        for result in staged_results
        if result["status"] in {"COPIED", "EXISTING"}
    ]

    if not available_dates:
        input_path = build_s3_uri(destination_bucket, normalize_prefix(raw_prefix)) + "/"
        return {
            "status": "NO_DATA",
            "available_dates": [],
            "missing_dates": missing_dates,
            "raw_paths": [],
            "input_path": input_path,
            "daily_start_date": None,
            "daily_end_date": None,
        }

    daily_start_date = parse_date(min(available_dates))
    daily_end_date = parse_date(max(available_dates))

    input_path = build_s3_uri(destination_bucket, normalize_prefix(raw_prefix)) + "/"

    return {
        "status": "STAGED",
        "available_dates": available_dates,
        "missing_dates": missing_dates,
        "raw_paths": raw_paths,
        "input_path": input_path,
        "daily_start_date": format_date(daily_start_date),
        "daily_end_date": format_date(daily_end_date),
    }
