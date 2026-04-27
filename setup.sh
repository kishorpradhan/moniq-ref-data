#!/usr/bin/env bash

set -euo pipefail

VENV_DIR=".venv"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
AWS_PROFILE_NAME="${AWS_PROFILE:-default}"
BREW_JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
BREW_JAVA_BIN="/opt/homebrew/opt/openjdk@17/bin"

echo "Checking Python..."
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "Error: ${PYTHON_BIN} is not installed or not on PATH."
  exit 1
fi

echo "Checking Java..."
if ! command -v java >/dev/null 2>&1 || ! java -version >/dev/null 2>&1; then
  if [ -x "${BREW_JAVA_BIN}/java" ]; then
    export JAVA_HOME="${BREW_JAVA_HOME}"
    export PATH="${BREW_JAVA_BIN}:${PATH}"
    echo "Using Homebrew Java from ${JAVA_HOME}"
  else
    echo "Error: Java is required for PySpark."
    echo "Install Java 11+ and rerun this script."
    exit 1
  fi
fi

echo "Checking AWS CLI..."
if ! command -v aws >/dev/null 2>&1; then
  echo "Error: AWS CLI is not installed."
  echo "Install it with your package manager, then rerun this script."
  echo "Example on macOS with Homebrew: brew install awscli"
  exit 1
fi

echo "Creating virtual environment in ${VENV_DIR}..."
if [ ! -d "${VENV_DIR}" ]; then
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

echo "Activating virtual environment..."
source "${VENV_DIR}/bin/activate"

echo "Upgrading pip..."
python -m pip install --upgrade pip

echo "Installing Python dependencies..."
pip install -r requirements.txt

echo "Checking AWS CLI configuration..."
if ! aws sts get-caller-identity --profile "${AWS_PROFILE_NAME}" >/dev/null 2>&1; then
  echo "AWS CLI is installed, but credentials for profile '${AWS_PROFILE_NAME}' are not ready."
  echo "Run one of the following and rerun jobs once credentials are available:"
  echo "  aws configure"
  echo "  aws configure --profile ${AWS_PROFILE_NAME}"
else
  echo "AWS CLI credentials validated for profile '${AWS_PROFILE_NAME}'."
fi

echo "Validating Spark import..."
python - <<'PY'
from pyspark.sql import SparkSession

spark = (
    SparkSession.builder
    .master("local[*]")
    .appName("local-validation")
    .getOrCreate()
)
print(f"Spark version: {spark.version}")
spark.stop()
PY

cat <<'EOF'

Setup completed.

Next steps:
  1. source .venv/bin/activate
  2. aws configure
  3. python -m jobs.sample_job --input-path s3a://your-bucket/path/

EOF
