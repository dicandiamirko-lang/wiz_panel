# -----------------------------------------------------------------------------
# BOOTSTRAP - da eseguire UNA VOLTA in locale (state locale) prima delle pipeline.
# Crea:
#   - le API necessarie
#   - il bucket GCS per lo state remoto di Terraform
#   - Workload Identity Federation (OIDC) GitHub -> GCP, quindi NESSUNA chiave JSON
#   - due service account separati (separation of duties):
#       * gh-iac-deployer : usato dalla pipeline IaC (Terraform)
#       * gh-app-deployer : usato dalla pipeline applicativa (build/push/deploy)
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "storage.googleapis.com",
    "orgpolicy.googleapis.com",
    "containerscanning.googleapis.com",
    "securitycenter.googleapis.com",
    "binaryauthorization.googleapis.com",
  ]

  iac_roles = [
    "roles/editor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/container.admin",
    "roles/secretmanager.admin",
    "roles/storage.admin",
    "roles/logging.admin",
    "roles/monitoring.admin",
    "roles/binaryauthorization.policyEditor",
  ]

  app_roles = [
    "roles/artifactregistry.writer",
    "roles/container.admin", # serve per creare la ClusterRoleBinding cluster-admin richiesta dall'esercizio
    "roles/secretmanager.secretAccessor",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# --- Bucket per lo state remoto ------------------------------------------------
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-wiz-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = true
  }
}

# --- Workload Identity Federation per GitHub Actions ---------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # Solo i token emessi per QUESTO repository possono autenticarsi
  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- Service account pipeline IaC ----------------------------------------------
resource "google_service_account" "iac" {
  account_id   = "gh-iac-deployer"
  display_name = "GitHub Actions - Terraform"
}

resource "google_project_iam_member" "iac" {
  for_each = toset(local.iac_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.iac.email}"
}

resource "google_service_account_iam_member" "iac_wif" {
  service_account_id = google_service_account.iac.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

# --- Service account pipeline applicativa --------------------------------------
resource "google_service_account" "app" {
  account_id   = "gh-app-deployer"
  display_name = "GitHub Actions - App build & deploy"
}

resource "google_project_iam_member" "app" {
  for_each = toset(local.app_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.app.email}"
}

resource "google_service_account_iam_member" "app_wif" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
