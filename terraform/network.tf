# =============================================================================
# Rete: VPC custom (nessuna subnet automatica) con due subnet separate
#   - "public"  : VM MongoDB, con IP pubblico e SSH aperto (zona "esposta")
#   - "private" : nodi GKE, senza IP pubblico, uscita controllata via Cloud NAT
# Piu' le regole firewall che definiscono cosa e' raggiungibile e da dove.
# =============================================================================

# VPC custom: auto_create_subnetworks=false perche' vogliamo definire noi le subnet
# (in una VPC "auto" GCP creerebbe una subnet per ogni regione, senza controllo).
resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

# Subnet PUBBLICA: ospita la VM MongoDB. E' qui che vive la superficie esposta.
resource "google_compute_subnetwork" "public" {
  name                     = "${var.name_prefix}-public"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.1.0/24"
  private_ip_google_access = true # la VM raggiunge le API Google (Secret Manager, GCS) sulla rete Google

  # VPC Flow Logs anche qui: e' la subnet ESPOSTA, quella dove servono di piu'
  # (chi si connette alla 22, verso dove esce il traffico della VM).
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Subnet PRIVATA: ospita i nodi GKE.
resource "google_compute_subnetwork" "private" {
  name                     = "${var.name_prefix}-gke-private"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.16.0/20"
  private_ip_google_access = true # i nodi raggiungono le API Google (Artifact Registry, Secret Manager) SENZA IP pubblico

  # Range secondari VPC-native: IP separati per i pod e per i service del cluster.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }

  # VPC Flow Logs: registra i flussi di rete della subnet (visibilita'/forensics).
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Cloud Router + Cloud NAT: danno ai nodi privati l'uscita verso INTERNET pubblico
# (es. aggiornamenti di sistema, API esterne). NB: i pull da Artifact Registry e le
# chiamate alle API Google passano invece da Private Google Access, non dal NAT.
resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"           # Google assegna gli IP di NAT automaticamente
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS" # NAT solo per le subnet elencate sotto

  # Solo la subnet privata esce via NAT (tutti i suoi range, pod inclusi).
  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY" # logga solo gli errori di NAT (meno rumore)
  }
}

# --- Firewall -------------------------------------------------------------------
# Le regole si applicano alle VM con il tag di rete indicato in target_tags.

# DEBOLEZZA INTENZIONALE: SSH (22) aperto a TUTTO internet (0.0.0.0/0) sulla VM Mongo.
# E' uno dei punti d'ingresso richiesti dall'esercizio. log_config = tutti i tentativi
# finiscono nei firewall log (si vedono gli accessi/scan da IP ignoti).
resource "google_compute_firewall" "ssh_from_internet" {
  name          = "${var.name_prefix}-allow-ssh-from-internet"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["mongo"] # si applica alla sola VM Mongo (tag "mongo")

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Controllo CORRETTO: la porta di MongoDB (27017) e' raggiungibile SOLO dalla rete
# Kubernetes (range dei nodi + range dei pod), non da internet. Cosi' il DB non e'
# esposto direttamente: ci arriva solo l'app dal cluster.
resource "google_compute_firewall" "mongo_from_gke" {
  name        = "${var.name_prefix}-allow-mongo-from-gke"
  network     = google_compute_network.vpc.id
  direction   = "INGRESS"
  target_tags = ["mongo"]
  source_ranges = [
    google_compute_subnetwork.private.ip_cidr_range,                       # nodi GKE
    google_compute_subnetwork.private.secondary_ip_range[0].ip_cidr_range, # pod GKE
  ]

  allow {
    protocol = "tcp"
    ports    = ["27017"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
