# -----------------------------------------------------------------------------
# Bucket dei backup MongoDB
# DEBOLEZZA INTENZIONALE: lettura e listing pubblici (allUsers).
# Chiunque puo' elencare e scaricare i dump del database, inclusi gli hash
# delle password degli utenti dell'applicazione.
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "backups" {
  name                        = "${var.project_id}-mongo-backups"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "inherited" # "enforced" bloccherebbe l'accesso pubblico
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
}

# storage.objectViewer include storage.objects.get + storage.objects.list
# => lettura pubblica E listing pubblico
resource "google_storage_bucket_iam_member" "backups_public" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "backups_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.mongo_vm.email}"
}
