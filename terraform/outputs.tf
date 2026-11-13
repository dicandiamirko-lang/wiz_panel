output "mongo_vm_public_ip" {
  value = google_compute_address.mongo.address
}

output "mongo_vm_internal_ip" {
  value = google_compute_address.mongo_internal.address
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.mongo.name} --zone ${var.zone} --project ${var.project_id}"
}

output "backup_bucket_public_listing_url" {
  value = "https://storage.googleapis.com/${google_storage_bucket.backups.name}"
}

output "gke_cluster_name" {
  value = google_container_cluster.gke.name
}

output "gke_get_credentials" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.gke.name} --zone ${var.zone} --project ${var.project_id}"
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

# IP statico globale del LB dell'app e hostname/URL HTTPS (nip.io).
output "app_lb_ip" {
  value = google_compute_global_address.tasky_lb.address
}

output "app_hostname" {
  value = "${replace(google_compute_global_address.tasky_lb.address, ".", "-")}.nip.io"
}

output "app_url" {
  value = "https://${replace(google_compute_global_address.tasky_lb.address, ".", "-")}.nip.io"
}
