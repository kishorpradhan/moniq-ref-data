# GCP Secret Manager

This Terraform creates Secret Manager secret containers and IAM access for the S3 to Cloud SQL loader.

It intentionally does **not** create `google_secret_manager_secret_version` resources. Secret payloads added through Terraform are stored in Terraform state, even when marked sensitive. Keep the actual AWS keys and database password out of Terraform.

## Usage

```bash
cd terraform/gcp-secret-manager
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

After apply, add only the missing AWS secret values out of band:

```bash
printf '%s' 'YOUR_AWS_ACCESS_KEY_ID' | gcloud secrets versions add aws-access-key-id \
  --project moniq-490803 \
  --data-file=-

printf '%s' 'YOUR_AWS_SECRET_ACCESS_KEY' | gcloud secrets versions add aws-secret-access-key \
  --project moniq-490803 \
  --data-file=-
```

This configuration reuses the existing `moniq-upload-db-password` secret for `DB_PASSWORD`. Do not add or rotate the database password unless you intentionally want to change the Cloud SQL write-user password.

Use Terraform outputs as GitHub repository variable values:

```text
AWS_ACCESS_KEY_ID_SECRET=aws-access-key-id
AWS_SECRET_ACCESS_KEY_SECRET=aws-secret-access-key
DB_PASSWORD_SECRET=moniq-upload-db-password
```

The Cloud Run runtime service account is granted `roles/secretmanager.secretAccessor` on these secrets.
