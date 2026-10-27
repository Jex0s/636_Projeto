#!/usr/bin/env bash
# UC00636 - Recolha local de indicadores publicos do Dashboard
# Sem credenciais, IPs, logs integrais ou operacoes administrativas pela web.
set -Eeuo pipefail
umask 022

DEST='/var/www/html/dashboard-status.json'
[[ "$EUID" -eq 0 ]] || { echo 'ERRO: executar como root.' >&2; exit 1; }
[[ -d /var/www/html ]] || { echo 'ERRO: diretório Apache não encontrado.' >&2; exit 1; }

service_state() {
    local unit="$1" package="$2"
    if systemctl is-active --quiet "$unit"; then
        printf 'active'
    elif rpm -q "$package" >/dev/null 2>&1; then
        printf 'inactive'
    else
        printf 'not_installed'
    fi
}

read_cpu() {
    local -a a b
    read -ra a < /proc/stat
    sleep 0.25
    read -ra b < /proc/stat
    local i total1=0 total2=0 idle1 idle2 used
    for ((i=1;i<=8;i++)); do total1=$((total1 + ${a[i]:-0})); total2=$((total2 + ${b[i]:-0})); done
    idle1=$((${a[4]:-0} + ${a[5]:-0}))
    idle2=$((${b[4]:-0} + ${b[5]:-0}))
    if ((total2 > total1)); then
        used=$((100 * ((total2-total1)-(idle2-idle1)) / (total2-total1)))
        ((used<0)) && used=0
        ((used>100)) && used=100
        printf '%d' "$used"
    else
        printf '0'
    fi
}

cpu=$(read_cpu)
ram=$(awk '/MemTotal:/{t=$2} /MemAvailable:/{a=$2} END{if(t>0) printf "%.0f",100*(t-a)/t; else print 0}' /proc/meminfo)
disk=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5);print $5+0}')
uptime=$(awk '{printf "%.0f",$1}' /proc/uptime)

apache=$(service_state httpd httpd)
php=$(service_state php-fpm php-fpm)
maria=$(service_state mariadb mariadb-server)
fail2ban=$(service_state fail2ban fail2ban)
cron=$(service_state crond cronie)
selinux=$(getenforce 2>/dev/null || printf 'Unknown')

# Módulos: verificar apenas se o Apache se encontra a funcionar.
modsec='inactive'
if [[ "$apache" == 'active' ]] && /usr/sbin/httpd -M 2>/dev/null | grep -q 'security2_module'; then
    modsec='active'
fi

tls='not_configured'
if [[ "$apache" == 'active' && -s /etc/letsencrypt/live/uc00636-ip-prod/fullchain.pem ]]; then
    if openssl x509 -checkend 0 -noout -in /etc/letsencrypt/live/uc00636-ip-prod/fullchain.pem >/dev/null 2>&1; then
        tls='certificate_valid'
    else
        tls='certificate_expired'
    fi
fi

# Contar apenas códigos HTTP agregados; não divulgar IPs ou URLs dos clientes.
requests='null'; errors4='null'; errors5='null'
if [[ -r /var/log/httpd/access_log ]]; then
    day=$(LC_ALL=C date '+%d/%b/%Y')
    read -r requests errors4 errors5 < <(awk -v day="$day" 'index($4,day)==2 {r++; if($9 ~ /^4/) a++; if($9 ~ /^5/) b++} END{print r+0,a+0,b+0}' /var/log/httpd/access_log)
fi

# Ler somente o nome do diretório de backup datado, nunca publicar ficheiros internos.
last_backup='null'
if [[ -d /backups/uc00636 ]]; then
    name=$(find /backups/uc00636 -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^20[0-9]{6}_[0-9]{6}$' | LC_ALL=C sort | tail -1 || true)
    if [[ "$name" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})[0-9]{2}$ ]]; then
        last_backup='"'"${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}"'"'
    fi
fi

# JSON só contém nomes de estados fixos, datas ISO e números calculados localmente.
tmp=$(mktemp '/var/www/html/.dashboard-status.XXXXXXXX')
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<JSON
{
  "schema": 1,
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "metrics": {"cpu_percent": $cpu, "ram_percent": $ram, "disk_percent": $disk, "uptime_seconds": $uptime},
  "services": {"apache": "$apache", "php_fpm": "$php", "mariadb": "$maria", "fail2ban": "$fail2ban", "cron": "$cron", "modsecurity": "$modsec"},
  "security": {"selinux": "$selinux", "tls": "$tls"},
  "http_today": {"requests": $requests, "errors_4xx": $errors4, "errors_5xx": $errors5},
  "last_backup": $last_backup
}
JSON
chmod 0644 "$tmp"
if command -v restorecon >/dev/null 2>&1; then restorecon -F "$tmp" >/dev/null 2>&1 || true; fi
mv -f "$tmp" "$DEST"
if command -v restorecon >/dev/null 2>&1; then restorecon -F "$DEST" >/dev/null 2>&1 || true; fi
trap - EXIT
