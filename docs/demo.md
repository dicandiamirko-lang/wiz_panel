# Script demo live (~25 min)

Prepara prima: `gcloud container clusters get-credentials wiz-gke --zone europe-west1-b --project clgcporg10-158`
e tieni aperte le tab console GCP: GKE, Compute, Storage, Logging, Monitoring > Alerting, GitHub Actions/Security.

> Progetto lab: `clgcporg10-158` · IP pubblico attuale dell'app: `34.117.223.228`.
> L'IP cambia a ogni redeploy: verificalo con `kubectl get ingress -n tasky`.

## 1. L'applicazione funziona (3 min)
```bash
kubectl get nodes -o wide               # nodi senza EXTERNAL-IP -> subnet privata
kubectl get pods,svc,ingress -n tasky   # IP pubblico dell'Ingress
```
Apri `http://34.117.223.228`, registra un utente, crea 2-3 todo.

## 2. I dati sono nel database (3 min)
```bash
gcloud compute ssh wiz-mongo-vm --zone europe-west1-b
ADMIN=$(gcloud secrets versions access latest --secret=mongo-admin-password)
mongosh "mongodb://admin:$ADMIN@127.0.0.1:27017/?authSource=admin" --eval '
  db = db.getSiblingDB("go-mongodb");
  printjson(db.user.find({}, {password:0}).toArray());
  printjson(db.todos.find().toArray());'
mongod --version            # versione obsoleta
lsb_release -a              # Linux obsoleto
```

## 3. Variabile d'ambiente e wizexercise.txt (2 min)
```bash
kubectl set env deployment/tasky -n tasky --list   # MONGODB_URI arriva dal Secret tasky-secrets
kubectl exec -n tasky deploy/tasky -- cat /app/wizexercise.txt
```
Mostra la riga `COPY wizexercise.txt` nel `Dockerfile` e lo step "Verifica wizexercise.txt" nella pipeline.

## 4. Debolezze e impatto (8 min)
**Bucket pubblico**: da una finestra in incognito, senza login (su Windows PowerShell usa `curl.exe`):
```bash
curl https://storage.googleapis.com/clgcporg10-158-mongo-backups          # listing XML
curl -O https://storage.googleapis.com/clgcporg10-158-mongo-backups/backups/<file>
```
**cluster-admin dal container**: un attaccante con RCE nell'app:
```bash
kubectl auth can-i '*' '*' --as=system:serviceaccount:tasky:tasky       # yes
kubectl exec -n tasky deploy/tasky -- sh -c 'wget -qO- --header "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" --no-check-certificate https://kubernetes.default.svc/api/v1/secrets | head -c 400'
```
**VM con permessi eccessivi**: dalla VM:
```bash
gcloud compute instances list          # funziona: la VM puo' gestire Compute
# potrebbe creare una VM con la SA di un altro servizio -> escalation
```
**SSH esposto**: Logging, query sui firewall log della regola `wiz-allow-ssh-from-internet` (tentativi da IP sconosciuti).

**Kill chain**: SSH esposto → VM compromessa → SA compute.admin → nuove VM / movimento laterale; parallelamente il bucket pubblico espone i dati senza alcun exploit.

## 5. Controlli di sicurezza (7 min)
**Preventivo: Binary Authorization**
```bash
kubectl run test --image=nginx -n tasky      # NEGATO
```
**Detective**: Monitoring > Alerting: incident "[SEC] kubectl exec in un pod" e "[SEC] Immagine bloccata" generati dai comandi appena eseguiti.

**Edge WAF (Cloud Armor, preview)**: Network Security > Cloud Armor > `tasky-waf-preview`: regole OWASP (SQLi, XSS, LFI, RCE, scanner) in preview sul LB. Mostra i log di cosa *avrebbe* bloccato senza interrompere l'app. Punto chiave: i vettori reali dell'esercizio (SSH, bucket, cluster-admin) non passano dal LB → Cloud Armor non li tocca; è messo in preview di proposito.

**Dato sensibile (DLP)**: Security > Sensitive Data Protection: inspection sul bucket `clgcporg10-158-mongo-backups`. Punto onesto: i backup sono archivi `mongodump --gzip` (binari), che il DLP non parsa → 0 finding sul formato attuale. Per far emergere i dati servirebbe un export in JSON/CSV. Dimostra quando un controllo *non* basta da solo.

**Audit log**: Logs Explorer, query:
```
logName:"cloudaudit.googleapis.com" AND protoPayload.methodName="io.k8s.core.v1.pods.exec.create"
```
**Pipeline**: GitHub > Security > Code scanning: finding di Checkov (bucket pubblico, SSH 0.0.0.0/0…) e Trivy (CVE immagine). Environment `production` con approvazione.

**Valore di Wiz**: i singoli tool vedono pezzi separati; Wiz collega SSH esposto + VM vulnerabile + SA privilegiata + bucket pubblico in un unico *toxic combination / attack path*.
