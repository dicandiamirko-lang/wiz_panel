# -----------------------------------------------------------------------------
# GKE: cluster con nodi privati (nessun IP pubblico) nella subnet privata.
# L'endpoint del control plane resta pubblico (limitato da authorized networks)
# per permettere kubectl dalla pipeline GitHub e durante la demo.
# -----------------------------------------------------------------------------

resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-nodes"
  display_name = "GKE nodes (least privilege)"
}

resource "google_project_iam_member" "gke_nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "gke" {
  name     = "${var.name_prefix}-gke"
  location = var.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.private.id

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.gke_master_authorized_cidr
      display_name = "authorized"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    http_load_balancing {
      disabled = false # necessario per Ingress -> Google Cloud Load Balancer
    }
  }

  dynamic "binary_authorization" {
    for_each = var.enable_binary_authorization ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS", "APISERVER"]
  }

  depends_on = [google_compute_router_nat.nat]
}

resource "google_container_node_pool" "default" {
  name       = "default-pool"
  cluster    = google_container_cluster.gke.id
  location   = var.zone
  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_node_machine_type
    disk_size_gb    = 50
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# --- Artifact Registry ----------------------------------------------------------
resource "google_artifact_registry_repository" "apps" {
  repository_id = "${var.name_prefix}-apps"
  location      = var.region
  format        = "DOCKER"
  description   = "Immagini dell'applicazione Tasky"
}
