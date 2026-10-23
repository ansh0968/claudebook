#!/usr/bin/env bash
# Runs on the Oracle server during every deploy. Safe to re-run.
# Plugs into the host's existing nginx + firewalld; never stops or rewrites other services.
set -euo pipefail
cd "$(dirname "$0")"
DOMAIN=book.clarifiq.in
CONF=/etc/nginx/conf.d/claudebook.conf
ACME_ROOT=/var/www/claudebook-acme
log() { printf '>> %s\n' "$*"; }

# 0. Room to build?
avail_kb=$(df --output=avail -k / | tail -1)
if [ "$avail_kb" -lt 2000000 ]; then echo "Less than 2GB free on /, refusing to build"; exit 1; fi

# 1. App secret: keep the one already on the box, use the CI-provided one if given, else generate.
touch .env && chmod 600 .env
if [ -n "${CLAUDEBOOK_SECRET:-}" ]; then
  grep -v '^CLAUDEBOOK_SECRET=' .env > .env.tmp || true
  echo "CLAUDEBOOK_SECRET=$CLAUDEBOOK_SECRET" >> .env.tmp && mv .env.tmp .env && chmod 600 .env
elif ! grep -q '^CLAUDEBOOK_SECRET=' .env; then
  echo "CLAUDEBOOK_SECRET=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 40)" >> .env
  log "generated a new app secret"
fi

# 2. App container, bound to localhost only.
mkdir -p data
log "building and starting the container"
sudo docker compose up -d --build --remove-orphans
for i in $(seq 1 30); do curl -fsS http://127.0.0.1:8787/health >/dev/null 2>&1 && break; sleep 2; done
curl -fsS http://127.0.0.1:8787/health >/dev/null || { sudo docker compose logs --tail 50; exit 1; }
log "app healthy on 127.0.0.1:8787"

# 3. SELinux: nginx must be allowed to proxy to a local port.
if command -v getsebool >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
  if getsebool httpd_can_network_connect | grep -q off; then
    log "enabling SELinux httpd_can_network_connect"
    sudo setsebool -P httpd_can_network_connect on
  fi
fi

# 4. Firewall: only add http/https if missing (other rules untouched).
if sudo firewall-cmd --state >/dev/null 2>&1; then
  for svc in http https; do
    sudo firewall-cmd --query-service=$svc >/dev/null || { sudo firewall-cmd --permanent --add-service=$svc >/dev/null; reload_fw=1; }
  done
  [ -n "${reload_fw:-}" ] && sudo firewall-cmd --reload >/dev/null && log "opened http/https in firewalld"
fi

# Install an nginx config only if the whole config still validates; otherwise put the old one back.
install_conf() {
  local src=$1 backup
  backup=$(mktemp)
  if sudo test -f "$CONF"; then sudo cp "$CONF" "$backup"; else : > "$backup"; fi
  sudo cp "$src" "$CONF"
  sudo restorecon "$CONF" 2>/dev/null || true
  if sudo nginx -t 2>/tmp/nginx-test.log; then
    sudo systemctl reload nginx
  else
    cat /tmp/nginx-test.log
    if [ -s "$backup" ]; then sudo cp "$backup" "$CONF"; else sudo rm -f "$CONF"; fi
    echo "nginx rejected the new config, previous config restored"; exit 1
  fi
}

# 5. HTTPS certificate via Let's Encrypt (webroot, so nginx keeps running the whole time).
sudo mkdir -p "$ACME_ROOT"
sudo restorecon -R "$ACME_ROOT" 2>/dev/null || true
if ! command -v certbot >/dev/null; then
  log "installing certbot from Oracle's EPEL"
  sudo dnf install -y -q oracle-epel-release-el9
  sudo dnf install -y -q --enablerepo=ol9_developer_EPEL certbot
fi
if ! sudo test -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem; then
  log "requesting certificate for $DOMAIN"
  sudo test -f "$CONF" || install_conf nginx-claudebook-bootstrap.conf
  sudo certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
fi
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
sudo systemctl enable --now certbot-renew.timer >/dev/null 2>&1 || true

# 6. Final nginx site.
install_conf nginx-claudebook.conf
log "nginx serving https://$DOMAIN"
sudo docker compose ps
