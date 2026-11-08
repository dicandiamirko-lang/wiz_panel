variable "project_id" {
  description = "ID del progetto GCP (Wiz CloudLabs)"
  type        = string
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "zone" {
  type    = string
  default = "europe-west1-b"
}

variable "name_prefix" {
  type    = string
  default = "wiz"
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
  type    = string
  default = "e2-medium"
}

# --- GKE ------------------------------------------------------------------------
variable "gke_node_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "gke_node_count" {
  type    = number
  default = 2
}

variable "gke_master_authorized_cidr" {
  description = "CIDR autorizzato a raggiungere l'API server GKE. 0.0.0.0/0 perche' i runner GitHub hostati hanno IP dinamici."
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
