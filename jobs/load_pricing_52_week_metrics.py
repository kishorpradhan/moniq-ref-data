from __future__ import annotations

import argparse
import datetime as dt

from common.io import read_iceberg_table
from common.spark import build_spark_session
from pyspark.sql import DataFrame
from pyspark.sql import Window
from pyspark.sql import functions as F


LOOKBACK_DAYS = 364
METRICS_COLUMNS = [
    "ticker",
    "trade_date",
    "window_start",
    "volume",
    "open",
    "close",
    "high",
    "low",
    "transactions",
    "past_high_52_weeks",
    "past_low_52_weeks",
    "future_high_52_weeks",
    "future_low_52_weeks",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Calculate 52-week pricing metrics from the curated daily_pricing table.")
    parser.add_argument("--warehouse-path", required=True, help="Iceberg warehouse root, for example s3://bucket/curated.")
    parser.add_argument("--database", default="us_reference_data", help="Glue database name.")
    parser.add_argument("--source-table", default="daily_pricing", help="Source Iceberg table name.")
    parser.add_argument("--target-table", default="pricing_52_week_metrics", help="Target Iceberg table name.")
    parser.add_argument("--start-date", required=True, help="Inclusive output lower bound in YYYY-MM-DD format.")
    parser.add_argument("--end-date", required=True, help="Inclusive output upper bound in YYYY-MM-DD format.")
    parser.add_argument(
        "--date-range-mode",
        choices=["output", "daily_impacted"],
        default="output",
        help=(
            "Use output to write exactly start-date through end-date. Use daily_impacted "
            "for daily loads, where start-date/end-date are newly staged pricing dates and "
            "the metrics output range becomes start-date minus 364 days through end-date."
        ),
    )
    return parser.parse_args()


def resolve_output_range(start_date: str, end_date: str, date_range_mode: str) -> tuple[str, str]:
    if date_range_mode == "output":
        return start_date, end_date

    if date_range_mode == "daily_impacted":
        daily_start_date = dt.datetime.strptime(start_date, "%Y-%m-%d").date()
        impacted_start_date = daily_start_date - dt.timedelta(days=LOOKBACK_DAYS)
        return impacted_start_date.strftime("%Y-%m-%d"), end_date

    raise ValueError(f"Unsupported date_range_mode: {date_range_mode}")


def transform(df: DataFrame, start_date: str, end_date: str) -> DataFrame:
    lookback_start = F.date_sub(F.lit(start_date).cast("date"), LOOKBACK_DAYS)
    lookahead_end = F.date_add(F.lit(end_date).cast("date"), LOOKBACK_DAYS)

    trade_day = F.datediff(F.col("trade_date"), F.lit("1970-01-01"))
    trailing_window = Window.partitionBy("ticker").orderBy("trade_day").rangeBetween(-LOOKBACK_DAYS, 0)
    leading_window = Window.partitionBy("ticker").orderBy("trade_day").rangeBetween(1, LOOKBACK_DAYS)

    metrics = (
        df.filter((F.col("trade_date") >= lookback_start) & (F.col("trade_date") <= lookahead_end))
        .withColumn("trade_day", trade_day)
        .withColumn("trailing_start_date", F.min("trade_date").over(trailing_window))
        .withColumn(
            "has_full_trailing_window",
            F.col("trailing_start_date") <= F.date_sub(F.col("trade_date"), LOOKBACK_DAYS),
        )
        .withColumn(
            "past_high_52_weeks",
            F.when(F.col("has_full_trailing_window"), F.max("high").over(trailing_window)),
        )
        .withColumn(
            "past_low_52_weeks",
            F.when(F.col("has_full_trailing_window"), F.min("low").over(trailing_window)),
        )
        .withColumn("future_high_52_weeks", F.max("high").over(leading_window))
        .withColumn("future_low_52_weeks", F.min("low").over(leading_window))
        .filter((F.col("trade_date") >= F.lit(start_date)) & (F.col("trade_date") <= F.lit(end_date)))
        .drop("trade_day", "trailing_start_date", "has_full_trailing_window")
    )

    return metrics.select(*METRICS_COLUMNS)


def merge_metrics_table(
    df: DataFrame,
    database_name: str,
    table_name: str,
    catalog_name: str = "glue_catalog",
    temp_view_name: str = "pricing_52_week_metrics_updates",
) -> None:
    df.createOrReplaceTempView(temp_view_name)

    target_table = f"{catalog_name}.{database_name}.{table_name}"
    update_assignments = ", ".join([f"target.{column} = source.{column}" for column in METRICS_COLUMNS])
    insert_columns = ", ".join(METRICS_COLUMNS)
    insert_values = ", ".join([f"source.{column}" for column in METRICS_COLUMNS])

    df.sparkSession.sql(
        f"""
        MERGE INTO {target_table} target
        USING {temp_view_name} source
        ON target.ticker = source.ticker
           AND target.trade_date = source.trade_date
        WHEN MATCHED THEN UPDATE SET {update_assignments}
        WHEN NOT MATCHED THEN INSERT ({insert_columns}) VALUES ({insert_values})
        """
    )


def main() -> None:
    args = parse_args()
    spark = build_spark_session(
        app_name="load-pricing-52-week-metrics",
        warehouse_path=args.warehouse_path,
        enable_glue_iceberg=True,
    )

    output_start_date, output_end_date = resolve_output_range(args.start_date, args.end_date, args.date_range_mode)
    source_df = read_iceberg_table(spark, database_name=args.database, table_name=args.source_table)
    transformed_df = transform(source_df, output_start_date, output_end_date)
    merge_metrics_table(
        df=transformed_df,
        database_name=args.database,
        table_name=args.target_table,
    )

    spark.stop()


if __name__ == "__main__":
    main()
