# =============================================================================
# Bucket Cloud Storage dei backup di MongoDB.
# DEBOLEZZA INTENZIONALE: lettura e listing PUBBLICI (allUsers).
# Chiunque, senza autenticazione, puo' elencare e scaricare i dump del database,
# inclusi i dati degli utenti e gli hash delle password. E' meta' della "toxic
# combination": storage pubblico + dati sensibili.
# =============================================================================

resource "google_storage_bucket" "backups" {
  name                        = "${var.project_id}-mongo-backups"
  location                    = var.region
  uniform_bucket_level_access = true        # accesso gestito solo via IAM (niente ACL per-oggetto)
  public_access_prevention    = "inherited" # VOLUTO: "enforced" bloccherebbe allUsers e chiuderebbe la debolezza
  force_destroy               = true        # il lab va distrutto/ricreato: permette di eliminare il bucket pieno

  # Ciclo di vita: i backup piu' vecchi di 30 giorni vengono cancellati da soli
  # (contiene i costi e limita quanti dump restano esposti).
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  # Usage/access logs: registra OGNI richiesta al bucket (IP, oggetto, esito),
  # incluse quelle ANONIME. E' il controllo detective che serve qui: i Data Access
  # audit log non registrano gli accessi pubblici (allUsers), gli usage log si'.
  # Il bucket resta pubblico (debolezza voluta), ma ora si vede chi scarica i dump.
  logging {
    log_bucket        = google_storage_bucket.access_logs.name
    log_object_prefix = "mongo-backups/"
  }
}

# Bucket PRIVATO che riceve gli usage log del bucket dei backup.
resource "google_storage_bucket" "access_logs" {
  name                        = "${var.project_id}-access-logs"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced" # nessun accesso pubblico ai log
  force_destroy               = true

  versioning {
    enabled = true # protegge i log da sovrascritture/cancellazioni accidentali
  }

  # Conserva i log 90 giorni (come gli audit log), poi li elimina.
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}

# Google scrive gli usage log tramite il gruppo di servizio cloud-storage-analytics:
# gli serve solo il permesso di creare oggetti nel bucket dei log.
resource "google_storage_bucket_iam_member" "access_logs_writer" {
  bucket = google_storage_bucket.access_logs.name
  role   = "roles/storage.objectCreator"
  member = "group:cloud-storage-analytics@google.com"
}

# LA riga che rende il bucket pubblico: allUsers (chiunque su internet) con il
# ruolo objectViewer = storage.objects.get + storage.objects.list -> lettura E
# elenco degli oggetti. E' questa la misconfigurazione che l'esercizio richiede.
resource "google_storage_bucket_iam_member" "backups_public" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Permesso di SCRITTURA (solo creazione oggetti) per la service account della VM:
# e' cio' che le serve per caricare i dump giornalieri. Niente di piu'.
resource "google_storage_bucket_iam_member" "backups_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.mongo_vm.email}"
}
