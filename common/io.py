from __future__ import annotations

from typing import Optional

from pyspark.sql import DataFrame, SparkSession
from pyspark.sql import types as T


def read_csv(
    spark: SparkSession,
    input_path: str,
    schema: Optional[T.StructType] = None,
    header: bool = True,
    recursive_file_lookup: bool = True,
) -> DataFrame:
    reader = (
        spark.read.option("header", str(header).lower())
        .option("recursiveFileLookup", str(recursive_file_lookup).lower())
    )

    if schema is not None:
        reader = reader.schema(schema)

    return reader.csv(input_path)


def read_iceberg_table(
    spark: SparkSession,
    database_name: str,
    table_name: str,
    catalog_name: str = "glue_catalog",
) -> DataFrame:
    return spark.table(f"{catalog_name}.{database_name}.{table_name}")


def write_iceberg_table(
    df: DataFrame,
    database_name: str,
    table_name: str,
    write_disposition: str,
    catalog_name: str = "glue_catalog",
    partition_repartition_column: Optional[str] = None,
) -> None:
    if partition_repartition_column:
        df = df.repartition(partition_repartition_column)

    target = df.writeTo(f"{catalog_name}.{database_name}.{table_name}")

    if write_disposition == "append":
        target.append()
        return

    if write_disposition == "overwrite_partitions":
        target.overwritePartitions()
        return

    raise ValueError(f"Unsupported write_disposition: {write_disposition}")
