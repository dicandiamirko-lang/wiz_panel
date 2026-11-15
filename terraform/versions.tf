# =============================================================================
# Requisiti del progetto Terraform: versione di Terraform, provider usati e
# backend dove vive lo stato remoto.
# =============================================================================

terraform {
  required_version = ">= 1.6" # versione minima di Terraform

  # Provider usati e vincoli di versione (~> blocca la major, consente le minor).
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0" # provider ufficiale Google Cloud
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6" # genera le password casuali (secrets.tf)
    }
  }

  # STATO REMOTO su Google Cloud Storage: lo state (che contiene valori sensibili)
  # non resta sul PC. Il nome del bucket NON e' qui: viene passato a init per non
  # fissare il project id nel codice ->
  #   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
  # "prefix" e' la cartella dentro il bucket in cui vive questo state.
  backend "gcs" {
    prefix = "wiz-exercise"
  }
}

# Configurazione del provider Google: progetto/regione/zona di default per tutte
# le risorse, presi dalle variabili.
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
