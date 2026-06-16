variable "gcp_project_id" {
  description = "GCP project that owns the Secret Manager secrets."
  type        = string
}

variable "gcp_region" {
  description = "Default GCP region for provider operations."
  type        = string
  default     = "us-central1"
}

variable "enable_required_apis" {
  description = "Whether Terraform should enable the Secret Manager API."
  type        = bool
  default     = true
}

variable "secret_ids" {
  description = "Secret Manager secret IDs to create. Values are secret names only; secret payloads are added outside Terraform."
  type = object({
    aws_access_key_id     = string
    aws_secret_access_key = string
    db_password           = string
  })
  default = {
    aws_access_key_id     = "aws-access-key-id"
    aws_secret_access_key = "aws-secret-access-key"
    db_password           = "moniq-upload-db-password"
  }
}

variable "runtime_service_account_email" {
  description = "Cloud Run Job runtime service account email that needs to read these secrets."
  type        = string
}

variable "additional_secret_accessor_service_account_emails" {
  description = "Additional service account emails that should be able to read the secrets. Use sparingly."
  type        = set(string)
  default     = []
}

variable "labels" {
  description = "Labels applied to created secrets."
  type        = map(string)
  default = {
    managed_by = "terraform"
    workload   = "s3-to-cloudsql-loader"
  }
}
