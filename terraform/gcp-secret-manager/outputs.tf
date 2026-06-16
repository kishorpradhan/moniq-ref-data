output "secret_ids" {
  description = "Secret IDs to use as GitHub repository variable values for *_SECRET settings."
  value       = local.secret_ids
}

output "secret_resource_names" {
  description = "Full Secret Manager resource names."
  value = {
    for key, secret in google_secret_manager_secret.loader : key => secret.name
  }
}

output "secret_accessor_service_account_emails" {
  description = "Service accounts granted roles/secretmanager.secretAccessor on these secrets."
  value       = local.secret_accessor_service_account_emails
}
