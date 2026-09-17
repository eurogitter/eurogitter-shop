#!/usr/bin/env bash
# ============================================================
#  Eurogitter – Server-Einrichtung (Ubuntu 22.04 / 24.04, als root)
#  Aufruf in der Server-Konsole (eine Zeile):
#     bash <(curl -fsSL https://raw.githubusercontent.com/eurogitter/eurogitter-shop/main/setup.sh)
#  Kann jederzeit erneut ausgefuehrt werden: holt den neuesten Stand (eurogitter-shop.zip)
#  von GitHub, behaelt Datenbank und .env, startet den Shop neu und richtet HTTPS ein,
#  sobald die Domain auf diesen Server zeigt.
# ============================================================
set -eu
DOMAIN="eurogitter.de"
GITHUB_USER="eurogitter"                # GitHub-Konto des Betreibers
REPO_NAME="eurogitter-shop"
APP="/opt/eurogitter"
BACKUPS="/opt/eurogitter-backups"
PORT="3100"
MAILBOX="info@eurogitter.de"
SVC_USER="eurogitter"
export DEBIAN_FRONTEND=noninteractive

echo "### Eurogitter Setup fuer $DOMAIN ###"

# --- GitHub-Konto fuer den Download ermitteln -------------------------------
if [ "$GITHUB_USER" = "DEIN-GITHUB-KONTO" ]; then
  printf "Ihr GitHub-Kontoname (Besitzer des Repositories %s): " "$REPO_NAME"
  read -r GITHUB_USER </dev/tty
fi
RAW="https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main"

# --- Pakete ---------------------------------------------------------------
apt-get update -y
apt-get install -y curl unzip rsync nginx ca-certificates ufw certbot python3-certbot-nginx sqlite3

# --- Node.js 24 (node:sqlite ist dort ohne Zusatz-Flag enthalten) --------
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt 24 ]; then
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
fi
echo "Node.js: $(node -v)"

# --- Firewall: nur SSH, HTTP, HTTPS ---------------------------------------
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null

# --- Eigener Systembenutzer fuer den Shop (kein root im Dauerbetrieb) ------
id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --home "$APP" --shell /usr/sbin/nologin "$SVC_USER"

# --- Shop-Code von GitHub holen (ZIP) und einspielen; data/ und .env bleiben ---
TMP="$(mktemp -d)"
echo "Lade $RAW/$REPO_NAME.zip ..."
curl -fsSL "$RAW/$REPO_NAME.zip" -o "$TMP/shop.zip"
unzip -q "$TMP/shop.zip" -d "$TMP/shop"
SRC="$TMP/shop"
[ -f "$SRC/server.js" ] || SRC="$(dirname "$(find "$TMP/shop" -maxdepth 3 -name server.js | head -1)")"
mkdir -p "$APP/data/invoices" "$APP/data/mail-vorschau"
rsync -a --delete --exclude 'data/' --exclude '.env' "$SRC/" "$APP/"
rm -rf "$TMP"
cd "$APP"

# --- .env nur beim ersten Mal anlegen (Passwoerter bleiben bei Updates erhalten) ---
if [ ! -f .env ]; then
  ADMINPW="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  echo
  echo "Ein paar Angaben fuer Rechnung und Impressum (Enter = leer lassen, spaeter in $APP/.env nachtragen):"
  printf "IBAN fuer die Rechnung: ";            read -r IBAN </dev/tty || IBAN=""
  printf "BIC: ";                               read -r BIC </dev/tty || BIC=""
  printf "Name der Bank: ";                     read -r BANK </dev/tty || BANK=""
  printf "USt-IdNr. (z. B. DE123456789): ";     read -r USTID </dev/tty || USTID=""
  printf "Telefonnummer fuers Impressum (Enter = keine): "; read -r PHONE </dev/tty || PHONE=""
  echo
  echo "Passwort des Postfachs $MAILBOX (Namecheap Private Email), damit der Shop echte E-Mails"
  echo "verschicken kann (Bestellbestaetigung, Rechnung, Kontakt). Nur Enter = spaeter in $APP/.env eintragen."
  printf "SMTP-Passwort: "
  SMTPPW=""
  read -r -s SMTPPW </dev/tty || SMTPPW=""
  echo
  cat > .env <<EOF
