# -----------------------------------------------------------------------------
# Credenziali generate da Terraform e salvate in Secret Manager.
# - La VM le legge all'avvio (la sua SA ha accesso)
# - La pipeline applicativa legge mongodb-uri e jwt-secret e crea il Secret K8s
# NB: i valori finiscono anche nello state Terraform -> il bucket di state e' privato.
# -----------------------------------------------------------------------------

resource "random_password" "mongo_admin" {
  length  = 24
  special = false
}

resource "random_password" "mongo_app" {
  length  = 24
  special = false
}

resource "random_password" "jwt" {
  length  = 32
  special = false
}

locals {
  secrets = {
    "mongo-admin-password" = random_password.mongo_admin.result
    "mongo-app-password"   = random_password.mongo_app.result
    "app-jwt-secret"       = random_password.jwt.result
    "mongodb-uri"          = "mongodb://tasky:${random_password.mongo_app.result}@${google_compute_address.mongo_internal.address}:27017/go-mongodb?authSource=go-mongodb"
  }
}

resource "google_secret_manager_secret" "s" {
  for_each  = local.secrets
  secret_id = each.key

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "s" {
  for_each    = local.secrets
  secret      = google_secret_manager_secret.s[each.key].id
  secret_data = each.value
}
