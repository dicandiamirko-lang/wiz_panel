# Spiegazione dettagliata: pipeline e Terraform

Per rispondere a qualsiasi domanda. Ogni blocco: **cosa fa** e **perché**.

---

# PARTE A — Pipeline GitHub Actions

Principi comuni a tutti i workflow:
- `permissions: {}` in testa = **zero permessi di default**; ogni job dichiara solo i suoi (least privilege sul token).
- `persist-credentials: false` su ogni checkout = il token di GitHub non resta scritto nella cartella del repo.
- Action **fissate a SHA** (non a tag mobile) = non può cambiarti il codice sotto i piedi (supply chain).
- Autenticazione a GCP via **Workload Identity Federation (OIDC)**: `id-token: write` genera un token firmato da GitHub, scambiato con credenziali GCP temporanee → **nessuna chiave statica**.

## A1. `iac.yml` — IaC - Terraform

**Trigger** (righe 10-22): PR e push su `main` *solo se tocchi* `terraform/**` o il workflow; più `workflow_dispatch` con scelta `apply`/`destroy`.
**`concurrency: terraform`** (26-28): un solo run Terraform alla volta, non si cancellano a vicenda → niente lock corrotti sullo state.
**`env`** (30-38): passa le variabili di repo come `TF_VAR_*` (Terraform le legge in automatico) e il nome del bucket di state.

**Job `iac-scan`** (41-69): checkout → **Checkov** (`framework: terraform`, `soft_fail: true` → segnala ma non blocca, perché le misconfig sono volute) → carica il SARIF nella tab Security (`category: checkov-iac`).

**Job `plan`** (71-105): dipende da `iac-scan`. Si autentica a GCP (OIDC, SA `gh-iac-deployer`), installa gcloud e Terraform, poi:
- `terraform fmt -check` = formattazione;
- `terraform init -backend-config="bucket=..."` = collega lo state remoto su GCS;
- `terraform validate` = correttezza sintattica/riferimenti;
- `terraform plan -out=tfplan` = calcola le modifiche;
- salva `tfplan` nel **bucket privato** (non negli artifact GitHub) perché **il piano contiene le password** generate.

**Job `apply`** (107-142): solo su `main`, dietro `environment: production` → **si ferma in attesa di approvazione manuale**. Recupera *esattamente* il piano approvato dal bucket, `terraform apply tfplan`, poi cancella il piano e stampa gli output. (Applicare il piano salvato garantisce che applichi ciò che è stato rivisto, non un ricalcolo.)

**Job `destroy`** (144-192): solo da `workflow_dispatch` con `action: destroy`. Prima di `terraform destroy` fa `kubectl delete namespace tasky` e **aspetta che spariscano i NEG**: Load Balancer e NEG li crea Kubernetes, Terraform non li conosce; se restano, la VPC risulta "in uso" e il destroy fallisce (e i costi continuano).

## A2. `app.yml` — App - Build & Deploy

**Trigger** (9-15): PR/push su `main` se tocchi `app/**`, `k8s/**` o il workflow; più manuale.
**`env`** (19-25): calcola il nome immagine `…/wiz-apps/tasky` e un tag locale `tasky:ci`.

**Job `build`** (28-120):
1. `meta` (42-43): tag immagine = primi 12 char dello SHA del commit → **immagine tracciabile al commit**.
2. **Hadolint** (45-49): lint del Dockerfile, fallisce su errori.
3. `docker build` (52-53): build con tag locale (build e scan non dipendono da GCP).
4. **Verifica wizexercise.txt** (55-57): `docker run … cat /app/wizexercise.txt` → conferma che il file richiesto è *dentro* l'immagine.
5. **Trivy SARIF** (59-73): scansione CVE (CRITICAL/HIGH), caricata in Security (`exit-code 0` = non blocca qui).
6. **Gate Trivy** (78-86): seconda passata che **blocca** sui CRITICAL *con fix disponibile* (`ignore-unfixed`); disattivabile con `TRIVY_GATE=false`.
7. **ClamAV** (92-104): esporta il filesystem dell'immagine e lo scansiona per **malware** (non CVE): webshell, miner, trojan. Legge l'exit code (0 pulito, 1 trovato) e scrive un riepilogo.
8. **Auth + Push** (106-120): *solo su main, non su PR* → OIDC con SA `gh-app-deployer`, `gcloud auth configure-docker`, tag e `docker push` su Artifact Registry.

