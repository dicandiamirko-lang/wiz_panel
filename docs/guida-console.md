# Manuale demo: trovare · mostrare · spiegare

Mappa rapida di **tutto** ciò che è configurato, con *dove* si trova (console + comando)
e *cosa dire* in una frase. Progetto `clgcporg10-158` · regione `europe-west1` · zona `europe-west1-b`.

**Diagrammi di supporto** (aprili su schermo): `docs/architettura.svg` (architettura),
`docs/attacco.svg` (attack path + mitigazioni), `docs/pipeline.svg` (CI/CD),
`docs/confronto-tool.svg` (Checkov vs SCC).

---

## 1. GCP — infrastruttura

| Cosa | Console (menu ☰) | Comando | Cosa dire |
|---|---|---|---|
| **Rete VPC** | VPC network > VPC networks → `wiz-vpc` | `gcloud compute networks subnets list` | VPC custom, 2 subnet: `wiz-public` (VM) e `wiz-gke-private` (nodi GKE) |
| **Firewall** | VPC network > Firewall | `gcloud compute firewall-rules list` | `allow-ssh-from-internet` (22 da 0.0.0.0/0, debolezza voluta) e `allow-mongo-from-gke` (27017 solo da subnet GKE) |
| **Cloud NAT** | Network services > Cloud NAT | `gcloud compute routers nats list --router wiz-router --region europe-west1` | dà uscita internet ai nodi privati senza esporli |
| **VM MongoDB** | Compute Engine > VM instances → `wiz-mongo-vm` | `gcloud compute instances describe wiz-mongo-vm --zone europe-west1-b` | Ubuntu 22.04 (obsoleto), Mongo 6.0 (EOL), IP pubblico + SSH aperto |
| **GKE cluster** | Kubernetes Engine > Clusters → `wiz-gke` | `gcloud container clusters describe wiz-gke --zone europe-west1-b` | zonale, nodi privati, Workload Identity, Binary Authorization |
| **Nodi GKE** | Kubernetes Engine > Clusters > Nodes | `kubectl get nodes -o wide` | nessun EXTERNAL-IP → confermano che sono in subnet privata |
| **Artifact Registry** | Artifact Registry > Repositories → `wiz-apps` | `gcloud artifacts docker images list europe-west1-docker.pkg.dev/clgcporg10-158/wiz-apps` | registro Docker privato; Binary Authorization accetta solo immagini da qui |
| **Load Balancer** | Network services > Load balancing | `gcloud compute forwarding-rules list --global` | HTTP LB creato dall'Ingress GKE; IP pubblico dell'app |

## 2. GCP — dati e segreti

| Cosa | Console | Comando | Cosa dire |
|---|---|---|---|
| **Bucket backup (pubblico)** | Cloud Storage > Buckets → `clgcporg10-158-mongo-backups` → Permissions | `gcloud storage buckets get-iam-policy gs://clgcporg10-158-mongo-backups` | `allUsers` = `storage.objectViewer` → lettura e listing pubblici (debolezza voluta) |
| **Prova esposizione** | — | `curl.exe https://storage.googleapis.com/clgcporg10-158-mongo-backups` | listing XML senza login: chiunque scarica i dump |
| **Bucket state (privato)** | Cloud Storage > `clgcporg10-158-wiz-tfstate` | `gcloud storage buckets describe gs://clgcporg10-158-wiz-tfstate` | `public_access_prevention=enforced` + versioning: lo state (con le password) è protetto |
| **Secret Manager** | Security > Secret Manager | `gcloud secrets list` | 4 segreti: `mongo-admin-password`, `mongo-app-password`, `app-jwt-secret`, `mongodb-uri`; generati da Terraform, mai nel repo |

## 3. GCP — identità e accessi

