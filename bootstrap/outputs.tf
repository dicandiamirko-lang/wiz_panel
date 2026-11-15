# =============================================================================
# Output del bootstrap: sono i valori da copiare nelle "Variables" del repository
# GitHub (Settings > Secrets and variables > Actions > Variables). Le pipeline li
# leggono come ${{ vars.NOME }} per autenticarsi e sapere dove operare.
# =============================================================================

output "GCP_PROJECT_ID" {
  description = "Progetto GCP di destinazione."
  value       = var.project_id
}

output "GCP_REGION" {
  description = "Regione di default per le pipeline."
  value       = var.region
}

output "TF_STATE_BUCKET" {
  description = "Bucket dello state remoto (passato a 'terraform init -backend-config')."
  value       = google_storage_bucket.tfstate.name
}

output "GCP_WIF_PROVIDER" {
  description = "Provider Workload Identity Federation usato dal login OIDC nei workflow."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "GCP_IAC_SA" {
  description = "Service account impersonata dalla pipeline IaC."
  value       = google_service_account.iac.email
}

output "GCP_APP_SA" {
  description = "Service account impersonata dalla pipeline App."
  value       = google_service_account.app.email
}
