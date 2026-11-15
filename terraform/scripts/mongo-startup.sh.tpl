#!/bin/bash
# =============================================================================
# Startup script della VM MongoDB. Viene eseguito UNA VOLTA al primo avvio
# (metadata startup-script) e si occupa di: installare MongoDB alla versione
# obsoleta richiesta, creare gli utenti, abilitare l'autenticazione e impostare
# il backup giornaliero verso il bucket pubblico.
#
# E' renderizzato da Terraform con templatefile(): i segnaposto con graffe
# (mongo_version, backup_bucket, project_id, admin_secret, app_secret) sono
# sostituiti da Terraform PRIMA di arrivare sulla VM. Le variabili bash normali
# usano il dollaro semplice; nell'heredoc del backup sono protette con backslash
# per non farle valutare al momento della scrittura del file.
# =============================================================================
set -euo pipefail                                        # esci al primo errore / variabile non definita
exec > >(tee -a /var/log/wiz-mongo-setup.log) 2>&1       # salva tutto l'output del setup in un log

export PATH=$PATH:/snap/bin:/usr/bin
MARKER=/var/lib/wiz-mongo-installed                      # file "sentinella": se c'e', l'installazione e' gia' avvenuta
MONGO_VERSION="${mongo_version}"                         # valori iniettati da Terraform
BACKUP_BUCKET="${backup_bucket}"
PROJECT_ID="${project_id}"

# Legge una password da Secret Manager (usando la SA della VM). Con retry perche'
# al primissimo boot il permesso IAM puo' metterci qualche secondo a propagarsi.
get_secret() {
  for i in $(seq 1 30); do
    if gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID" 2>/dev/null; then
      return 0
    fi
    sleep 10
  done
  echo "Impossibile leggere il secret $1" >&2
  return 1
}

# Blocco di installazione: eseguito solo se il MARKER non esiste (idempotenza:
# se la VM si riavvia, non reinstalla tutto).
if [ ! -f "$MARKER" ]; then
  echo "== Installazione MongoDB $MONGO_VERSION =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y gnupg curl

  # Aggiunge la chiave GPG e il repository apt ufficiale di MongoDB per la versione scelta.
  curl -fsSL "https://www.mongodb.org/static/pgp/server-$MONGO_VERSION.asc" \
    | gpg --dearmor --yes -o "/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg"
  CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-$MONGO_VERSION.gpg ] https://repo.mongodb.org/apt/ubuntu $CODENAME/mongodb-org/$MONGO_VERSION multiverse" \
    > "/etc/apt/sources.list.d/mongodb-org-$MONGO_VERSION.list"

  apt-get update -y
  apt-get install -y mongodb-org
  # Blocca gli aggiornamenti: la versione obsoleta e' voluta
  apt-mark hold mongodb-org mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools || true

  # Ascolta su tutte le interfacce: l'accesso e' filtrato dal firewall VPC (solo GKE)
  sed -i 's/^  bindIp: .*/  bindIp: 0.0.0.0/' /etc/mongod.conf

  systemctl enable mongod
  systemctl start mongod

  # Attende che MongoDB risponda prima di creare gli utenti.
  for i in $(seq 1 30); do
    mongosh --quiet --eval "db.adminCommand('ping').ok" && break
    sleep 2
  done

  # Legge le due password generate da Terraform e salvate in Secret Manager.
  ADMIN_PWD=$(get_secret "${admin_secret}")
  APP_PWD=$(get_secret "${app_secret}")

  echo "== Creazione utenti =="
  # Utente amministratore (root) e utente applicativo con permessi SOLO sul suo DB.
  mongosh --quiet admin --eval "
    db.createUser({user: 'admin', pwd: '$ADMIN_PWD', roles: [{role: 'root', db: 'admin'}]});
  "
  mongosh --quiet go-mongodb --eval "
    db.createUser({user: 'tasky', pwd: '$APP_PWD', roles: [{role: 'readWrite', db: 'go-mongodb'}]});
  "

  echo "== Abilitazione autenticazione =="
  # Attiva l'autenticazione: da qui serve user+password per connettersi (non e'
  # un DB "aperto"). L'esposizione resta limitata dal firewall, non e' anonima.
  if ! grep -q '^security:' /etc/mongod.conf; then
    printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
  fi
  systemctl restart mongod

  touch "$MARKER" # segna l'installazione come completata (idempotenza)
fi

# --- Script di backup ----------------------------------------------------------
# Scrive su disco lo script che fa il dump e lo carica sul bucket. Nell'heredoc i
# "\$" proteggono le variabili perche' siano valutate quando lo script GIRA, non
# ora che viene scritto; "admin_secret", "project_id" e "backup_bucket" sono invece
# risolti subito da Terraform.
cat > /usr/local/bin/mongo-backup.sh <<EOF
#!/bin/bash
set -euo pipefail
export PATH=\$PATH:/snap/bin:/usr/bin
TS=\$(date -u +%Y%m%d-%H%M%S)
FILE=/tmp/mongo-backup-\$TS.archive.gz
ADMIN_PWD=\$(gcloud secrets versions access latest --secret="${admin_secret}" --project="$PROJECT_ID")
mongodump --uri="mongodb://admin:\$ADMIN_PWD@127.0.0.1:27017/?authSource=admin" --archive="\$FILE" --gzip
gcloud storage cp "\$FILE" "gs://$BACKUP_BUCKET/backups/"
rm -f "\$FILE"
echo "\$(date -u) backup caricato: gs://$BACKUP_BUCKET/backups/\$(basename \$FILE)"
EOF
chmod 700 /usr/local/bin/mongo-backup.sh # eseguibile solo da root

# Pianifica il backup ogni giorno alle 02:00 UTC via cron.
echo "0 2 * * * root /usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1" > /etc/cron.d/mongo-backup
chmod 644 /etc/cron.d/mongo-backup

# Esegue un primo backup subito, cosi' il bucket (pubblico) non e' vuoto in demo:
# e' questo dump che poi si puo' scaricare anonimamente per dimostrare la fuga dati.
/usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1 || true

echo "== Setup completato =="