**Job `deploy`** (122-174): solo su main, `environment: production` (seconda approvazione). Si autentica (SA app), prende le credenziali del cluster, poi:
- **Namespace e RBAC** (148-149): applica `00-namespace.yaml` + `01-rbac.yaml` (crea la SA `tasky` e il binding cluster-admin).
- **Secret K8s** (151-160): legge `mongodb-uri` e `app-jwt-secret` da **Secret Manager**, li maschera nei log (`::add-mask::`) e crea il Secret `tasky-secrets` con `apply` idempotente. I segreti **non sono mai nel repo**.
- **Deploy**: `sed` sostituisce `IMAGE_PLACEHOLDER` con l'immagine buildata e applica il Deployment. Poi legge l'**hostname HTTPS** dal secret **`app-hostname`** (`gcloud secrets versions access`), che il Terraform calcola dall'**IP statico** `wiz-tasky-ip` (`<IP-con-trattini>.nip.io`); lo inietta in `04-tls.yaml` (`HOST_PLACEHOLDER`), crea il **ManagedCertificate** e applica Service/Ingress (l'Ingress aggancia l'IP statico per nome); attende il `rollout status`. L'app SA usa solo il ruolo `secretAccessor` che ha già: **nessun permesso Compute**.
  - *Perché non si legge l'IP dall'Ingress:* subito dopo l'apply lo stato dell'Ingress può mostrare ancora l'IP precedente. Il certificato verrebbe chiesto per un dominio che non punta al LB e resterebbe bloccato in `Provisioning` (`FailedNotVisible`). È successo al primo deploy HTTPS; il secret elimina la race.
- **Verifica**: mostra pod/svc/ingress, lo stato del `managedcertificate` (`Provisioning`→`Active`), stampa l'URL HTTPS e rilegge `wizexercise.txt` dal pod in esecuzione.

> **Metodo di deploy del container: push-based via GitHub Actions** (`kubectl apply`), **non** ArgoCD né FluxCD. Vedi `docs/comandi.md` §Deploy per la spiegazione completa.

## A3. `security.yml` — Repo Security

**Trigger** (8-14): PR, push su main, **ogni lunedì** (cron) e manuale.
**Job `codeql`** (19-35): SAST sul codice **Go** (init → autobuild → analyze), risultati in Security.
**Job `trufflehog`** (41-54): cerca **segreti committati** e con `--results=verified` fallisce *solo se la credenziale è ancora attiva* → pochi falsi positivi. Su push scansiona i commit nuovi, su schedule/manuale tutta la storia (`fetch-depth: 0`).

## A4. `pipeline-security.yml` — Pipeline Security (sicurezza *dei workflow*)

**Trigger** (12-20): modifiche a `.github/**`, push su main, ogni lunedì, manuale.
**Job `actionlint`** (25-36): sintassi dei workflow + **shellcheck** sugli script `run`.
**Job `zizmor`** (38-62): misconfig dei workflow (injection, permessi eccessivi, token esposti, action non fissate a SHA o vulnerabili). Due passate: report SARIF (non blocca) + **gate** sui finding di gravità alta (blocca).
**Job `workflow-secrets`** (64-79): TruffleHog su `.github/` con `--fail` → qui **più severo**: in un workflow non deve esserci *nessuna* credenziale, attiva o no.

---

# PARTE B — Terraform

## B0. `bootstrap/` — eseguito UNA volta in locale (state locale)
Serve a creare ciò che le pipeline useranno. `main.tf`:
- **`apis`** (28-45 → risorsa 66-70): abilita tutte le API GCP necessarie (compute, container, artifactregistry, secretmanager, iam, sts, logging, monitoring, binauthz, securitycenter…).
- **Bucket state** (73-83): `…-wiz-tfstate`, `public_access_prevention=enforced`, **versioning on** → lo state remoto è privato e versionato.
- **Workload Identity Pool + Provider** (86-110): federazione OIDC con GitHub. `attribute_mapping` mappa i claim del token; **`attribute_condition` limita l'accesso al solo repo** `dicandiamirko-lang/wiz_panel`; issuer = `token.actions.githubusercontent.com`.
- **SA `gh-iac-deployer`** (113-129): ruoli ampi per gestire l'infra (`editor`, `container.admin`, `secretmanager.admin`, ecc.) + `workloadIdentityUser` legato al repo.
- **SA `gh-app-deployer`** (132-148): ruoli minimi per l'app (`artifactregistry.writer`, `container.admin` *necessario per creare il binding cluster-admin richiesto*, `secretmanager.secretAccessor`) + WIF.
- **Separation of duties**: due SA distinte, chi builda l'app non può riscrivere l'infrastruttura.

