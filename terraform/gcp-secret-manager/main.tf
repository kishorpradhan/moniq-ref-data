locals {
  secret_ids = {
    aws_access_key_id     = var.secret_ids.aws_access_key_id
    aws_secret_access_key = var.secret_ids.aws_secret_access_key
    db_password           = var.secret_ids.db_password
  }

  secret_accessor_service_account_emails = setunion(
    [var.runtime_service_account_email],
    var.additional_secret_accessor_service_account_emails,
  )

  secret_access_bindings = {
    for binding in flatten([
      for secret_key, secret_id in local.secret_ids : [
        for service_account_email in local.secret_accessor_service_account_emails : {
          key                   = "${secret_key}:${service_account_email}"
          secret_key            = secret_key
          service_account_email = service_account_email
        }
      ]
    ]) : binding.key => binding
  }
}

resource "google_project_service" "secretmanager" {
  count = var.enable_required_apis ? 1 : 0

  project            = var.gcp_project_id
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_secret_manager_secret" "loader" {
  for_each = local.secret_ids

  secret_id = each.value
  labels    = var.labels

  replication {
    auto {}
  }

  depends_on = [
    google_project_service.secretmanager,
  ]

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "loader_accessor" {
  for_each = local.secret_access_bindings

  project   = var.gcp_project_id
  secret_id = google_secret_manager_secret.loader[each.value.secret_key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.service_account_email}"
}
