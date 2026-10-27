#!/usr/bin/env bash
# UC00636 - Instalacao opcional do dashboard, sem tocar nos Scripts 01-11.
set -Eeuo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'ERRO: executar com sudo.' >&2; exit 1; }
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$DIR/dashboard.html" && -f "$DIR/collect.sh" ]] || { echo 'ERRO: ficheiros do dashboard em falta.' >&2; exit 1; }
systemctl is-active --quiet httpd || { echo 'ERRO: Apache inativo. Executar primeiro Script 01.' >&2; exit 1; }
install -d -m 0755 /usr/local/libexec
install -m 0700 "$DIR/collect.sh" /usr/local/libexec/uc00636-dashboard-collect
if [[ -f /var/www/html/dashboard.html ]]; then
    install -d -m 0700 /root/uc00636-dashboard-backups
    cp -p /var/www/html/dashboard.html "/root/uc00636-dashboard-backups/dashboard-$(date +%Y%m%d-%H%M%S).html"
fi
install -m 0644 "$DIR/dashboard.html" /var/www/html/dashboard.html
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F /var/www/html/dashboard.html >/dev/null 2>&1 || true
fi
cat > /etc/systemd/system/uc00636-dashboard.service <<'EOF'
[Unit]
Description=UC00636 - Recolha de indicadores publicos do dashboard
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/uc00636-dashboard-collect
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/www/html
EOF
cat > /etc/systemd/system/uc00636-dashboard.timer <<'EOF'
[Unit]
Description=UC00636 - Atualizacao de indicadores do dashboard

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=false
Unit=uc00636-dashboard.service

[Install]
WantedBy=timers.target
EOF
chmod 0644 /etc/systemd/system/uc00636-dashboard.{service,timer}
systemctl daemon-reload
systemctl start uc00636-dashboard.service
systemctl enable --now uc00636-dashboard.timer
printf '\nOK: dashboard instalado.\n'
printf 'Acesso na rede: http://IP_DA_VM/dashboard.html\n'
printf 'Atualizacao: a cada 60 segundos.\n'
printf 'Acesso HTTPS externo depende do router, NAT e certificado de cada colega.\n'
