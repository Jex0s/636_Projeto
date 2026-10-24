#!/bin/bash
# =====================================================================
# UC00636 - SCRIPT 07 - Desempenho Apache + HTTPS/TLS
# CentOS Stream 10 / Apache 2.4 / Certbot em /opt/certbot
#
# Modos independentes para facilitar a explicacao na defesa:
#   ajuda                       - mostra os modos
#   desempenho                 - KeepAlive, gzip, MPM event (modo padrao)
#   https-preparar             - instala mod_ssl e Certbot 5.4+ em venv
#   cert-teste IPV4            - pede certificado ACME de testes (staging)
#   cert-producao IPV4         - pede certificado publico real
#   https-aplicar              - associa certificado de producao ao Apache
#   renovacao-preparar         - cria hook e unidades systemd SEM ativar timer
#
# IMPORTANTE:
# - Os comandos nao configuram router NOS, Windows Firewall ou VMware NAT.
# - Para cert-teste e cert-producao, a porta 80 publica deve estar
#   temporariamente acessivel ao Let's Encrypt (HTTP-01).
# - A renovacao automatica FALHARA com o encaminhamento externo fechado.
# - HTTPS-aplicar so usa certificado ja emitido, nunca pede outro.
# =====================================================================

CONF="/etc/httpd/conf.d/uc00636-tuning.conf"
SSL_CONF="/etc/httpd/conf.d/ssl.conf"
BACKUP_DIR="/root/uc00636_backup_apache"
LOG_DIR="/var/log/uc00636"
LOG="$LOG_DIR/07_tuning_apache.log"
CERTBOT="/opt/certbot/bin/certbot"
CERT_NAME="uc00636-ip-prod"
WEBROOT="/var/www/html"
SERVICO="/etc/systemd/system/uc00636-certbot.service"
TIMER="/etc/systemd/system/uc00636-certbot.timer"
HOOK="/etc/letsencrypt/renewal-hooks/deploy/uc00636-apache.sh"

ajuda() {
    cat <<'EOF'
UC00636 - SCRIPT 07 | Apache + HTTPS (v0.2)
  ajuda                      Mostra este menu (sem alterar o sistema).
  desempenho                Aplica tuning/gzip; igual a executar sem argumentos.
  https-preparar            Instala mod_ssl e Certbot em ambiente virtual.
  cert-teste IPV4           Emite certificado de TESTE para o IP (porta 80 publica).
  cert-producao IPV4        Emite certificado REAL para o IP (porta 80 publica).
  https-aplicar             Aplica certificado existente 'uc00636-ip-prod'.
  renovacao-preparar        Prepara hook, service e timer, mas NAO ativa timer.

Ordem numa VM limpa apos Script 01: desempenho -> https-preparar ->
cert-teste (opcional) -> cert-producao -> https-aplicar -> renovacao-preparar.
A configuracao de NAT/router/Windows e manual e externa ao CentOS.
EOF
}

preparar_log() {
    install -d -m 0700 "$LOG_DIR" "$BACKUP_DIR" || exit 1
    touch "$LOG" || exit 1
    chmod 0600 "$LOG"
}

info() {
    echo "$*" | tee -a "$LOG"
}

validar_httpd() {
    if ! /usr/sbin/httpd -t >> "$LOG" 2>&1; then
        info "ERRO: sintaxe Apache invalida; consulta $LOG"
        return 1
    fi
}

