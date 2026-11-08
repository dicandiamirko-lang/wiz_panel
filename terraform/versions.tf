terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Il nome del bucket viene passato a runtime:
  #   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
  backend "gcs" {
    prefix = "wiz-exercise"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
