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
  description = "Repository GitHub nel formato owner/nome (es. mirko/wiz-exercise)"
  type        = string
}
