# -----------------------------------------------------------------------------
# IP statico GLOBALE per il Load Balancer esterno creato dall'Ingress GKE.
#
# Serve per l'HTTPS: il certificato Google-managed si emette su un hostname, e
# noi usiamo nip.io (<IP-con-trattini>.nip.io), che risolve esattamente a questo
# IP. Riservandolo qui:
#   - l'IP non cambia a ogni redeploy dell'Ingress (l'hostname resta stabile);
#   - il nome "${var.name_prefix}-tasky-ip" e' referenziato dall'annotazione
#     dell'Ingress (kubernetes.io/ingress.global-static-ip-name) e dalla pipeline
#     app.yml, che da questo IP ricava l'hostname nip.io per il ManagedCertificate.
#
# NB: e' un IP esterno globale (richiesto dall'HTTP(S) LB globale del GKE Ingress
# classe "gce"). Il destroy lo rimuove insieme al resto dello stack.
# -----------------------------------------------------------------------------
resource "google_compute_global_address" "tasky_lb" {
  name = "${var.name_prefix}-tasky-ip"
}
