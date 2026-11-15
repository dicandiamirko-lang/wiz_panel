# =============================================================================
# GKE: cluster Kubernetes che ospita l'app Tasky.
# Scelte di sicurezza:
#   - nodi PRIVATI (nessun IP pubblico): stanno nella subnet privata e escono solo
#     via Cloud NAT / Private Google Access.
#   - control plane con endpoint PUBBLICO (debolezza voluta dell'esercizio) ma
#     limitato dalle authorized networks; serve per kubectl da pipeline e demo.
#   - Workload Identity, Shielded nodes, service account dei nodi a privilegio minimo.
# =============================================================================

# Service account DEI NODI, a privilegio minimo: identita' con cui girano i nodi
# del cluster. Tenerla stretta limita il "blast radius" se un nodo viene compromesso.
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.name_prefix}-gke-nodes"
  display_name = "GKE nodes (least privilege)"
}

# Solo i permessi che i nodi usano davvero: scrivere log/metriche e TIRARE le
# immagini da Artifact Registry (reader). Nessun ruolo ampio tipo editor.
resource "google_project_iam_member" "gke_nodes" {
  for_each = toset([
    "roles/logging.logWriter",       # scrive i log
    "roles/monitoring.metricWriter", # scrive le metriche
    "roles/monitoring.viewer",       # legge le metriche (health)
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader", # pull delle immagini del cluster
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "gke" {
  name     = "${var.name_prefix}-gke"
  location = var.zone # cluster ZONALE (una sola zona): piu' economico per il lab

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.private.id # i nodi vivono nella subnet privata

  # Si rimuove il node pool di default e se ne crea uno gestito sotto, cosi' da
  # controllarne service account, shielding e scopes.
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false # il lab va distrutto/ricreato spesso

  # IP dei pod e dei service presi dai secondary range della subnet (VPC-native).
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true  # i nodi NON hanno IP pubblico
    enable_private_endpoint = false # DEBOLEZZA VOLUTA: endpoint API pubblico
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Chi puo' raggiungere l'endpoint del control plane. var.gke_master_authorized_cidr
  # di default e' 0.0.0.0/0 (aperto): in produzione andrebbe ristretto.
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.gke_master_authorized_cidr
      display_name = "authorized"
    }
  }

  # Workload Identity: i pod usano un'identita' GCP SENZA montare le chiavi del
  # nodo. Blocca l'abuso del metadata server per rubare la SA dei nodi.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR" # upgrade automatici gestiti da Google (canale intermedio)
  }

  addons_config {
    http_load_balancing {
      disabled = false # serve l'addon per far creare all'Ingress il Google Cloud Load Balancer
    }
    network_policy_config {
      disabled = false # addon necessario per applicare le NetworkPolicy (vedi sotto)
    }
  }

  # Network Policy (Calico): abilita l'enforcement delle NetworkPolicy Kubernetes,
  # cioe' la micro-segmentazione tra pod. Senza, un pod compromesso raggiunge tutti
  # gli altri. Finche' non si crea una NetworkPolicy il traffico resta tutto permesso.
  # (Calico invece di Dataplane V2: quest'ultimo richiederebbe di ricreare il cluster.)
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  # Intranode visibility: il traffico tra pod sullo STESSO nodo passa dalla VPC,
  # quindi compare nei VPC Flow Logs e rispetta il firewall (visibilita'/forensics).
  enable_intranode_visibility = true

  # Binary Authorization (opzionale): se attivo, il cluster applica la policy che
  # ammette solo immagini dal nostro Artifact Registry (vedi security.tf).
  dynamic "binary_authorization" {
    for_each = var.enable_binary_authorization ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  # Manda a Cloud Logging i log di sistema, dei workload e dell'API server
  # (questi ultimi servono agli alert tipo "kubectl exec").
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS", "APISERVER"]
  }

  depends_on = [google_compute_router_nat.nat] # il NAT deve esserci prima dei nodi (pull immagini/egress)
}

# Node pool gestito: i worker veri e propri.
resource "google_container_node_pool" "default" {
  name       = "default-pool"
  cluster    = google_container_cluster.gke.id
  location   = var.zone
  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_node_machine_type
    disk_size_gb    = 50
    service_account = google_service_account.gke_nodes.email # la SA a privilegio minimo di sopra
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Shielded VM: avvio verificato (Secure Boot) + controllo integrita'.
    # Difende dal boot di codice non attendibile / rootkit sul nodo.
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # GKE_METADATA = Workload Identity attivo sul nodo: un pod normale non puo'
    # leggere il token della service account del nodo dal metadata server.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true # ripara i nodi guasti
    auto_upgrade = true # applica le patch del control plane ai nodi
  }
}

# --- Artifact Registry ----------------------------------------------------------
# Registro Docker PRIVATO del progetto: la pipeline ci pusha l'immagine Tasky e il
# cluster la tira da qui. Binary Authorization ammette SOLO immagini di questo repo.
resource "google_artifact_registry_repository" "apps" {
  repository_id = "${var.name_prefix}-apps"
  location      = var.region
  format        = "DOCKER"
  description   = "Immagini dell'applicazione Tasky"
}
