terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {
    bucket = "moniq-490803-terraform-state"
    prefix = "moniq-reference-data/gcp-cloudsql-loader"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
