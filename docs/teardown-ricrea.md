# Distruggere e ricreare l'ambiente

Due modi: **via pipeline** (consigliato, è il flusso del progetto) o **locale**
(se ti chiedono di farlo a mano dal terminale). Ordine e spiegazione di ogni passo.

> Regola d'oro: **prima si cancella il namespace `tasky`**, poi si distrugge l'infra.
> Load Balancer e NEG li crea Kubernetes, non Terraform: se restano, la VPC risulta
> "in uso", il `destroy` fallisce e i costi continuano.

---

## A. TEARDOWN via pipeline (consigliato)

1. **GitHub → Actions → "IaC - Terraform" → Run workflow → `destroy`** → approva l'environment `production`.
   Il job `destroy` fa da solo: `kubectl delete namespace tasky`, **attende la rimozione dei NEG**, poi `terraform destroy -auto-approve`.
2. **Bootstrap** (resta fuori dalle pipeline, va a mano in locale):
```bash
cd bootstrap
terraform init
terraform destroy -var="project_id=clgcporg10-158" -var="github_repo=dicandiamirko-lang/wiz_panel"
```
3. **Cloud Armor** (creato fuori Terraform) — scollega ed elimina:
```bash
gcloud compute backend-services update <backend> --security-policy "" --global
gcloud compute security-policies delete tasky-waf-preview
```
(il nome `<backend>` da `gcloud compute backend-services list --global`)

---

## B. TEARDOWN locale (se te lo chiedono dal terminale)
```bash
# 1. rimuovi le risorse create da Kubernetes (LB + NEG)
kubectl delete namespace tasky --ignore-not-found --timeout=600s

# 2. verifica che i NEG siano spariti (ripeti finché l'elenco è vuoto)
gcloud compute network-endpoint-groups list --filter="network~wiz-vpc"

# 3. distruggi l'infrastruttura principale
cd terraform
terraform init -backend-config="bucket=clgcporg10-158-wiz-tfstate"
terraform destroy \
  -var="project_id=clgcporg10-158" \
  -var="region=europe-west1" -var="zone=europe-west1-b"

# 4. distruggi il bootstrap
cd ../bootstrap
terraform init
terraform destroy -var="project_id=clgcporg10-158" -var="github_repo=dicandiamirko-lang/wiz_panel"

# 5. controlla che non resti nulla a pagamento
gcloud compute instances list; gcloud container clusters list
```
**Spiegazione:**
- `kubectl delete namespace tasky` = elimina Deployment/Service/Ingress → GKE rimuove LB e NEG.
- `network-endpoint-groups list` = conferma che i NEG non ci sono più (altrimenti il destroy fallisce).
- `terraform init -backend-config` = ricollega lo **state remoto** (necessario per sapere cosa distruggere).
- `terraform destroy` main = rimuove rete, VM, GKE, bucket, secret, controlli.
- `terraform destroy` bootstrap = rimuove WIF, le 2 SA, il bucket di state (`force_destroy`).

---

## C. RICREARE via pipeline (consigliato)

1. **Bootstrap** (locale, una volta):
```bash
cd bootstrap
terraform init
terraform apply -var="project_id=clgcporg10-158" -var="github_repo=dicandiamirko-lang/wiz_panel"
terraform output    # copia i valori nelle Variables di GitHub se il progetto è nuovo
```
2. **IaC**: push su `main` (o Actions → "IaC - Terraform" → Run → `apply`) → **approva** → ~10-15 min (GKE è lento).
3. **App**: Actions → "App - Build & Deploy" → Run workflow → **approva** → build, push, deploy.
4. **URL dell'app**: `kubectl get ingress -n tasky` (IP statico `wiz-tasky-ip`) → `https://<IP-con-trattini>.nip.io`. Il LB impiega 3-5 min; il certificato Google-managed (`kubectl get managedcertificate -n tasky`) passa ad `Active` in ~15-60 min.
5. **Cloud Armor + DLP** (fuori Terraform): riesegui i comandi in `docs/cloud-armor-dlp.md`.

---

## D. RICREARE in locale (se te lo chiedono dal terminale)
```bash
# 1. bootstrap
cd bootstrap && terraform init
terraform apply -var="project_id=clgcporg10-158" -var="github_repo=dicandiamirko-lang/wiz_panel"

# 2. infrastruttura principale
cd ../terraform
terraform init -backend-config="bucket=clgcporg10-158-wiz-tfstate"
terraform apply \
  -var="project_id=clgcporg10-158" \
  -var="region=europe-west1" -var="zone=europe-west1-b"

# 3. credenziali del cluster
gcloud container clusters get-credentials wiz-gke --zone europe-west1-b --project clgcporg10-158

# 4. build & push dell'immagine (serve Docker)
IMG=europe-west1-docker.pkg.dev/clgcporg10-158/wiz-apps/tasky:manual
gcloud auth configure-docker europe-west1-docker.pkg.dev --quiet
docker build -t "$IMG" app && docker push "$IMG"

# 5. namespace, RBAC e Secret da Secret Manager
kubectl apply -f k8s/00-namespace.yaml -f k8s/01-rbac.yaml
MONGODB_URI=$(gcloud secrets versions access latest --secret=mongodb-uri)
SECRET_KEY=$(gcloud secrets versions access latest --secret=app-jwt-secret)
kubectl create secret generic tasky-secrets -n tasky \
  --from-literal=MONGODB_URI="$MONGODB_URI" --from-literal=SECRET_KEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# 6. deploy dei manifest (sostituisci il placeholder dell'immagine)
sed "s|IMAGE_PLACEHOLDER|$IMG|" k8s/02-deployment.yaml | kubectl apply -f -
# HTTPS: ricava l'hostname nip.io dall'IP statico e applica TLS + Ingress
LB_IP=$(gcloud compute addresses describe wiz-tasky-ip --global --format='value(address)')
sed "s|HOST_PLACEHOLDER|${LB_IP//./-}.nip.io|" k8s/04-tls.yaml | kubectl apply -f -
kubectl apply -f k8s/03-service-ingress.yaml
kubectl rollout status deployment/tasky -n tasky --timeout=300s
echo "App URL: https://${LB_IP//./-}.nip.io"
```
**Spiegazione (passi non ovvi):**
- `apply` bootstrap = ricrea API, bucket state, WIF e SA; serve **prima** di tutto il resto.
- `terraform apply` main = ricrea l'intera infra; `init -backend-config` riaggancia lo state remoto.
- `configure-docker` = autentica Docker verso Artifact Registry.
- `secrets versions access` = legge le password da Secret Manager e le inietta nel Secret K8s (replica ciò che fa la pipeline).
- `sed … IMAGE_PLACEHOLDER` = il Deployment ha un segnaposto: lo sostituisci con il tag reale prima di applicarlo.
- `rollout status` = attende che le repliche siano pronte.

> In locale servono **Docker** e **gke-gcloud-auth-plugin**. La via pipeline evita entrambi
> e applica le stesse identiche operazioni: in demo, se puoi, usa la pipeline.
