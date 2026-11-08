# Questi valori vanno inseriti come "Variables" del repository GitHub
# (Settings > Secrets and variables > Actions > Variables)

output "GCP_PROJECT_ID" {
  value = var.project_id
}

output "GCP_REGION" {
  value = var.region
}

output "TF_STATE_BUCKET" {
  value = google_storage_bucket.tfstate.name
}

output "GCP_WIF_PROVIDER" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "GCP_IAC_SA" {
  value = google_service_account.iac.email
}

output "GCP_APP_SA" {
  value = google_service_account.app.email
}
