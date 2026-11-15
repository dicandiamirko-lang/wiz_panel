# =============================================================================
# Output: valori utili stampati da "terraform output" dopo l'apply.
# Comodi per la demo (IP, comandi pronti) e letti dalla pipeline (app_hostname).
# =============================================================================

# --- VM MongoDB -----------------------------------------------------------------
output "mongo_vm_public_ip" {
  description = "IP pubblico della VM Mongo (quello su cui la 22 e' esposta)."
  value       = google_compute_address.mongo.address
}

output "mongo_vm_internal_ip" {
  description = "IP interno fisso della VM (a cui punta la connection string)."
  value       = google_compute_address.mongo_internal.address
}

output "ssh_command" {
  description = "Comando pronto per entrare nella VM via SSH."
  value       = "gcloud compute ssh ${google_compute_instance.mongo.name} --zone ${var.zone} --project ${var.project_id}"
}

# --- Bucket di backup -----------------------------------------------------------
output "backup_bucket_public_listing_url" {
  description = "URL del listing pubblico del bucket: dimostra l'esposizione (apri senza login)."
  value       = "https://storage.googleapis.com/${google_storage_bucket.backups.name}"
}

# --- GKE / Registry -------------------------------------------------------------
output "gke_cluster_name" {
  value = google_container_cluster.gke.name
}

output "gke_get_credentials" {
  description = "Comando pronto per configurare kubectl sul cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.gke.name} --zone ${var.zone} --project ${var.project_id}"
}

output "artifact_registry" {
  description = "Percorso del registry Docker dove la pipeline pusha l'immagine."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

# --- App (HTTPS) ----------------------------------------------------------------
# L'IP statico globale del LB e l'hostname/URL HTTPS su nip.io derivato da esso.
# app_hostname e' anche scritto in Secret Manager e letto dalla pipeline di deploy.
output "app_lb_ip" {
  value = google_compute_global_address.tasky_lb.address
}

output "app_hostname" {
  description = "Hostname HTTPS = IP-con-trattini + .nip.io."
  value       = "${replace(google_compute_global_address.tasky_lb.address, ".", "-")}.nip.io"
}

output "app_url" {
  description = "URL pubblico dell'app."
  value       = "https://${replace(google_compute_global_address.tasky_lb.address, ".", "-")}.nip.io"
}
