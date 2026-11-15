# =============================================================================
# Variabili del bootstrap. Si passano da riga di comando al primo apply, es.:
#   terraform apply -var="project_id=clgcporg10-158" -var="github_repo=owner/nome"
# =============================================================================

variable "project_id" {
  description = "ID del progetto GCP fornito da Wiz CloudLabs"
  type        = string
}

variable "region" {
  description = "Regione GCP"
  type        = string
  default     = "europe-west1"
}

variable "github_repo" {
  description = "Repository GitHub (owner/nome). Vincola la federazione OIDC: solo i workflow di questo repo potranno autenticarsi a GCP."
  type        = string
}
