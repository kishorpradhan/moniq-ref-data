from __future__ import annotations

import os
from typing import Optional

from pyspark.sql import SparkSession


def _ensure_java_home() -> None:
    """
    Make a Homebrew JDK discoverable on macOS when `/usr/bin/java` is only a stub.
    """
    brew_java_home = "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
    brew_java_bin = "/opt/homebrew/opt/openjdk@17/bin"

    if os.path.exists(os.path.join(brew_java_bin, "java")) and not os.getenv("JAVA_HOME"):
        os.environ["JAVA_HOME"] = brew_java_home
        os.environ["PATH"] = f"{brew_java_bin}:{os.environ.get('PATH', '')}"


def _project_root() -> str:
    return os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def build_spark_session(
    app_name: str,
    extra_packages: Optional[str] = None,
    warehouse_path: Optional[str] = None,
    enable_glue_iceberg: bool = False,
) -> SparkSession:
    """
    Build a Spark session that works locally with s3a:// and stays compatible with EMR Serverless.

    EMR Serverless already provides the Hadoop AWS integration. Local development usually does not,
    so we add the required packages only when running outside EMR Serverless.
    """
    if enable_glue_iceberg and not warehouse_path:
        raise ValueError("warehouse_path is required when enable_glue_iceberg is true")

    project_root = _project_root()
    running_from_zip = not os.path.isdir(project_root)
    running_on_emr_serverless = bool(os.getenv("EMR_SERVERLESS_JOB_RUN_ID")) or running_from_zip

    builder = SparkSession.builder.appName(app_name)

    if not running_on_emr_serverless:
        _ensure_java_home()
        driver_log_config = os.path.join(project_root, "configs", "log4j2-driver.properties")
        executor_log_config = os.path.join(project_root, "configs", "log4j2-executor.properties")
        driver_logs_dir = os.path.join(project_root, "logs", "driver")
        executor_logs_dir = os.path.join(project_root, "logs", "executor")

        os.makedirs(driver_logs_dir, exist_ok=True)
        os.makedirs(executor_logs_dir, exist_ok=True)

        packages = extra_packages or ",".join(
            [
                "org.apache.hadoop:hadoop-aws:3.3.4",
                "com.amazonaws:aws-java-sdk-bundle:1.12.262",
            ]
        )
        builder = (
            builder.config("spark.jars.packages", packages)
            .config(
                "spark.driver.extraJavaOptions",
                f"-Dlog4j.configurationFile=file:{driver_log_config}",
            )
            .config(
                "spark.executor.extraJavaOptions",
                f"-Dlog4j.configurationFile=file:{executor_log_config}",
            )
        )

    builder = (
        builder.config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
        .config(
            "spark.hadoop.fs.s3a.aws.credentials.provider",
            "com.amazonaws.auth.DefaultAWSCredentialsProviderChain",
        )
        .config("spark.hadoop.fs.s3a.path.style.access", "false")
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.sql.execution.arrow.pyspark.enabled", "true")
    )

    if enable_glue_iceberg:
        builder = (
            builder.config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
            .config("spark.sql.defaultCatalog", "glue_catalog")
            .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog")
            .config("spark.sql.catalog.glue_catalog.type", "glue")
            .config("spark.sql.catalog.glue_catalog.warehouse", warehouse_path)
        )

    return builder.getOrCreate()