# --------------------------------------------------------------
# ETAPA 1 - DESEMPENHO (mantem os parametros ja validados)
# --------------------------------------------------------------
desempenho() {
    local MEM_MB WORKERS BACKUP="" TENTATIVA_NOVA=0 TEMP
    info "=== Script 07 desempenho iniciado: $(date) ==="

    if ! systemctl is-active --quiet httpd; then
        info 'ERRO: Apache nao esta ativo. Executar antes o Script 01.'
        return 1
    fi
    if ! httpd -M 2>/dev/null | grep -q mpm_event_module; then
        info 'ERRO: o script exige MPM event.'
        return 1
    fi
    if ! httpd -M 2>/dev/null | grep -q deflate_module; then
        info 'ERRO: o script exige mod_deflate.'
        return 1
    fi

    MEM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    if [ -z "$MEM_MB" ]; then
        info 'ERRO: nao foi possivel identificar a memoria.'
        return 1
    fi
    if [ "$MEM_MB" -ge 4096 ]; then WORKERS=100; else WORKERS=50; fi
    info "Memoria: ${MEM_MB} MB | MaxRequestWorkers: $WORKERS"

    if [ -f "$CONF" ]; then
        BACKUP="$BACKUP_DIR/uc00636-tuning-$(date +%Y%m%d-%H%M%S).conf"
        cp -p "$CONF" "$BACKUP" || { info 'ERRO: backup da configuracao'; return 1; }
        info "Backup: $BACKUP"
    else
        TENTATIVA_NOVA=1
    fi

    TEMP=$(mktemp /etc/httpd/conf.d/.uc00636-tuning.XXXXXX) || return 1
    if ! cat > "$TEMP" <<EOCONF
# UC00636 - Parametros de desempenho; gerado pelo Script 07.
# KeepAlive reutiliza ligacoes HTTP para varios pedidos.
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 3
Timeout 30

# MPM event: cada processo usa 25 threads.
<IfModule mpm_event_module>
    ThreadsPerChild 25
    MaxRequestWorkers $WORKERS
</IfModule>

# Compressao de conteudos textuais e ficheiros estaticos.
<IfModule deflate_module>
    AddOutputFilterByType DEFLATE text/html text/plain text/css text/javascript application/javascript application/json application/xml text/xml
    <FilesMatch "\.(html|txt|css|js)$">
        SetOutputFilter DEFLATE
    </FilesMatch>
</IfModule>
EOCONF
    then
        rm -f "$TEMP"
        info 'ERRO: nao foi possivel escrever a configuracao.'
        return 1
    fi

    chmod 644 "$TEMP"
    mv -f "$TEMP" "$CONF" || { rm -f "$TEMP"; return 1; }
    if ! validar_httpd || ! systemctl reload httpd || ! systemctl is-active --quiet httpd; then
        info 'ERRO: a restaurar a configuracao de desempenho anterior.'
        if [ "$TENTATIVA_NOVA" -eq 1 ]; then
            rm -f "$CONF"
        else
            cp -p "$BACKUP" "$CONF"
        fi
        httpd -t >> "$LOG" 2>&1
        systemctl reload httpd >> "$LOG" 2>&1
        return 1
    fi
    info "OK: tuning e gzip aplicados em $CONF"
}

# --------------------------------------------------------------
# ETAPA 2 - PREPARAR SOFTWARE, SEM EMITIR CERTIFICADO PUBLICO
# --------------------------------------------------------------
https_preparar() {
    info 'PASSO HTTPS - Instalar mod_ssl'
    dnf install -y mod_ssl || return 1

    # No CentOS Stream 10, este servico inicializa o certificado localhost.
    # E preciso para que o ssl.conf instalado por mod_ssl seja valido.
    if [ ! -s /etc/pki/tls/certs/localhost.crt ]; then
        systemctl start httpd-init.service || {
            info 'ERRO: httpd-init.service falhou.'; return 1;
        }
    fi
    validar_httpd || return 1

    if [ ! -x "$CERTBOT" ]; then
        info 'PASSO HTTPS - Criar ambiente Python e instalar Certbot'
        python3 -m venv /opt/certbot || return 1
        /opt/certbot/bin/python -m pip install 'certbot>=5.4,<6' || return 1
    else
        info 'OK: Certbot ja instalado em /opt/certbot.'
    fi
    install -d -m 0755 "$WEBROOT/.well-known/acme-challenge" || return 1
    "$CERTBOT" --version | tee -a "$LOG"
    info 'OK: preparado. O router e a firewall externa NAO foram alterados.'
}

# --------------------------------------------------------------
# ETAPA 3 - PEDIR CERTIFICADO (REQUER PORTA 80 ACESSIVEL)
# --------------------------------------------------------------
certificado() {
    local ambiente="$1" ip="$2" nome
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        info 'ERRO: indica um IPv4 valido como parametro.'
        return 2
    fi
    if [ ! -x "$CERTBOT" ]; then
        info 'ERRO: instala primeiro o Certbot com https-preparar.'
        return 1
    fi
    if [ "$ambiente" = 'teste' ]; then
        nome='uc00636-ip-teste'
        info "A emitir certificado STAGING para $ip"
        "$CERTBOT" certonly --staging --preferred-profile shortlived \
            --webroot -w "$WEBROOT" --ip-address "$ip" --cert-name "$nome"
    else
        nome="$CERT_NAME"
        info "ATENCAO: certificado REAL para $ip. Usa apenas IP autorizado."
        "$CERTBOT" certonly --preferred-profile shortlived \
            --webroot -w "$WEBROOT" --ip-address "$ip" --cert-name "$nome"
    fi
}

