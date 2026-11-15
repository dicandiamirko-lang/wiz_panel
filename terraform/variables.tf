# =============================================================================
# Variabili di input della configurazione principale.
# I valori reali arrivano dalla pipeline (TF_VAR_*) o da terraform.tfvars.
# =============================================================================

variable "project_id" {
  description = "ID del progetto GCP (Wiz CloudLabs)"
  type        = string
}

variable "region" {
  description = "Regione delle risorse regionali (subnet, bucket, VM). Vincolata a europe-west1 dalle org policy del lab."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zona per le risorse zonali (VM, cluster GKE zonale)."
  type        = string
  default     = "europe-west1-b"
}

variable "name_prefix" {
  description = "Prefisso applicato ai nomi delle risorse (es. wiz-vpc, wiz-gke)."
  type        = string
  default     = "wiz"
}

# --- VM MongoDB -----------------------------------------------------------------
variable "mongo_vm_image" {
  description = "Immagine Linux obsoleta (1+ anno). Ubuntu 22.04 LTS: rilasciata ad aprile 2022, superata da 24.04."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "mongo_version" {
  description = "Serie MongoDB obsoleta (1+ anno). La 6.0 e' fuori supporto da luglio 2025."
  type        = string
  default     = "6.0"
}

variable "mongo_vm_machine_type" {
  description = "Tipo macchina della VM MongoDB (dimensionamento/costo)."
  type        = string
  default     = "e2-medium"
}

# --- GKE ------------------------------------------------------------------------
variable "gke_node_machine_type" {
  description = "Tipo macchina dei nodi GKE."
  type        = string
  default     = "e2-standard-2"
}

variable "gke_node_count" {
  description = "Numero di nodi nel node pool di default."
  type        = number
  default     = 2
}

variable "gke_master_authorized_cidr" {
  description = "CIDR autorizzato a raggiungere l'API server GKE. 0.0.0.0/0 perche' i runner GitHub hostati hanno IP dinamici (debolezza voluta: in prod va ristretto)."
  type        = string
  default     = "0.0.0.0/0"
}

# --- Controlli di sicurezza -----------------------------------------------------
variable "alert_email" {
  description = "Email che riceve gli alert dei controlli detective (vuoto = nessuna notifica, solo incident in console)"
  type        = string
  default     = ""
}

variable "enable_org_policies" {
  description = "Applica Organization Policy a livello di progetto. Richiede roles/orgpolicy.policyAdmin: abilitalo solo se CloudLabs lo concede."
  type        = bool
  default     = false
}

variable "enable_binary_authorization" {
  description = "Controllo preventivo: GKE accetta solo immagini dal nostro Artifact Registry"
  type        = bool
  default     = true
}
