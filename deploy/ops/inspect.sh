# Read-only look at the server before deploying. Changes nothing.
section() { printf '\n===== %s =====\n' "$1"; }
section system; cat /etc/os-release | grep -E '^(NAME|VERSION)='; uname -m; uptime; free -m; df -h / /home 2>/dev/null
section listeners; sudo ss -ltnp
section docker; command -v docker && sudo docker version --format '{{.Server.Version}}' 2>&1; sudo docker ps -a 2>&1 | head -30; command -v podman && podman --version
section compose; sudo docker compose version 2>&1 | head -1
section running-services; systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}'
section web-servers
for b in nginx caddy httpd apache2 haproxy traefik; do command -v $b >/dev/null && echo "$b: $(command -v $b)"; done
[ -d /etc/nginx ] && { echo "--- nginx conf files"; sudo find /etc/nginx -name '*.conf' -o -path '*sites-enabled*' -type f | head -40; echo "--- nginx server_names"; sudo nginx -T 2>/dev/null | grep -E '^\s*(server_name|listen|proxy_pass|root|ssl_certificate )' | sort | uniq -c | head -60; }
[ -f /etc/caddy/Caddyfile ] && { echo "--- Caddyfile"; sudo cat /etc/caddy/Caddyfile; }
[ -d /etc/httpd ] && sudo grep -rhE 'ServerName|Listen|ProxyPass' /etc/httpd 2>/dev/null | head -30
section certs; sudo ls /etc/letsencrypt/live 2>/dev/null; command -v certbot
section selinux; command -v getenforce && getenforce
section firewall; sudo firewall-cmd --state 2>&1; sudo firewall-cmd --list-all 2>&1 | head -20; sudo iptables -S INPUT 2>&1 | head -20
section local-http; curl -sS -o /dev/null -w 'http://127.0.0.1 -> %{http_code}\n' http://127.0.0.1 2>&1; curl -sSk -o /dev/null -w 'https://book.clarifiq.in (local) -> %{http_code}\n' --resolve book.clarifiq.in:443:127.0.0.1 https://book.clarifiq.in 2>&1
section home; ls -la ~ | head -40; ls ~/claudebook 2>&1 | head
section node; command -v node && node -v