# --------------------------------------------------------------
# ETAPA 4 - USAR CERTIFICADO JA EMITIDO NO APACHE
# --------------------------------------------------------------
https_aplicar() {
    local cert="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
    local chave="/etc/letsencrypt/live/$CERT_NAME/privkey.pem"
    local backup

    if [ ! -s "$cert" ] || [ ! -s "$chave" ]; then
        info "ERRO: certificado ou chave inexistente para $CERT_NAME."
        info 'Primeiro emite o certificado com cert-producao IPV4.'
        return 1
    fi
    if [ ! -f "$SSL_CONF" ]; then
        info 'ERRO: ssl.conf nao encontrado. Executa https-preparar.'
        return 1
    fi
    if ! grep -qE '^[[:space:]]*SSLCertificateFile[[:space:]]' "$SSL_CONF" || \
       ! grep -qE '^[[:space:]]*SSLCertificateKeyFile[[:space:]]' "$SSL_CONF"; then
        info 'ERRO: diretivas SSL nao encontradas. Nao modificar automaticamente.'
        return 1
    fi

    backup="$BACKUP_DIR/ssl-$(date +%Y%m%d-%H%M%S).conf"
    cp -p "$SSL_CONF" "$backup" || return 1
    info "Backup da configuracao SSL: $backup"

    sed -i -E \
      -e "s|^[[:space:]]*SSLCertificateFile[[:space:]].*|SSLCertificateFile $cert|" \
      -e "s|^[[:space:]]*SSLCertificateKeyFile[[:space:]].*|SSLCertificateKeyFile $chave|" \
      "$SSL_CONF" || { cp -p "$backup" "$SSL_CONF"; return 1; }

    if ! validar_httpd || ! systemctl reload httpd; then
        info 'ERRO: a restaurar ssl.conf anterior.'
        cp -p "$backup" "$SSL_CONF"
        httpd -t >> "$LOG" 2>&1
        systemctl reload httpd >> "$LOG" 2>&1
        return 1
    fi
    info "OK: Apache usa o certificado de producao $CERT_NAME."
}

# --------------------------------------------------------------
# ETAPA 5 - HOOK + SERVICO + TIMER; NAO ATIVAR AUTOMATICAMENTE
# --------------------------------------------------------------
renovacao_preparar() {
    info 'PASSO RENOVACAO - Criar hook e unidades systemd'
    if [ ! -x "$CERTBOT" ]; then
        info 'ERRO: Certbot nao instalado.'
        return 1
    fi
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy || return 1

    cat > "$HOOK" <<'EOF'
#!/bin/bash
# UC00636 - Recarregar Apache apos renovacao TLS
/usr/sbin/httpd -t || exit 1
/usr/bin/systemctl reload httpd
EOF
    chmod 0755 "$HOOK" || return 1

    cat > "$SERVICO" <<EOF
[Unit]
Description=UC00636 - Renovacao do certificado TLS

[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --cert-name $CERT_NAME --non-interactive --quiet
EOF
    chmod 0644 "$SERVICO"

    cat > "$TIMER" <<'EOF'
[Unit]
Description=UC00636 - Agendamento da renovacao TLS

[Timer]
OnCalendar=*-*-* 03:00:00
OnCalendar=*-*-* 15:00:00
Persistent=false
Unit=uc00636-certbot.service

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$TIMER"

    bash -n "$HOOK" || return 1
    systemd-analyze verify "$SERVICO" "$TIMER" || return 1
    systemctl daemon-reload || return 1
    info 'OK: hook, servico e temporizador preparados.'
    info 'AVISO: o timer NAO foi ativado. HTTP-01 exige acesso publico TCP 80.'
    info 'Ativar somente quando a renovacao puder validar o IP sem interrupcoes.'
}

# --------------------------------------------------------------
# MENU PRINCIPAL - CADA MODO EXECUTA APENAS A SUA TAREFA
# --------------------------------------------------------------
case "${1:-desempenho}" in
    ajuda|help|-h|--help)
        ajuda
        exit 0
        ;;
    desempenho|https-preparar|cert-teste|cert-producao|https-aplicar|renovacao-preparar)
        ;;
    *)
        echo "ERRO: opcao desconhecida '$1'."
        ajuda
        exit 2
        ;;
esac

if [ "$EUID" -ne 0 ]; then
    echo 'ERRO: executa este script com sudo.'
    exit 1
fi
preparar_log

case "${1:-desempenho}" in
    desempenho) desempenho ;;
    https-preparar) https_preparar ;;
    cert-teste) certificado teste "${2:-}" ;;
    cert-producao) certificado producao "${2:-}" ;;
    https-aplicar) https_aplicar ;;
    renovacao-preparar) renovacao_preparar ;;
esac