PORT=$PORT
BASE_URL=https://$DOMAIN
SELLER_BRAND=Eurogitter
SELLER_NAME=Elbmarkt Handels GmbH
SELLER_LEGALFORM=GmbH
SELLER_ADDRESS=Emmy-Noether-Straße 2, 85221 Dachau
SELLER_COUNTRY=Deutschland
SELLER_MANAGER=Kim Kristensen
SELLER_MANAGER_ROLE=Geschäftsführer
SELLER_REGISTER_COURT=Amtsgericht München
SELLER_REGISTER_NO=HRB 316367
SELLER_EMAIL=$MAILBOX
SELLER_PHONE=$PHONE
SELLER_WEB=www.$DOMAIN
SELLER_USTID=$USTID
SELLER_TAXNUMBER=
SELLER_IBAN=$IBAN
SELLER_BIC=$BIC
SELLER_BANK=$BANK
SELLER_TAXRATE=19
PAYMENT_DAYS=14
DELIVERY_DAYS=3-6
ADMIN_EMAIL=admin@$DOMAIN
ADMIN_PASSWORD=$ADMINPW
SMTP_HOST=mail.privateemail.com
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=$MAILBOX
SMTP_PASS=$SMTPPW
MAIL_FROM=Eurogitter <$MAILBOX>
MAIL_BCC=$MAILBOX
EOF
  chmod 600 .env
  echo "$ADMINPW" > /root/EUROGITTER-ADMIN-PASSWORT.txt
  chmod 600 /root/EUROGITTER-ADMIN-PASSWORT.txt
fi

# --- Produkte anlegen (nur fehlende) und Rechte setzen ----------------------
node seed.js || true
chown -R "$SVC_USER":"$SVC_USER" "$APP"
chmod 600 "$APP/.env"

# --- Shop als Dienst (startet automatisch, auch nach Neustart) -------------
cat > /etc/systemd/system/eurogitter.service <<EOF
[Unit]
Description=Eurogitter Shop
After=network.target

[Service]
WorkingDirectory=$APP
EnvironmentFile=$APP/.env
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=3
User=$SVC_USER
Group=$SVC_USER
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable eurogitter >/dev/null
systemctl restart eurogitter

# --- nginx als Tuersteher (Port 80/443 -> Shop auf $PORT) -------------------
cat > /etc/nginx/sites-available/eurogitter <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    client_max_body_size 25M;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/eurogitter /etc/nginx/sites-enabled/eurogitter
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx

# --- Taegliche Sicherung von Datenbank und Rechnungen (14 Tage aufbewahren) ---
mkdir -p "$BACKUPS"
cat > /usr/local/bin/eurogitter-backup.sh <<EOF
#!/usr/bin/env bash
set -eu
STAMP="\$(date +%Y-%m-%d_%H-%M)"
sqlite3 "$APP/data/shop.db" ".backup '$BACKUPS/shop-\$STAMP.db'"
tar -czf "$BACKUPS/rechnungen-\$STAMP.tar.gz" -C "$APP/data" invoices 2>/dev/null || true
cp "$APP/.env" "$BACKUPS/env-\$STAMP.txt" && chmod 600 "$BACKUPS/env-\$STAMP.txt"
find "$BACKUPS" -type f -mtime +14 -delete
EOF
chmod 700 /usr/local/bin/eurogitter-backup.sh
( crontab -l 2>/dev/null | grep -v eurogitter-backup ; echo "30 3 * * * /usr/local/bin/eurogitter-backup.sh" ) | crontab -
/usr/local/bin/eurogitter-backup.sh || true

# --- HTTPS mit Let's Encrypt (klappt erst, wenn die Domain auf diesen Server zeigt) ---
if certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "$MAILBOX" --redirect >/tmp/certbot.log 2>&1; then
  echo "HTTPS eingerichtet (Zertifikat verlaengert sich automatisch)."
else
  echo "HINWEIS: HTTPS noch nicht eingerichtet – zeigt die Domain schon auf diesen Server?"
  echo "         Spaeter einfach dieses Skript erneut ausfuehren oder:"
  echo "         certbot --nginx -d $DOMAIN -d www.$DOMAIN --redirect"
fi

# --- Kurzer Selbsttest ------------------------------------------------------
sleep 2
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || echo 000)"
echo
echo "### FERTIG ###"
echo "Shop antwortet intern mit HTTP $CODE (200 = gut)."
echo "Shop:   https://$DOMAIN"
echo "Admin:  https://$DOMAIN/admin"
echo "Login:  admin@$DOMAIN   Passwort: $(cat /root/EUROGITTER-ADMIN-PASSWORT.txt)"
echo "(Das Passwort steht auch in /root/EUROGITTER-ADMIN-PASSWORT.txt – nach dem ersten Login bitte aendern.)"
echo "Sicherungen: taeglich 03:30 Uhr nach $BACKUPS"
echo "Status:  systemctl status eurogitter     Protokoll: journalctl -u eurogitter -n 50"
