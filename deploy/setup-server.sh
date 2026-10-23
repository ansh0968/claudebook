#!/usr/bin/env bash
# Runs on the Oracle server during every deploy. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v docker >/dev/null; then
  echo "Installing Docker"
  if command -v apt-get >/dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
  else
    sudo dnf install -y dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  sudo systemctl enable --now docker
fi

# Oracle's images ship a host firewall that blocks 80/443 even when the cloud security list allows them.
if command -v firewall-cmd >/dev/null && sudo firewall-cmd --state >/dev/null 2>&1; then
  sudo firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
  sudo firewall-cmd --reload >/dev/null
elif command -v iptables >/dev/null; then
  for port in 80 443; do
    sudo iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || sudo iptables -I INPUT 5 -p tcp --dport $port -j ACCEPT
  done
  if command -v netfilter-persistent >/dev/null; then sudo netfilter-persistent save >/dev/null; fi
fi

mkdir -p data
sudo docker compose up -d --build --remove-orphans
sudo docker image prune -f >/dev/null
sudo docker compose ps
