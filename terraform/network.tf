# -----------------------------------------------------------------------------
# Rete: VPC custom con
#   - subnet "public"  : VM MongoDB (IP pubblico, SSH aperto)
#   - subnet "private" : nodi GKE (nessun IP pubblico, uscita via Cloud NAT)
# -----------------------------------------------------------------------------

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "public" {
  name          = "${var.name_prefix}-public"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.1.0/24"
}

resource "google_compute_subnetwork" "private" {
  name                     = "${var.name_prefix}-gke-private"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.16.0/20"
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Uscita internet per i nodi privati (pull immagini, ecc.)
resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Firewall -------------------------------------------------------------------

# DEBOLEZZA INTENZIONALE: SSH esposto a tutto internet
resource "google_compute_firewall" "ssh_from_internet" {
  name          = "${var.name_prefix}-allow-ssh-from-internet"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mongo"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# MongoDB raggiungibile SOLO dalla rete Kubernetes (nodi + pod)
resource "google_compute_firewall" "mongo_from_gke" {
  name        = "${var.name_prefix}-allow-mongo-from-gke"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  target_tags = ["mongo"]
  source_ranges = [
    google_compute_subnetwork.private.ip_cidr_range,
    google_compute_subnetwork.private.secondary_ip_range[0].ip_cidr_range,
  ]

  allow {
    protocol = "tcp"
    ports    = ["27017"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
