#!/bin/bash
# -----------------------------------------------------------------------------
# Startup script della VM MongoDB (renderizzato da Terraform con templatefile).
# Nota: le variabili bash sono scritte SENZA graffe per non collidere con
# l'interpolazione di Terraform.
# -----------------------------------------------------------------------------
set -euo pipefail
exec > >(tee -a /var/log/wiz-mongo-setup.log) 2>&1

export PATH=$PATH:/snap/bin:/usr/bin
MARKER=/var/lib/wiz-mongo-installed
MONGO_VERSION="${mongo_version}"
BACKUP_BUCKET="${backup_bucket}"
PROJECT_ID="${project_id}"

get_secret() {
  # retry: al primo boot l'IAM puo' impiegare qualche secondo a propagarsi
  for i in $(seq 1 30); do
    if gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID" 2>/dev/null; then
      return 0
    fi
    sleep 10
  done
  echo "Impossibile leggere il secret $1" >&2
  return 1
}

if [ ! -f "$MARKER" ]; then
  echo "== Installazione MongoDB $MONGO_VERSION =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y gnupg curl

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

  for i in $(seq 1 30); do
    mongosh --quiet --eval "db.adminCommand('ping').ok" && break
    sleep 2
  done

  ADMIN_PWD=$(get_secret "${admin_secret}")
  APP_PWD=$(get_secret "${app_secret}")

  echo "== Creazione utenti =="
  mongosh --quiet admin --eval "
    db.createUser({user: 'admin', pwd: '$ADMIN_PWD', roles: [{role: 'root', db: 'admin'}]});
  "
  mongosh --quiet go-mongodb --eval "
    db.createUser({user: 'tasky', pwd: '$APP_PWD', roles: [{role: 'readWrite', db: 'go-mongodb'}]});
  "

  echo "== Abilitazione autenticazione =="
  if ! grep -q '^security:' /etc/mongod.conf; then
    printf '\nsecurity:\n  authorization: enabled\n' >> /etc/mongod.conf
  fi
  systemctl restart mongod

  touch "$MARKER"
fi

# --- Script di backup ----------------------------------------------------------
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
chmod 700 /usr/local/bin/mongo-backup.sh

# Backup giornaliero alle 02:00 UTC
echo "0 2 * * * root /usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1" > /etc/cron.d/mongo-backup
chmod 644 /etc/cron.d/mongo-backup

# Primo backup subito, cosi' il bucket non e' vuoto durante la demo
/usr/local/bin/mongo-backup.sh >> /var/log/mongo-backup.log 2>&1 || true

echo "== Setup completato =="