| Cosa | Console | Comando | Cosa dire |
|---|---|---|---|
| **Service Account** | IAM & Admin > Service Accounts | `gcloud iam service-accounts list` | 4 SA: 2 pipeline (`gh-iac-deployer`, `gh-app-deployer`), VM (`wiz-mongo-vm`), nodi (`wiz-gke-nodes`) |
| **VM over-permissive** | IAM & Admin > IAM → filtra `wiz-mongo-vm` | `gcloud projects get-iam-policy clgcporg10-158 --flatten="bindings[].members" --filter="wiz-mongo-vm"` | ha `compute.admin` + `serviceAccountUser` → escalation (debolezza voluta) |
| **Nodi least-privilege** | IAM → filtra `wiz-gke-nodes` | stesso comando con `wiz-gke-nodes` | solo log/metriche + `artifactregistry.reader`: contiene il movimento laterale |
| **Workload Identity Federation** | IAM & Admin > Workload Identity Federation → `github-pool` | `gcloud iam workload-identity-pools providers describe github-provider --location global --workload-identity-pool github-pool` | GitHub si autentica via OIDC, `attribute_condition` limita al repo; **nessuna chiave JSON** |

## 4. GCP — controlli di sicurezza (cloud native)

| Cosa | Console | Comando | Cosa dire |
|---|---|---|---|
| **Binary Authorization** | Security > Binary Authorization | `gcloud container binauthz policy export` | default `ALWAYS_DENY`, whitelist solo `wiz-apps` → immagini esterne bloccate |
| **Audit logging** | IAM & Admin > Audit Logs | — | Admin Activity (sempre) + Data Access (storage, secret) abilitati |
| **Log bucket + sink** | Logging > Logs Storage → `audit-logs` | `gcloud logging buckets list --location europe-west1` | copia di tutti gli audit log, retention 90 giorni |
| **Alert detective** | Monitoring > Alerting | `gcloud alpha monitoring policies list` | 6 alert su audit log: bucket pubblico, firewall aperto, modifica IAM, chiave SA, `kubectl exec`, immagine bloccata |
| **Security Command Center** | Security > Security Command Center > Findings | — | Standard attivo: rileva bucket pubblico, SSH, SA privilegiata, privilege escalation GKE, CVE immagini |
| **Cloud Armor** | Network Security > Cloud Armor → `tasky-waf-preview` | `gcloud compute security-policies describe tasky-waf-preview` | WAF OWASP in **preview** (logga, non blocca) sul LB dell'app |
| **DLP** | Security > Sensitive Data Protection > Inspection | — | inspection sul bucket backup; nota onesta: i dump `--gzip` sono binari → 0 finding |

## 5. Dimostrare le debolezze (a voce + comando)

| Debolezza | Comando | Cosa succede |
|---|---|---|
| **Bucket pubblico** | `curl.exe https://storage.googleapis.com/clgcporg10-158-mongo-backups` | listing senza auth |
| **cluster-admin dal pod** | `kubectl auth can-i '*' '*' --as=system:serviceaccount:tasky:tasky` | risponde `yes` |
| **wizexercise.txt** | `kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt` | il tuo nome dentro l'immagine |
| **VM permessi eccessivi** | da SSH sulla VM: `gcloud compute instances list` | funziona → la VM gestisce Compute |

---

## 6. GitHub

| Cosa | Dove | Cosa dire |
|---|---|---|
| **Struttura repo** | tab Code | `bootstrap/`, `terraform/`, `app/`, `k8s/`, `.github/workflows/`, `docs/` |
| **Pipeline** | tab Actions | 4 workflow: *IaC - Terraform*, *App - Build & Deploy*, *Repo Security*, *Pipeline Security* |
| **Approvazione manuale** | Settings > Environments > `production` | required reviewer: apply/deploy si fermano in attesa |
| **Variabili** | Settings > Secrets and variables > Actions > Variables | 7 variabili (progetto, regione, bucket state, provider WIF, i 2 SA…); **nessun secret/chiave** |
| **Risultati sicurezza** | tab Security > Code scanning | SARIF di Checkov, Trivy, CodeQL, zizmor in un unico posto |
| **Dependabot** | tab Security > Dependabot | alert sulle dipendenze (Go datato = debolezza voluta) |
| **Secret scanning** | Settings > Code security | push protection: blocca commit con credenziali |
| **OIDC in azione** | Actions > un run > job *auth* | log: scambia il token OIDC con le credenziali GCP, nessuna chiave |

### Frase di chiusura (il valore di Wiz)
> "Ogni tool vede un pezzo: Checkov l'IaC, Trivy l'immagine, SCC il runtime. Nessuno
> correla *bucket pubblico + dati sensibili + SA privilegiata* in un unico attack path.
> È esattamente ciò che fa una piattaforma CNAPP come Wiz: normalizza, deduplica e
> prioritizza per toxic combination."
