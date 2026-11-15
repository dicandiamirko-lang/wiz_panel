# =============================================================================
# BOOTSTRAP - si esegue UNA VOLTA in locale (con state LOCALE) prima delle pipeline.
# E' il "gancio" che permette a GitHub Actions di operare su GCP senza chiavi. Crea:
#   - le API GCP necessarie;
#   - il bucket GCS che conterra' lo state remoto delle pipeline;
#   - Workload Identity Federation (OIDC) GitHub -> GCP: NESSUNA chiave JSON da ruotare;
#   - due service account SEPARATE (separation of duties):
#       * gh-iac-deployer : usata dalla pipeline IaC (Terraform)
#       * gh-app-deployer : usata dalla pipeline applicativa (build/push/deploy)
# Nota: deve girare per primo perche' tutto il resto dipende dal bucket di state
# e dalle identita' create qui.
# =============================================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
  # NB: nessun backend remoto qui -> lo state del bootstrap e' LOCALE (e' lui a
  # creare il bucket che gli altri useranno come backend).
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  # API da abilitare sul progetto: ognuna serve a una parte dello stack (compute,
  # GKE, registry, secret, IAM/STS per OIDC, logging/monitoring, SCC, binauthz...).
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com", # Security Token Service: scambio del token OIDC
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

  # Ruoli della SA della pipeline IaC: deve poter creare tutta l'infrastruttura.
  # (editor + alcuni admin mirati). E' potente per natura: per questo la sua
  # identita' e' legata al solo repository via OIDC, senza chiavi.
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

  # Ruoli della SA della pipeline App: MOLTO piu' stretti della IaC.
  # Solo: push su Artifact Registry, deploy su GKE (vedi nota), lettura segreti.
  app_roles = [
    "roles/artifactregistry.writer",
    "roles/container.admin", # necessario per creare la ClusterRoleBinding cluster-admin richiesta dall'esercizio
    "roles/secretmanager.secretAccessor",
  ]
}

# Abilita tutte le API elencate. disable_on_destroy=false: il destroy non le
# disabilita (evita rotture se altre risorse del progetto le usano ancora).
resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

# --- Bucket per lo state remoto ------------------------------------------------
# Lo state contiene valori sensibili (password generate): qui e' PRIVATO
# (public_access_prevention=enforced) e versionato (recupero dopo errori).
resource "google_storage_bucket" "tfstate" {
  name                        = "${var.project_id}-wiz-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced" # opposto del bucket di backup: qui NIENTE accesso pubblico
  force_destroy               = true

  versioning {
    enabled = true
  }
}

# --- Workload Identity Federation per GitHub Actions ---------------------------
# Il "pool" raccoglie le identita' esterne (GitHub) che possono federarsi con GCP.
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

# Il provider OIDC: si fida dei token firmati da GitHub Actions e ne mappa i campi.
resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  # Mappa i claim del token GitHub su attributi GCP (repo, ref, actor...).
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.actor"      = "assertion.actor"
  }

  # CONDIZIONE DI FIDUCIA: solo i token emessi per QUESTO repository sono accettati.
  # Senza questa riga, qualunque repo GitHub potrebbe tentare la federazione.
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

# Assegna alla SA IaC i ruoli elencati sopra.
resource "google_project_iam_member" "iac" {
  for_each = toset(local.iac_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.iac.email}"
}

# Collega l'identita' federata del repo alla SA IaC: solo i workflow di QUESTO
# repository possono "impersonare" gh-iac-deployer (principalSet legato al repo).
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

# Stessa federazione per la SA App: solo i workflow di questo repo la usano.
resource "google_service_account_iam_member" "app_wif" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}
