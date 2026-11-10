# Wiz Technical Exercise v4 – GCP

Applicazione web a due livelli (Tasky su GKE + MongoDB su VM) con debolezze di
configurazione **intenzionali**, deploy automatizzato con Terraform e GitHub
Actions, e controlli di sicurezza nativi GCP.

## Architettura

```
                    Internet
        ┌──────────────┼───────────────────────────┐
        │ HTTP         │ SSH (0.0.0.0/0) ⚠         │ lettura/listing pubblici ⚠
        ▼              ▼                           ▼
 ┌──────────────┐ ┌─────────────────────────┐ ┌──────────────────────┐
 │ Cloud HTTP LB│ │ VM wiz-mongo-vm         │ │ GCS <proj>-mongo-    │
 │ (GKE Ingress)│ │ Ubuntu 22.04 ⚠          │ │ backups (allUsers) ⚠ │
 └──────┬───────┘ │ MongoDB 6.0 ⚠ (auth on) │ └──────────▲───────────┘
        │         │ SA: compute.admin ⚠     │──mongodump─┘ cron 02:00
 ┌──────▼───────────────────────┐ subnet public 10.10.1.0/24
 │ GKE wiz-gke (nodi privati)   │ └───────────▲─────────────┘
 │ subnet 10.10.16.0/20         │  tcp/27017 solo da nodi+pod GKE
 │ Deployment tasky             │─────────────┘
 │  SA tasky = cluster-admin ⚠  │
 │  MONGODB_URI da Secret K8s   │
 └──────────────┬───────────────┘
                │ Cloud NAT (uscita)
```
⚠ = debolezza intenzionale richiesta dall'esercizio.

## Struttura del repository

| Percorso | Contenuto |
|---|---|
| `bootstrap/` | Terraform da eseguire una volta in locale: API, bucket state, Workload Identity Federation, SA delle pipeline |
| `terraform/` | Tutta l'infrastruttura (rete, VM, bucket, GKE, Artifact Registry, Secret Manager, controlli di sicurezza) |
| `terraform/scripts/mongo-startup.sh.tpl` | Installa MongoDB, crea gli utenti, abilita l'auth, configura il backup giornaliero |
| `app/` | Applicazione Tasky (Go) + `Dockerfile` + `wizexercise.txt` |
| `k8s/` | Namespace, RBAC (cluster-admin), Deployment, Service, Ingress |
| `.github/workflows/iac.yml` | Pipeline 1: Checkov → plan → apply |
| `.github/workflows/app.yml` | Pipeline 2: build → verifica file → Hadolint → Trivy → ClamAV → push → deploy |
| `.github/workflows/security.yml` | CodeQL + Gitleaks + TruffleHog |
| `docs/demo.md` | Script della demo live |

## Debolezze intenzionali

| Requisito | Dove | Rischio |
|---|---|---|
| Linux obsoleto (Ubuntu 22.04) | `terraform/variables.tf` | CVE del sistema operativo non corrette |
| SSH aperto a internet | `terraform/network.tf` | Brute force, sfruttamento di vulnerabilità di sshd |
| VM con permessi cloud eccessivi | `terraform/mongo_vm.tf` | `compute.admin` + `serviceAccountUser`: chi entra nella VM crea VM con qualunque SA → escalation fino a owner |
| MongoDB obsoleto (6.0, EOL 07/2025) | `terraform/variables.tf` | CVE note del database |
| Backup in bucket pubblico | `terraform/backup_bucket.tf` | Chiunque scarica il dump completo del DB (dati e hash delle password) |
| Container con cluster-admin | `k8s/01-rbac.yaml` | Una RCE nell'app porta al controllo dell'intero cluster |
| Endpoint API GKE raggiungibile da 0.0.0.0/0 | `terraform/gke.tf` | Superficie di attacco del control plane (mitigata da IAM) |
| L'app stampa la connection string nei log | `app/database/database.go` | Password Mongo in chiaro in Cloud Logging |

## Controlli di sicurezza

**Pipeline / repository (DevSecOps)**
- Workload Identity Federation: nessuna chiave di service account in GitHub
- Due service account distinti per IaC e app (separation of duties)
- Checkov sul Terraform, Hadolint sul Dockerfile, Trivy sull'immagine (CVE), ClamAV sull'immagine (malware), CodeQL sul codice Go, Gitleaks e TruffleHog per i segreti (TruffleHog segnala solo quelli ancora attivi), Dependabot
- Risultati pubblicati nella tab **Security** di GitHub (SARIF)
- Environment `production` con approvazione manuale prima di apply/deploy
- Branch protection su `main` (da configurare a mano, vedi sotto)