## B1. `versions.tf`
Provider `google ~> 6.0` e `random ~> 3.6`; **backend GCS** per lo state (il bucket arriva a runtime da `-backend-config`), prefix `wiz-exercise`.

## B2. `variables.tf`
Parametri con default: progetto/regione/zona, `name_prefix=wiz`; immagine VM Ubuntu 22.04 e Mongo 6.0 (**obsoleti per scelta**); tipi macchina; `gke_master_authorized_cidr=0.0.0.0/0` (i runner GitHub hanno IP dinamici); flag `enable_org_policies` (default off, serve `orgpolicy.policyAdmin`) e `enable_binary_authorization` (default on).

## B3. `network.tf`
- **VPC** custom (`auto_create_subnetworks=false`) → rete pulita: nessuna subnet automatica, creo solo quelle che servono (segmentazione).
- **Router + Cloud NAT** → uscita internet **solo in uscita** per i nodi privati.
- **Firewall `ssh_from_internet`**: 22 da `0.0.0.0/0` sui tag `mongo` → **debolezza voluta**, con log.
- **Firewall `mongo_from_gke`**: 27017 **solo** dai range della subnet GKE → il DB non è esposto a internet.

### Le subnet: perché nella console ne vedo 3

Nel Terraform ne definisco **due**; la terza la crea **GKE** da solo.

| Subnet | Range | Chi la crea | A cosa serve |
|---|---|---|---|
| `wiz-public` | `10.10.1.0/24` | **io** (TF) | VM MongoDB — zona "esposta" (IP pubblico, SSH aperto) |
| `wiz-gke-private` | `10.10.16.0/20` | **io** (TF) | nodi GKE — zona "protetta" (nessun IP pubblico, uscita via NAT) |
| `gke-wiz-gke-…-pe-subnet` | `172.16.0.0/28` | **GKE** (auto) | *Private Service Connect*: collega i nodi al **control plane** del cluster privato senza esporlo su internet |

Il suffisso `pe-subnet` = *private endpoint*; nome con hash e range fuori dal mio schema `10.x` → risorsa di sistema, non è nell'IaC. La sua presenza **conferma** che il cluster è privato (control plane non pubblico).

**Separazione:** DB nella subnet esposta, app nella subnet protetta; tra le due passa solo ciò che apre il firewall (Mongo 27017 raggiungibile **solo** dalla subnet GKE).

### Le regole firewall: quali creo io e quali crea GKE

Nella console ne vedi **5**: **2 le definisco io** nel Terraform, **3 le crea GKE/Load Balancer** in automatico. Si distinguono dal nome: `wiz-allow-*` = mie e nell'IaC; nome con **hash** (`gke-…`, `k8s-fw-…`) = auto-create e gestite dal servizio.

**Le 2 mie (`network.tf`):**

| Regola | Apre | A chi | Perché |
|---|---|---|---|
| `wiz-allow-ssh-from-internet` | **22 (SSH)** | da `0.0.0.0/0` (tutto internet) → tag `mongo` | **Debolezza voluta**: la VM MongoDB è raggiungibile in SSH da chiunque (con log) |
| `wiz-allow-mongo-from-gke` | **27017 (MongoDB)** | **solo** dai range della subnet GKE → tag `mongo` | Il DB è raggiungibile **solo** dall'app nel cluster, **non** da internet |

> Contrasto da raccontare: la 22 aperta a tutti è il rischio **intenzionale**; la 27017 invece è configurata **bene** (ristretta alla sola rete GKE).

**Le 3 di GKE (automatiche):**

