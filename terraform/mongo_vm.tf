# -----------------------------------------------------------------------------
# VM con MongoDB obsoleto
#   - Linux 1+ anno obsoleto                         (var.mongo_vm_image)
#   - SSH aperto a internet                          (network.tf)
#   - permessi cloud eccessivi: puo' creare VM       (DEBOLEZZA INTENZIONALE)
#   - MongoDB 1+ anno obsoleto, auth attiva, 27017 solo da GKE
#   - backup giornaliero su bucket pubblico          (backup_bucket.tf)
# -----------------------------------------------------------------------------

resource "google_service_account" "mongo_vm" {
  account_id   = "${var.name_prefix}-mongo-vm"
  display_name = "MongoDB VM (overly permissive)"
}

# DEBOLEZZA INTENZIONALE: compute.admin + serviceAccountUser.
# Chi compromette la VM (es. via SSH esposto) puo' creare nuove VM e
# agganciarvi qualunque service account del progetto -> privilege escalation.
resource "google_project_iam_member" "mongo_vm_overly_permissive" {
  for_each = toset([
    "roles/compute.admin",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mongo_vm.email}"
}

resource "google_project_iam_member" "mongo_vm_logging" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.mongo_vm.email}"
}

resource "google_secret_manager_secret_iam_member" "mongo_vm" {
  for_each  = toset(["mongo-admin-password", "mongo-app-password"])
  secret_id = google_secret_manager_secret.s[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.mongo_vm.email}"
}

resource "google_compute_address" "mongo" {
  name   = "${var.name_prefix}-mongo-ip"
  region = var.region
}

# IP interno statico: la connection string in Secret Manager non dipende dalla VM
resource "google_compute_address" "mongo_internal" {
  name         = "${var.name_prefix}-mongo-internal-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.public.id
  address_type = "INTERNAL"
  address      = "10.10.1.10"
}

resource "google_compute_instance" "mongo" {
  name         = "${var.name_prefix}-mongo-vm"
  machine_type = var.mongo_vm_machine_type
  zone         = var.zone
  tags         = ["mongo"]

  boot_disk {
    initialize_params {
      image = var.mongo_vm_image
      size  = 20
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.public.id
    network_ip = google_compute_address.mongo_internal.address
    access_config {
      nat_ip = google_compute_address.mongo.address
    }
  }

  service_account {
    email  = google_service_account.mongo_vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/scripts/mongo-startup.sh.tpl", {
      mongo_version = var.mongo_version
      backup_bucket = google_storage_bucket.backups.name
      admin_secret  = "mongo-admin-password"
      app_secret    = "mongo-app-password"
      project_id    = var.project_id
    })
  }

  # Password e permessi devono esistere prima che lo startup script li legga
  depends_on = [
    google_secret_manager_secret_version.s,
    google_secret_manager_secret_iam_member.mongo_vm,
    google_storage_bucket_iam_member.backups_writer,
  ]

  allow_stopping_for_update = true
}
