# =============================================================================
# VM MongoDB (database dell'app Tasky) + le sue debolezze INTENZIONALI
#   - Linux obsoleto (1+ anno)                       -> var.mongo_vm_image
#   - SSH 22 aperto a internet                       -> vedi network.tf (firewall)
#   - service account con permessi cloud eccessivi   -> DEBOLEZZA INTENZIONALE
#   - MongoDB obsoleto (1+ anno), auth attiva, 27017 raggiungibile solo da GKE
#   - backup giornaliero verso un bucket pubblico    -> vedi backup_bucket.tf
# Lo stato "vulnerabile" e' richiesto dall'esercizio: non va corretto qui.
# =============================================================================

# Service account DEDICATA alla VM: identita' con cui la VM parla con le API GCP
# (senza chiavi statiche: usa il token servito dal metadata server dell'istanza).
resource "google_service_account" "mongo_vm" {
  account_id   = "${var.name_prefix}-mongo-vm"
  display_name = "MongoDB VM (overly permissive)"
}

# DEBOLEZZA INTENZIONALE: compute.admin + serviceAccountUser.
# compute.admin  -> puo' creare/gestire VM nel progetto.
# serviceAccountUser -> puo' AGGANCIARE a quelle VM un'altra service account.
# Combinati: chi entra nella VM (via SSH esposto) crea una VM che impersona una SA
# piu' potente ed esegue codice come lei -> privilege escalation fino al progetto.
resource "google_project_iam_member" "mongo_vm_overly_permissive" {
  for_each = toset([
    "roles/compute.admin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mongo_vm.email}"
}

# Permessi MINIMI e legittimi: la VM scrive i propri log e le proprie metriche.
# Non fanno parte della debolezza: servono per audit/osservabilita'.
resource "google_project_iam_member" "mongo_vm_logging" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mongo_vm.email}"
}

# La VM legge SOLO le due password che le servono (admin e utente app) da Secret
# Manager: le credenziali non sono mai scritte nello startup script o su disco.
resource "google_secret_manager_secret_iam_member" "mongo_vm" {
  for_each  = toset(["mongo-admin-password", "mongo-app-password"])
  secret_id = google_secret_manager_secret.s[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mongo_vm.email}"
}

# IP pubblico statico della VM: e' cio' che rende la 22 raggiungibile da internet
# (insieme alla regola firewall in network.tf). In produzione andrebbe rimosso.
resource "google_compute_address" "mongo" {
  name   = "${var.name_prefix}-mongo-ip"
  region = var.region
}

# IP interno statico: cosi' la connection string salvata in Secret Manager punta
# a un indirizzo fisso e non cambia se la VM viene ricreata.
resource "google_compute_address" "mongo_internal" {
  name         = "${var.name_prefix}-mongo-internal-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.public.id
  address_type = "INTERNAL"
  address      = "10.10.1.10"
}

# La VM vera e propria.
resource "google_compute_instance" "mongo" {
  name         = "${var.name_prefix}-mongo-vm"
  machine_type = var.mongo_vm_machine_type
  zone         = var.zone
  tags         = ["mongo"] # il tag "mongo" aggancia le regole firewall (network.tf)

  boot_disk {
    initialize_params {
      image = var.mongo_vm_image # immagine Linux OBSOLETA (debolezza voluta)
      size  = 20
      type  = "pd-balanced"
    }
  }

  # Sta nella subnet PUBBLICA e ha un IP esterno (access_config): esposta a internet.
  network_interface {
    subnetwork = google_compute_subnetwork.public.id
    network_ip = google_compute_address.mongo_internal.address # IP interno fisso
    access_config {
      nat_ip = google_compute_address.mongo.address # IP pubblico fisso
    }
  }

  # Identita' della VM. scopes=cloud-platform insieme ai ruoli IAM sopra e' cio'
  # che rende la SA realmente sfruttabile per l'escalation.
  service_account {
    email  = google_service_account.mongo_vm.email
    scopes = ["cloud-platform"]
  }

  # Script di provisioning eseguito al primo avvio: installa MongoDB, crea gli
  # utenti, abilita l'auth e configura il backup giornaliero (vedi scripts/).
  # templatefile() inietta i valori Terraform nei segnaposto ${...} dello script.
  metadata = {
    startup-script = templatefile("${path.module}/scripts/mongo-startup.sh.tpl", {
      mongo_version = var.mongo_version
      backup_bucket = google_storage_bucket.backups.name
      admin_secret  = "mongo-admin-password"
      app_secret    = "mongo-app-password"
      project_id    = var.project_id
    })
  }

  # Ordine di creazione: password, permessi di lettura segreti e permesso di
  # scrittura sul bucket devono esistere PRIMA che lo startup script parta.
  depends_on = [
    google_secret_manager_secret_version.s,
    google_secret_manager_secret_iam_member.mongo_vm,
    google_storage_bucket_iam_member.backups_writer,
  ]

  allow_stopping_for_update = true # consente a Terraform di spegnere/riavviare per applicare modifiche
}