| Regola | A cosa serve |
|---|---|
| `gke-…-all` | Traffico **interno** tra nodi, pod e service del cluster (la rete Kubernetes deve comunicare al suo interno) |
| `gke-…-vms` | Regole per i **nodi** (VM del cluster): health check e comunicazione di sistema tra i componenti GKE |
| `k8s-fw-l7-…` | Regola del **Load Balancer L7** (Ingress): lascia entrare i **Google health check** e il traffico del bilanciatore verso i pod → è ciò che fa funzionare l'IP pubblico dell'app (descr. *"GCE L7 firewall rule"*) |

### I range secondari (solo sulla subnet privata)

La subnet `wiz-gke-private` ha, oltre al range primario (i **nodi**), due **range secondari**:

| Range secondario | CIDR | A cosa serve |
|---|---|---|
| `pods` | `10.20.0.0/16` | un IP per ogni **pod** |
| `services` | `10.30.0.0/20` | un IP per ogni **Service** Kubernetes |

Servono perché il cluster è **VPC-native**: i pod hanno IP **reali della VPC** (via *alias IP*), non IP "finti" nascosti nei nodi. Vantaggi: firewall e **VPC Flow Logs** applicabili direttamente sui pod, scalabilità, e **load balancing nativo** (il LB parla ai pod). GCP **non** crea i range secondari di default: li dichiaro io e il cluster li aggancia per nome (`ip_allocation_policy` in `gke.tf`). I **VPC Flow Logs** sono attivi (campionamento 0.5).

### Cosa scarica il Cloud NAT (quali immagini)

Il NAT dà ai nodi privati una via **in uscita**; nessuno da internet può aprire connessioni verso di loro. Ma **non** tutte le immagini passano di lì:

| Immagine da… | Come arriva | Usa il NAT? |
|---|---|---|
| **Artifact Registry/GCR di Google** (la tua `tasky`) | *Private Google Access* (`private_ip_google_access=true`) | **No** — corsia privata verso le API Google |
| **Docker Hub, quay.io, ghcr.io, registry.k8s.io** (terze parti/community) | **Cloud NAT** → internet | **Sì** |

Quindi l'immagine dell'app Tasky **non** usa il NAT; il NAT serve per immagini di terze parti (es. `nginx` da Docker Hub del test di Binary Authorization), add-on da `registry.k8s.io` e in generale l'outbound dei pod (update OS, chiamate ad API esterne).

## B4. `mongo_vm.tf`
- **SA `wiz-mongo-vm`** + binding **`compute.admin` e `serviceAccountUser`** (18-26) → **privilege escalation voluta**: chi entra nella VM crea VM con altre SA.
- Binding log/metriche + accesso ai 2 secret delle password.
- **IP pubblico** (`google_compute_address.mongo`) e **IP interno statico** `10.10.1.10` (così la connection string nel secret non dipende dalla VM).
- **Istanza** (59-104): Ubuntu obsoleto, tag `mongo`, scope `cloud-platform`, `startup-script` renderizzato da `templatefile`; `depends_on` su secret e IAM così lo startup li trova pronti.

## B5. `scripts/mongo-startup.sh.tpl`
All'avvio: installa Mongo nella versione obsoleta e **blocca gli update** (`apt-mark hold`); `bindIp 0.0.0.0` (filtrato comunque dal firewall); crea utente `admin` (root) e `tasky` (readWrite su `go-mongodb`) leggendo le password da Secret Manager; **abilita l'autenticazione**. Installa `/usr/local/bin/mongo-backup.sh` (mongodump `--gzip` → `gcloud storage cp` sul bucket pubblico), schedula un **cron giornaliero alle 02:00 UTC** e fa un primo backup subito (così il bucket non è vuoto in demo).

## B6. `backup_bucket.tf`
- **Bucket `…-mongo-backups`**: `public_access_prevention="inherited"` (non enforced → **si può rendere pubblico**), lifecycle 30 giorni, `force_destroy`.
- **`backups_public`**: `allUsers` = `storage.objectViewer` → **lettura + listing pubblici** (objectViewer include get *e* list).
- **`backups_writer`**: la SA della VM può solo scrivere (`objectCreator`).

### Quali bucket sono miei (org GCP condivisa)

Nella console compaiono vari bucket: sono in un'**org condivisa** (CloudLabs), quindi vedo anche quelli di altri. **Solo due sono miei.**

