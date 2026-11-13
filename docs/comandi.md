# Comandi per la demo — spiegati

Da **PowerShell** (il tuo PC) o dalla **Cloud Shell** di GCP. Su Windows usa `curl.exe`
(non `curl`, che è un alias di PowerShell). Valori: progetto `clgcporg10-158`,
cluster `wiz-gke`, zona `europe-west1-b`.

---

## 0. Setup iniziale (una volta per sessione)
```bash
gcloud config set project clgcporg10-158                 # fissa il progetto di default
gcloud auth login                                        # login utente (apre il browser)
gcloud container clusters get-credentials wiz-gke \
  --zone europe-west1-b --project clgcporg10-158         # scrive il kubeconfig per kubectl
```
`get-credentials` = scarica l'endpoint e le credenziali del cluster in `~/.kube/config`:
è ciò che permette a `kubectl` di parlare con `wiz-gke`.

---

## 1. Mostrare che l'app gira
```bash
kubectl get nodes -o wide                 # nodi: nessun EXTERNAL-IP -> subnet privata
kubectl get pods,svc,ingress -n tasky     # stato app + IP pubblico dell'Ingress
```
- `get nodes -o wide` = elenca i nodi con IP; l'assenza di IP esterno prova che sono privati.
- `get pods,svc,ingress` = pod in `Running`, Service, e l'IP del Load Balancer nell'Ingress.

```bash
kubectl get ingress -n tasky              # IP statico del LB (wiz-tasky-ip, fisso)
kubectl get managedcertificate -n tasky   # stato TLS: Provisioning -> Active (~15-60 min)
# hostname = <IP-con-trattini>.nip.io ; es. 34.120.1.5 -> 34-120-1-5.nip.io
curl.exe -I https://<IP-con-trattini>.nip.io   # verifica HTTPS 200 dall'esterno
curl.exe -I http://<IP-con-trattini>.nip.io    # 301 -> redirect a HTTPS
```

## 2. Database e dati
```bash
gcloud compute ssh wiz-mongo-vm --zone europe-west1-b    # entra nella VM (SSH)
# dentro la VM:
ADMIN=$(gcloud secrets versions access latest --secret=mongo-admin-password)
mongosh "mongodb://admin:$ADMIN@127.0.0.1:27017/?authSource=admin" --eval '
  db = db.getSiblingDB("go-mongodb");
  printjson(db.user.find({}, {password:0}).toArray());
  printjson(db.todos.find().toArray());'
mongod --version          # mostra la versione obsoleta (6.0)
lsb_release -a            # mostra il Linux obsoleto (Ubuntu 22.04)
```
- `gcloud compute ssh` = apre SSH gestendo chiavi/IAM in automatico.
- `secrets versions access` = legge la password da Secret Manager (la VM ne ha diritto).
- `mongosh --eval` = query al DB; `{password:0}` nasconde gli hash nella proiezione.

## 3. wizexercise.txt e variabili
```bash
kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt   # il file dentro il pod
kubectl set env deployment/tasky -n tasky --list                 # variabili d'ambiente
```
- `kubectl exec … -- cat` = esegue un comando dentro il container e stampa il file richiesto.
- `set env --list` = mostra che `MONGODB_URI` arriva dal Secret (non hardcoded).

## 4. Dimostrare le debolezze
```bash
# bucket pubblico (da qualunque PC, senza login):
curl.exe https://storage.googleapis.com/clgcporg10-158-mongo-backups              # listing XML
curl.exe -O https://storage.googleapis.com/clgcporg10-158-mongo-backups/backups/<file>  # download dump

# container con cluster-admin:
kubectl auth can-i '*' '*' --as=system:serviceaccount:tasky:tasky                 # -> yes

# VM con permessi eccessivi (dentro la VM):
gcloud compute instances list                                                     # funziona
```
- `auth can-i '*' '*'` = chiede "questa identità può fare qualsiasi azione su qualsiasi risorsa?"; `--as=` impersona la SA del pod. `yes` = ha cluster-admin.

## 5. Mostrare i controlli
```bash
# Binary Authorization blocca immagini esterne:
kubectl run test --image=nginx -n tasky            # NEGATO dall'admission controller

# Cloud Armor (preview):
gcloud compute security-policies describe tasky-waf-preview \
  --format="table(rules.priority,rules.action,rules.preview)"

# Audit log di kubectl exec:
gcloud logging read \
  'protoPayload.methodName="io.k8s.core.v1.pods.exec.create"' --limit 5

# SCC findings (se hai accesso al comando):
gcloud scc findings list --source=- --filter="state=\"ACTIVE\"" 2>/dev/null
```
- `kubectl run test --image=nginx` = prova a far girare un'immagine *fuori* da `wiz-apps`: Binary Authorization la rifiuta.
- `security-policies describe` = conferma che le regole WAF sono in `preview=True`.
- `logging read` = legge gli audit log; qui filtra gli `exec` nei pod.

## 6. Verifiche GCP utili (read-only)
```bash
gcloud compute instances list                        # VM
gcloud container clusters list                       # cluster GKE
gcloud compute firewall-rules list                   # firewall (vedi SSH 0.0.0.0/0)
gcloud secrets list                                  # segreti
gcloud iam service-accounts list                     # service account
gcloud storage buckets get-iam-policy gs://clgcporg10-158-mongo-backups   # allUsers sul bucket
gcloud projects get-iam-policy clgcporg10-158 \
  --flatten="bindings[].members" --filter="wiz-mongo-vm"                  # ruoli della VM
```

---

## Deploy del container: GitHub Actions (push-based), non ArgoCD/FluxCD

**Come viene deployato:** dal job `deploy` di `.github/workflows/app.yml`, con **`kubectl apply`**
eseguito dal runner GitHub dopo la build. È un modello **push-based / imperativo**:

```
commit su main → build+scan immagine → push su Artifact Registry →
  il runner fa get-credentials → kubectl apply dei manifest k8s/ → rollout
```

**Non** c'è ArgoCD né FluxCD. Quelli sono strumenti **GitOps / pull-based**: un agente
*dentro* il cluster osserva il repo Git e **tira** (pull) lo stato desiderato
riconciliandolo di continuo. Qui invece è la pipeline esterna a **spingere** (push) le
modifiche quando parte un workflow.

**Se te lo chiedono — differenze e trade-off:**

| | Questo progetto (GitHub Actions) | ArgoCD / FluxCD (GitOps) |
|---|---|---|
| Modello | push-based, imperativo | pull-based, dichiarativo |
| Chi applica | il runner GitHub (esterno) | un controller dentro il cluster |
| Riconciliazione | solo quando parte il workflow | continua (corregge il drift da solo) |
| Credenziali cluster | servono al runner (via OIDC) | restano nel cluster, non escono |
| Rollback | rilanci la pipeline | revert del commit Git |

**Perché la scelta va bene per l'esercizio:** una sola toolchain (GitHub Actions) copre
IaC, build, scan e deploy; è semplice da mostrare end-to-end. **Evoluzione possibile da
citare:** passare a GitOps con Argo/Flux per avere riconciliazione continua, meno
credenziali verso l'esterno e rollback dichiarativo — utile man mano che crescono i
workload.
