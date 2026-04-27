from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any
from urllib.parse import urlparse

import boto3

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if REPO_ROOT not in sys.path:
    sys.path.insert(0, REPO_ROOT)

from utils.aws import get_aws_profile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Inspect the current Iceberg metadata for a Glue catalog table.")
    parser.add_argument("--region", default="us-east-1", help="AWS region for Glue and S3.")
    parser.add_argument("--profile", default=get_aws_profile(), help="AWS profile name.")
    parser.add_argument("--database", required=True, help="Glue database name.")
    parser.add_argument("--table", required=True, help="Glue table name.")
    return parser.parse_args()


def parse_s3_uri(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path:
        raise ValueError(f"Invalid S3 URI: {uri}")
    return parsed.netloc, parsed.path.lstrip("/")


def fetch_table(glue_client: Any, database_name: str, table_name: str) -> dict[str, Any]:
    response = glue_client.get_table(DatabaseName=database_name, Name=table_name)
    return response["Table"]


def fetch_json(s3_client: Any, uri: str) -> dict[str, Any]:
    bucket, key = parse_s3_uri(uri)
    response = s3_client.get_object(Bucket=bucket, Key=key)
    return json.loads(response["Body"].read())


def print_columns(columns: list[dict[str, Any]]) -> None:
    print("Columns:")
    for column in columns:
        required = "required" if column.get("required") else "optional"
        print(f"  - {column['name']}: {column['type']} ({required})")


def print_partition_spec(partition_specs: list[dict[str, Any]], default_spec_id: int) -> None:
    print(f"Default partition spec id: {default_spec_id}")
    for spec in partition_specs:
        marker = "*" if spec["spec-id"] == default_spec_id else " "
        print(f"{marker} Spec {spec['spec-id']}:")
        if not spec.get("fields"):
            print("    - unpartitioned")
            continue
        for field in spec["fields"]:
            print(
                f"    - {field['name']}: transform={field['transform']}, "
                f"source-id={field['source-id']}, field-id={field['field-id']}"
            )


def print_properties(properties: dict[str, Any]) -> None:
    print("Properties:")
    if not properties:
        print("  - none")
        return
    for key in sorted(properties):
        print(f"  - {key} = {properties[key]}")


def print_snapshots(snapshots: list[dict[str, Any]], current_snapshot_id: int) -> None:
    print(f"Current snapshot id: {current_snapshot_id}")
    print("Snapshots:")
    if not snapshots:
        print("  - none")
        return
    for snapshot in snapshots:
        marker = "*" if snapshot["snapshot-id"] == current_snapshot_id else " "
        operation = snapshot.get("summary", {}).get("operation", "unknown")
        manifest_list = snapshot.get("manifest-list", "n/a")
        print(
            f"{marker} snapshot_id={snapshot['snapshot-id']} "
            f"sequence={snapshot.get('sequence-number')} "
            f"operation={operation} "
            f"manifest_list={manifest_list}"
        )


def main() -> None:
    args = parse_args()
    session = boto3.Session(profile_name=args.profile, region_name=args.region)
    glue_client = session.client("glue")
    s3_client = session.client("s3")

    table = fetch_table(glue_client, args.database, args.table)
    metadata_location = table.get("Parameters", {}).get("metadata_location")
    if not metadata_location:
        raise ValueError(f"Glue table {args.database}.{args.table} does not expose metadata_location")

    metadata = fetch_json(s3_client, metadata_location)
    schema = next(schema for schema in metadata["schemas"] if schema["schema-id"] == metadata["current-schema-id"])

    print(f"Table: {args.database}.{args.table}")
    print(f"Glue location: {table['StorageDescriptor']['Location']}")
    print(f"Metadata location: {metadata_location}")
    print(f"Format version: {metadata['format-version']}")
    print(f"Table UUID: {metadata['table-uuid']}")
    print_columns(schema["fields"])
    print_partition_spec(metadata.get("partition-specs", []), metadata["default-spec-id"])
    print_properties(metadata.get("properties", {}))
    print_snapshots(metadata.get("snapshots", []), metadata.get("current-snapshot-id", -1))


if __name__ == "__main__":
    main()
