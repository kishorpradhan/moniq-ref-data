from __future__ import annotations

import argparse
import json
import logging
import os
from typing import Any

from common.spark import build_spark_session

DEFAULT_INPUT_PATH = "s3a://moniq-market-data/eod/2026-04-17.csv.gz"
DEFAULT_LOG_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "logs", "driver", "sample_job.log"))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Sample PySpark job for local and EMR Serverless runs.")
    parser.add_argument(
        "--input-path",
        default=DEFAULT_INPUT_PATH,
        help="Input dataset path, including s3a:// URIs.",
    )
    parser.add_argument(
        "--log-path",
        default=DEFAULT_LOG_PATH,
        help="Path to the application log file.",
    )
    parser.add_argument(
        "--sample-size",
        type=int,
        default=10,
        help="Number of sample records to include in the log file.",
    )
    return parser.parse_args()


def configure_logging(log_path: str) -> logging.Logger:
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[
            logging.FileHandler(log_path, mode="a", encoding="utf-8"),
            logging.StreamHandler(),
        ],
        force=True,
    )
    return logging.getLogger("sample_job")


def row_to_jsonable(row: Any) -> dict[str, Any]:
    return row.asDict(recursive=True)


def main() -> None:
    args = parse_args()
    logger = configure_logging(args.log_path)
    spark = build_spark_session(app_name="sample-job")

    logger.info("Reading input from %s", args.input_path)
    df = (
        spark.read.option("header", True)
        .option("inferSchema", True)
        .csv(args.input_path)
    )

    schema_tree = df._jdf.schema().treeString()
    sample_rows = [row_to_jsonable(row) for row in df.limit(args.sample_size).collect()]
    row_count = df.count()

    logger.info("Schema for %s\n%s", args.input_path, schema_tree)
    logger.info("Sample records (%s rows):\n%s", len(sample_rows), json.dumps(sample_rows, indent=2, default=str))
    logger.info("Record count: %s", row_count)

    spark.stop()


if __name__ == "__main__":
    main()
