# Cloud Armor (preview) e Sensitive Data Protection (DLP)

Due controlli cloud-native attivati **fuori Terraform** (come SCC), via `gcloud`/REST.
Progetto: `clgcporg10-158` · regione: `europe-west1`.

---

## Cloud Armor — WAF OWASP in preview

### Perché preview e non block
Cloud Armor agisce **solo** sul traffico HTTP(S) che passa dal Load Balancer dell'app.
I vettori d'attacco dell'esercizio **non** passano da lì:

| Debolezza intenzionale | Cloud Armor la vede? |
|---|---|
| SSH aperto sulla VM Mongo | no (L4 sulla VM) |
| Bucket backup pubblico | no (GCS diretto) |
| Container cluster-admin | no (interno al cluster) |
| VM `compute.admin` → escalation | no (piano IAM) |
| Attacco web su Tasky (SQLi/XSS) | sì — ma non è il bersaglio dell'esercizio |

In **block** rischierebbe di (a) rompere l'accesso lecito all'app per falsi positivi
e (b) mascherare l'unico entry point HTTP, facendo sembrare "coperta" una debolezza
che deve restare visibile. In **preview** logga cosa bloccherebbe senza alterare
l'esposizione intenzionale: dimostra la conoscenza del layer edge senza falsare la demo.

### Comandi usati
```bash
# 1. policy
gcloud compute security-policies create tasky-waf-preview \
  --description "WAF OWASP in preview (non bloccante) per Tasky - esercizio Wiz"

# 2. regole OWASP preconfigurate, tutte in --preview (loggano, non bloccano)
gcloud compute security-policies rules create 1000 --security-policy tasky-waf-preview \
  --expression "evaluatePreconfiguredExpr('sqli-v33-stable')"            --action deny-403 --preview
gcloud compute security-policies rules create 1100 --security-policy tasky-waf-preview \
  --expression "evaluatePreconfiguredExpr('xss-v33-stable')"             --action deny-403 --preview
gcloud compute security-policies rules create 1200 --security-policy tasky-waf-preview \
  --expression "evaluatePreconfiguredExpr('lfi-v33-stable')"             --action deny-403 --preview
gcloud compute security-policies rules create 1300 --security-policy tasky-waf-preview \
  --expression "evaluatePreconfiguredExpr('rce-v33-stable')"             --action deny-403 --preview
gcloud compute security-policies rules create 1400 --security-policy tasky-waf-preview \
  --expression "evaluatePreconfiguredExpr('scannerdetection-v33-stable')" --action deny-403 --preview

# 3. collegamento al backend service dell'Ingress (default rule resta allow)
gcloud compute backend-services update k8s1-393ab948-tasky-tasky-80-42f8c9ce \
  --security-policy tasky-waf-preview --global
```
> Il nome del backend service cambia a ogni redeploy del cluster: recuperalo con
> `gcloud compute backend-services list --global`.

### Caveat: possibile reset dal controller Ingress
L'attacco è stato collegato direttamente al backend service via `gcloud`. Il controller
GKE Ingress, in una riconciliazione (modifica a Service/Ingress), **potrebbe rimuovere**
la policy impostata fuori banda. Finché i manifest `k8s/` non cambiano, l'associazione
regge per la demo. Versione permanente/riproducibile = un `BackendConfig` che referenzia
la policy, ma richiede che la policy esista **prima** del deploy (quindi come step di setup,
non nel deploy automatico che partirebbe da zero su un progetto nuovo):
```yaml
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata: { name: tasky-waf, namespace: tasky }
spec:
  securityPolicy: { name: tasky-waf-preview }
---
# + annotazione sul Service:
#   cloud.google.com/backend-config: '{"default": "tasky-waf"}'
```

### Verifica
```bash
gcloud compute security-policies describe tasky-waf-preview \
  --format="table(rules.priority,rules.action,rules.preview)"
```
Tutte le regole OWASP devono avere `preview = True`; la default (`2147483647`) = `allow`.

### Teardown
```bash
gcloud compute backend-services update k8s1-393ab948-tasky-tasky-80-42f8c9ce \
  --security-policy "" --global          # scollega
gcloud compute security-policies delete tasky-waf-preview
```

---

## Sensitive Data Protection (DLP) — inspection del bucket di backup

### Scopo
Qualificare **cosa** contiene il bucket pubblico: un bucket pubblico "vuoto" è basso
rischio, uno con PII/credenziali è critico. È il contesto-dato che trasforma due finding
separati nella **toxic combination** "bucket pubblico + dati sensibili".

### Comando usato (REST — gcloud non ha il comando stabile per i dlpJob)
```bash
TOK=$(gcloud auth print-access-token)
curl -s -X POST \
  "https://dlp.googleapis.com/v2/projects/clgcporg10-158/locations/europe-west1/dlpJobs" \
  -H "Authorization: Bearer $TOK" \
  -H "x-goog-user-project: clgcporg10-158" \
  -H "Content-Type: application/json" \
  -d @docs/examples/dlp-job.json
```
`infoTypes` cercati: EMAIL_ADDRESS, PHONE_NUMBER, IP_ADDRESS, GCP_CREDENTIALS,
AUTH_TOKEN, CREDIT_CARD_NUMBER.

Esito job (`GET .../dlpJobs/<id>`): `state: DONE`, `processedBytes: 2252`, **0 finding**.

### Risultato onesto: perché 0 finding
I backup sono archivi `mongodump --archive --gzip`: un **formato binario** (BSON
compresso). Il DLP scansiona testo e formati strutturati (JSON/CSV/Avro…), non sa
estrarre gli infoType da un dump binario → non trova nulla, pur avendo scansionato i file.

È un punto di valore, non un fallimento: **un controllo detective può dare falsa
tranquillità** se non è adatto al formato del dato. Per far emergere realmente le PII:
- esportare i dati in formato leggibile (`mongoexport` → JSON/CSV) e scansionare quello, oppure
- caricare in BigQuery e usare la **discovery** continua di Sensitive Data Protection.

### Costi
Cloud Armor in preview: ~pochi € (policy + regole, tariffate a richieste ispezionate).
DLP: tariffato a byte ispezionati — qui 2 KB, costo trascurabile.
Entrambi ampiamente dentro il budget del tenant.