**Cloud native (GCP)**
- *Audit logging*: Admin Activity (sempre attivi) + Data Access abilitati; copia in un log bucket dedicato con retention di 90 giorni; audit log del control plane Kubernetes inclusi
- *Preventivo*: **Binary Authorization**: GKE accetta solo immagini dal nostro Artifact Registry. Opzionali: Org Policy `iam.disableServiceAccountKeyCreation` e `gcp.resourceLocations`
- *Detective*: 6 alert Cloud Monitoring basati sugli audit log (bucket reso pubblico, firewall aperto a internet, modifiche IAM, chiavi SA, `kubectl exec`, immagine bloccata)
- *Consigliato*: attivare **Security Command Center** (Standard) dalla console: rileva da solo bucket pubblico, SSH aperto, VM con SA privilegiata

---

## Deploy passo passo

### 0. Prerequisiti (sul PC)
Installa: [Google Cloud CLI](https://cloud.google.com/sdk/docs/install), [Terraform ≥ 1.6](https://developer.hashicorp.com/terraform/install), `kubectl` (`gcloud components install kubectl gke-gcloud-auth-plugin`), [GitHub CLI](https://cli.github.com/) (facoltativo).

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project <PROJECT_ID>
```

### 1. Repository GitHub
Crea un repository (anche privato), poi dalla cartella del progetto:
```bash
git init -b main
git add .
git commit -m "Wiz technical exercise"
git remote add origin https://github.com/<utente>/<repo>.git
```
**Non fare ancora `git push`**: le pipeline partirebbero senza configurazione.

### 2. Bootstrap (una volta sola, in locale)
```bash
cd bootstrap
terraform init
terraform apply -var="project_id=<PROJECT_ID>" -var="github_repo=<utente>/<repo>"
```
Segna gli output.

### 3. Configurazione del repository GitHub
*Settings → Secrets and variables → Actions → Variables*, crea:

| Variabile | Valore |
|---|---|
| `GCP_PROJECT_ID` | output `GCP_PROJECT_ID` |
| `GCP_REGION` | `europe-west1` |
| `GCP_ZONE` | `europe-west1-b` |
| `TF_STATE_BUCKET` | output `TF_STATE_BUCKET` |
| `GCP_WIF_PROVIDER` | output `GCP_WIF_PROVIDER` |
| `GCP_IAC_SA` | output `GCP_IAC_SA` |
| `GCP_APP_SA` | output `GCP_APP_SA` |
| `ALERT_EMAIL` | (facoltativo) la tua email per gli alert |
| `TRIVY_GATE` | (facoltativo) `false` per non bloccare sulle CVE critiche |

Poi:
- *Settings → Environments* → crea `production` con te come **required reviewer**
- *Settings → Branches* → regola su `main`: PR obbligatoria, status check obbligatori
- *Settings → Code security*: abilita Dependabot alerts, secret scanning e push protection

### 4. Primo deploy
```bash
git push -u origin main
```
1. Parte **IaC - Terraform**: approva l'environment → circa 10-15 minuti (GKE è la parte lenta).
2. A infrastruttura pronta, lancia **App - Build & Deploy** da *Actions → Run workflow* (al primo push potrebbe partire prima che il cluster esista).
3. L'IP pubblico dell'app compare nel job "Verifica" (`kubectl get ingress`); il load balancer impiega 3-5 minuti a diventare attivo.

### 5. Teardown
*Actions → IaC - Terraform → Run workflow → destroy*, poi in locale `terraform destroy` in `bootstrap/`.

La pipeline cancella prima il namespace `tasky`, perché il load balancer e i NEG sono creati da Kubernetes e Terraform non li conosce. Se lanci `terraform destroy` a mano, esegui prima:
```bash
kubectl delete namespace tasky
```
Controlla infine in console che non siano rimaste risorse a pagamento.

---

## Problemi noti / da verificare alla prima esecuzione
- **Chiave GPG di MongoDB 6.0**: se `apt` rifiuta la chiave scaduta, guarda `/var/log/wiz-mongo-setup.log` sulla VM. In alternativa usa `mongo_version = "7.0"`: è comunque più vecchia di un anno rispetto all'8.x.
- **Org Policy**: lascia `ENABLE_ORG_POLICIES=false` se l'account CloudLabs non ha `orgpolicy.policyAdmin`.
- **Gate Trivy**: le dipendenze Go di Tasky sono del 2022; se il gate blocca, decidi se aggiornare `go.mod` (bonus da raccontare) o impostare `TRIVY_GATE=false`.
- **Checkov** è in `soft_fail`: segnala le debolezze volute senza bloccare. In un contesto reale andrebbe impostato `soft_fail: false`.
- **State e piani Terraform** contengono le password generate: stanno solo nel bucket privato dello state, con accesso limitato ai service account e agli owner del progetto.