| Bucket | Di chi | Cosa contiene |
|---|---|---|
| `clgcporg10-158-mongo-backups` | **mio** (IaC) | backup di MongoDB; è il bucket **pubblico** → **debolezza voluta** |
| `clgcporg10-158-wiz-tfstate` | **mio** (bootstrap) | **stato Terraform**; privato (configurato bene) |
| `clgcporg10-158-tfstate` | **non mio** (pre-esistente) | state di altro/vecchio uso → **non toccare** |
| `wiz-terraform-state-clgcporg10-158` | **non mio** | state di terzi → **non toccare** |
| `todo-wayne-tfstate`, `wiz-preprod-mongodb-backups-…`, `wiz-prod-mongodb-backups-…` | **non miei** (altre persone) | esercizi altrui → **non toccare** |

**Come riconoscere i miei:** prefisso `clgcporg10-158-`, region `europe-west1`, creati durante il mio deploy. Il `terraform destroy` tocca **solo** i miei; gli altri appartengono ad altri tenant della stessa org e non vanno mai cancellati.

## B7. `secrets.tf`
- Tre `random_password` (admin, app, jwt).
- `locals.secrets`: le 3 password + la **connection string** `mongodb-uri` costruita con l'IP interno statico + **`app-hostname`** (`<IP-statico-LB-con-trattini>.nip.io`, non è un segreto: sta qui perché la pipeline app lo legge con il ruolo che ha già).
- **Secret Manager**: `user_managed` replication fissata su `europe-west1` (l'org policy del lab **vieta `global`**); una secret-version per valore. *I valori finiscono nello state → per questo lo state è in un bucket privato.*

## B8. `gke.tf`
- **SA `wiz-gke-nodes`** con ruoli **minimi** (log, metriche, `artifactregistry.reader`) → **least privilege**, contiene il movimento laterale cloud.
- **Cluster `wiz-gke`** zonale: nodi privati (`enable_private_nodes`), **endpoint pubblico** ma limitato da `master_authorized_networks` (per kubectl da pipeline/demo); `ip_allocation_policy` usa i range secondari; **Workload Identity** (`workload_pool`); release channel REGULAR; addon **HTTP(S) Load Balancing** on (serve all'Ingress, anche per l'HTTPS); **Binary Authorization** `PROJECT_SINGLETON_POLICY_ENFORCE`; logging SYSTEM+WORKLOADS+**APISERVER** (audit control plane).
- **Node pool** `default-pool`: tipo macchina, **Shielded VM** (secure boot + integrity), **`GKE_METADATA`** (Workload Identity attivo, blocca l'abuso del metadata server), auto-repair/upgrade.
- **Artifact Registry `wiz-apps`** (Docker, regionale).

### Le StorageClass che vedo nel cluster (non le ho create io)

In *Kubernetes Engine → Storage → Storage Classes* compaiono ~10 voci (`standard`, `standard-rwo`, `premium-rwo`, `dynamic`, vari `*-rwx`…). **Le crea GKE di serie su ogni cluster**, non sono nell'IaC e **nel mio progetto non vengono usate**.

- **Cosa sono:** un "listino" dei **tipi di disco** che un pod può chiedere con una *PersistentVolumeClaim* per avere storage **persistente** (provisionato dinamicamente da GKE).
- **Due famiglie:** provisioner `pd.csi…` = **Persistent Disk** a blocchi, accesso `rwo` (*ReadWriteOnce*, un nodo alla volta, tipico dei DB); provisioner `filestore.csi…` = **Filestore/NFS** condiviso, accesso `rwx` (*ReadWriteMany*, più pod insieme). Le `premium/pd-ssd` sono più veloci, `standard` più economiche.
- **Perché non le uso:** i dati dell'app stanno su **MongoDB in una VM dedicata** (col suo disco), non su volumi persistenti nel cluster → nessun pod richiede una PVC. Le vedo solo perché sono preset di default.
- **Evoluzione da citare:** in un'architettura cloud-native "pura" si potrebbe spostare MongoDB nel cluster come StatefulSet con volumi (es. StorageClass `premium-rwo`).

## B9. `security.tf`
- **Audit logging** (15-38): abilita `ADMIN_READ`+`DATA_WRITE` su tutti i servizi e `DATA_READ` su storage e secret.
- **Log bucket `audit-logs`** + **sink** (41-54): copia tutti i `cloudaudit` log, retention 90gg, `location=europe-west1` (no `global` per l'org policy).
- **Binary Authorization policy** (61-75): default `ALWAYS_DENY` + whitelist solo `wiz-apps` → immagini esterne negate.

> **Perché ho aggiunto Binary Authorization (scelta mia, non un requisito esplicito).**
> È un controllo **preventivo** che **blocca il deploy di qualsiasi container la cui immagine non provenga da una whitelist** — nel mio caso **solo** il mio Artifact Registry `wiz-apps`. Ogni altra immagine (presa da internet, Docker Hub, ecc.) viene **negata all'ammissione, prima di partire**.
> L'ho messo perché ho testato tutto sul **mio tenant GCP** e, essendoci nell'ambiente una **vulnerabilità grave voluta** dall'esercizio, volevo essere certo che ci fosse una **mitigazione** capace di impedire il deploy di **container non autorizzati** (ad es. un **cryptominer** avviato sfruttando quella vulnerabilità). Così, anche se qualcuno riuscisse a ottenere accesso al cluster, **non potrebbe far girare immagini arbitrarie**: solo quelle costruite e pubblicate dalla mia pipeline.
> **Dove vederlo:** Console → *Security → Binary Authorization* (scheda Policy); da terminale `gcloud container binauthz policy export`; conferma sul cluster con `gcloud container clusters describe wiz-gke --zone europe-west1-b --format="value(binaryAuthorization.evaluationMode)"` (→ `PROJECT_SINGLETON_POLICY_ENFORCE`). Fonte di verità: `security.tf` (policy) e `gke.tf` (abilitazione).

- **Org Policy opzionali** (81-105, dietro flag): disabilita chiavi SA; limita le location a `eu`.
- **Detective** (110-179): un notification channel email (se `alert_email` valorizzata) e **6 alert policy** basate su filtri di log (bucket pubblico, firewall aperto, modifica IAM, chiave SA, `kubectl exec`, immagine bloccata da BinAuthz).

## B10. `outputs.tf`
Comodità per la demo: IP pubblico/interno della VM, **comando SSH pronto**, URL del listing pubblico del bucket, nome cluster, **comando get-credentials**, path dell'Artifact Registry.

---

# PARTE C — Kubernetes e immagine

- **`00-namespace.yaml`**: namespace `tasky`.
- **`01-rbac.yaml`**: SA `tasky` + **ClusterRoleBinding a `cluster-admin`** → **debolezza voluta**: una RCE nell'app = controllo totale del cluster.
- **`02-deployment.yaml`**: 2 repliche, `serviceAccountName: tasky`, immagine da placeholder, `MONGODB_URI`/`SECRET_KEY` dal Secret `tasky-secrets`, readiness/liveness su `:8080/`, resource limits.
- **`03-service-ingress.yaml`**: Service ClusterIP 80→8080 con annotazione **NEG** (container-native LB); Ingress `gce` → crea l'HTTP(S) Load Balancer esterno. Annotazioni HTTPS: `global-static-ip-name` (IP statico del Terraform), `managed-certificates` (certificato Google-managed) e `FrontendConfig` (redirect 80→443).
- **`04-tls.yaml`**: **HTTPS**. `ManagedCertificate` → Google emette e rinnova da solo un certificato valido per l'hostname `nip.io` (`HOST_PLACEHOLDER` sostituito dalla pipeline con `<IP-LB-con-trattini>.nip.io`). `FrontendConfig` → forza il **redirect 80→443**. La terminazione TLS è sul Load Balancer: l'app non va modificata. Le debolezze intenzionali restano invariate (l'HTTPS cifra solo il trasporto).
  - *Attenzione:* **non cambiare il dominio di un `ManagedCertificate` esistente.** GKE stacca il certificato dal Load Balancer per ricrearlo e può non riagganciarlo più. Il certificato resta in `Provisioning`, l'Ingress perde proxy HTTPS e forwarding rule 443, e `pre-shared-cert` resta vuoto. Va invece **cancellato e ricreato**: `kubectl delete managedcertificate tasky-cert -n tasky`, poi di nuovo l'apply di `04-tls.yaml`. Il certificato si valida solo quando è collegato a un Load Balancer. Validazione tipica: 15-60 minuti.
- **`Dockerfile`**: build multi-stage (Go 1.25 → Alpine 3.24), copia `wizexercise.txt`, **`USER 65532`** (non-root), espone 8080.
