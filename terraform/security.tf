# =============================================================================
# CLOUD NATIVE SECURITY
#   1. Audit logging del control plane (+ conservazione in un log bucket dedicato)
#   2. Controlli PREVENTIVI  : Binary Authorization (+ Org Policy opzionali)
#   3. Controlli DETECTIVE   : alert Cloud Monitoring su eventi di audit
# =============================================================================

# -----------------------------------------------------------------------------
# 1. AUDIT LOGGING
# Gli "Admin Activity" audit log (modifiche al control plane) sono sempre attivi
# su GCP. Qui abilitiamo anche i "Data Access" log, disattivati di default.
# I log di audit del control plane Kubernetes (k8s.io) arrivano in automatico
# da GKE in Cloud Audit Logs.
# -----------------------------------------------------------------------------
resource "google_project_iam_audit_config" "all_services" {
  project = var.project_id
  service = "allServices"

  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

resource "google_project_iam_audit_config" "sensitive_reads" {
  for_each = toset([
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
  ])
  project = var.project_id
  service = each.value

  audit_log_config {
    log_type = "DATA_READ"
  }
}

# Log bucket dedicato con retention di 90 giorni per tutti gli audit log
resource "google_logging_project_bucket_config" "audit" {
  project        = var.project_id
  location       = var.region # l'org policy del lab vieta "global"; europe-west1 e' tra le location consentite
  bucket_id      = "audit-logs"
  retention_days = 90
  description    = "Copia conservata di tutti i Cloud Audit Logs"
}

resource "google_logging_project_sink" "audit" {
  name                   = "audit-logs-sink"
  destination            = "logging.googleapis.com/${google_logging_project_bucket_config.audit.id}"
  filter                 = "logName:\"cloudaudit.googleapis.com\""
  unique_writer_identity = true
}

# -----------------------------------------------------------------------------
# 2a. PREVENTIVO - Binary Authorization
# GKE rifiuta qualunque immagine che non provenga dal nostro Artifact Registry.
# Demo: `kubectl run test --image=nginx` -> negato.
# -----------------------------------------------------------------------------
resource "google_binary_authorization_policy" "policy" {
  count = var.enable_binary_authorization ? 1 : 0

  # Consente le immagini di sistema gestite da Google (kube-system, ecc.)
  global_policy_evaluation_mode = "ENABLE"

  admission_whitelist_patterns {
    name_pattern = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}/**"
  }

  default_admission_rule {
    evaluation_mode  = "ALWAYS_DENY"
    enforcement_mode = "ENFORCED_BLOCK_AND_AUDIT_LOG"
  }
}

# -----------------------------------------------------------------------------
# 2b. PREVENTIVO - Organization Policy a livello di progetto (opzionali)
# Richiedono roles/orgpolicy.policyAdmin, che un account sandbox potrebbe non avere.
# -----------------------------------------------------------------------------
resource "google_org_policy_policy" "disable_sa_keys" {
  count  = var.enable_org_policies ? 1 : 0
  name   = "projects/${var.project_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "resource_locations" {
  count  = var.enable_org_policies ? 1 : 0
  name   = "projects/${var.project_id}/policies/gcp.resourceLocations"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      values {
        allowed_values = ["in:eu-locations"]
      }
    }
  }
}

# -----------------------------------------------------------------------------
# 3. DETECTIVE - alert basati sugli audit log
# -----------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  display_name = "Security alerts"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

locals {
  log_alerts = {
    public-bucket = {
      name   = "[SEC] Bucket reso pubblico"
      filter = "protoPayload.methodName=\"storage.setIamPermissions\" AND (protoPayload.serviceData.policyDelta.bindingDeltas.member=\"allUsers\" OR protoPayload.serviceData.policyDelta.bindingDeltas.member=\"allAuthenticatedUsers\")"
      doc    = "Un bucket Cloud Storage e' stato esposto a allUsers/allAuthenticatedUsers."
    }
    firewall-open-internet = {
      name   = "[SEC] Regola firewall aperta a 0.0.0.0/0"
      filter = "resource.type=\"gce_firewall_rule\" AND protoPayload.methodName=~\"compute.firewalls.(insert|patch|update)\" AND protoPayload.request.sourceRanges=\"0.0.0.0/0\""
      doc    = "E' stata creata/modificata una regola firewall che accetta traffico da tutto internet."
    }
    project-iam-change = {
      name   = "[SEC] Modifica IAM a livello di progetto"
      filter = "resource.type=\"project\" AND protoPayload.methodName=\"SetIamPolicy\""
      doc    = "La policy IAM del progetto e' stata modificata."
    }
    sa-key-created = {
      name   = "[SEC] Creata chiave per service account"
      filter = "protoPayload.methodName=\"google.iam.admin.v1.CreateServiceAccountKey\""
      doc    = "Creata una chiave statica per un service account (rischio di credenziali di lunga durata)."
    }
    k8s-exec = {
      name   = "[SEC] kubectl exec in un pod"
      filter = "resource.type=\"k8s_cluster\" AND protoPayload.methodName=\"io.k8s.core.v1.pods.exec.create\""
      doc    = "Qualcuno ha aperto una shell/eseguito un comando in un container."
    }
    binauthz-deny = {
      name   = "[SEC] Immagine bloccata da Binary Authorization"
      filter = "resource.type=\"k8s_cluster\" AND protoPayload.response.message:\"Binary Authorization\""
      doc    = "Tentativo di deploy di un'immagine non consentita."
    }
  }
}

resource "google_monitoring_alert_policy" "log_alerts" {
  for_each     = local.log_alerts
  display_name = each.value.name
  combiner     = "OR"

  conditions {
    display_name = each.value.name
    condition_matched_log {
      filter = each.value.filter
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }

  documentation {
    content   = each.value.doc
    mime_type = "text/markdown"
  }

  notification_channels = var.alert_email == "" ? [] : [google_monitoring_notification_channel.email[0].id]
}
