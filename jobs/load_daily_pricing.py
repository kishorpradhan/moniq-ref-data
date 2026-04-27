from __future__ import annotations

import argparse
from typing import Optional

from common.io import read_csv, write_iceberg_table
from common.spark import build_spark_session
from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql import types as T


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Load raw Massive day aggregates into the curated Iceberg daily_pricing table.")
    parser.add_argument("--input-path", required=True, help="Raw S3 prefix containing Massive daily aggregate csv.gz files.")
    parser.add_argument("--warehouse-path", required=True, help="Iceberg warehouse root, for example s3://bucket/curated.")
    parser.add_argument("--database", default="us_reference_data", help="Glue database name.")
    parser.add_argument("--table", default="daily_pricing", help="Target Iceberg table name.")
    parser.add_argument("--start-date", default=None, help="Optional inclusive lower bound on trade_date in YYYY-MM-DD format.")
    parser.add_argument("--end-date", default=None, help="Optional inclusive upper bound on trade_date in YYYY-MM-DD format.")
    parser.add_argument(
        "--write-disposition",
        choices=["overwrite_partitions", "append"],
        default="overwrite_partitions",
        help="How to write data into the target Iceberg table.",
    )
    return parser.parse_args()


def source_schema() -> T.StructType:
    return T.StructType(
        [
            T.StructField("ticker", T.StringType(), True),
            T.StructField("volume", T.LongType(), True),
            T.StructField("open", T.DoubleType(), True),
            T.StructField("close", T.DoubleType(), True),
            T.StructField("high", T.DoubleType(), True),
            T.StructField("low", T.DoubleType(), True),
            T.StructField("window_start", T.LongType(), True),
            T.StructField("transactions", T.LongType(), True),
        ]
    )


def transform(df: DataFrame, start_date: Optional[str], end_date: Optional[str]) -> DataFrame:
    transformed = (
        df.select(
            F.upper(F.col("ticker")).alias("ticker"),
            F.col("volume").cast("long").alias("volume"),
            F.col("open").cast("double").alias("open"),
            F.col("close").cast("double").alias("close"),
            F.col("high").cast("double").alias("high"),
            F.col("low").cast("double").alias("low"),
            F.col("window_start").cast("long").alias("window_start"),
            F.col("transactions").cast("long").alias("transactions"),
        )
        .withColumn(
            "trade_date",
            F.to_date(F.from_unixtime((F.col("window_start") / F.lit(1_000_000_000)).cast("bigint"))),
        )
        .dropna(subset=["ticker", "trade_date", "window_start"])
        .dropDuplicates(["ticker", "trade_date"])
        .select(
            "ticker",
            "trade_date",
            "window_start",
            "volume",
            "open",
            "close",
            "high",
            "low",
            "transactions",
        )
    )

    if start_date:
        transformed = transformed.filter(F.col("trade_date") >= F.lit(start_date))

    if end_date:
        transformed = transformed.filter(F.col("trade_date") <= F.lit(end_date))

    return transformed


def main() -> None:
    args = parse_args()
    spark = build_spark_session(
        app_name="load-daily-pricing",
        warehouse_path=args.warehouse_path,
        enable_glue_iceberg=True,
    )

    source_df = read_csv(spark, args.input_path, schema=source_schema())
    transformed_df = transform(source_df, args.start_date, args.end_date)
    write_iceberg_table(
        df=transformed_df,
        database_name=args.database,
        table_name=args.table,
        write_disposition=args.write_disposition,
        partition_repartition_column="trade_date",
    )

    spark.stop()


if __name__ == "__main__":
    main()
