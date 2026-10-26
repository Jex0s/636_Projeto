#!/bin/bash
 
# ==============================================================
# UC00636 - Projeto de Automatizacao em CentOS Stream 10
# SCRIPT 05 - Fail2ban
# Objetivo: proteger o SSH e o Apache contra ataques de forca bruta.
# Bloqueia um IP apos 3 tentativas falhadas.
# Este script deve ser executado com: sudo ./05_fail2ban.sh
# ==============================================================
 
# Conta Gmail do projeto: envia os alertas e tambem os recebe.
# Vazio = sem email (os bloqueios funcionam, mas sem alerta).
EMAIL="centosservidorweb@gmail.com"
 
# PASSO 1 - Confirmar que o utilizador tem permissoes de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: deves executar este script com sudo."
    exit 1
fi
 
mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/05_fail2ban.log"
 
echo "===== Inicio do Script 05: $(date) =====" | tee -a "$LOG"
 
# PASSO 2 - Confirmar que os scripts anteriores ja foram corridos.
# O Fail2ban le os logs do Apache (script 01) e usa o firewalld para bloquear IPs.
if [ ! -d /var/log/httpd ]; then
    echo "ERRO: o Apache nao esta instalado. Corre primeiro o script 01." | tee -a "$LOG"
    exit 1
fi
 
systemctl is-active --quiet firewalld
if [ $? -ne 0 ]; then
    echo "ERRO: o firewalld nao esta ativo. Corre primeiro o script 03." | tee -a "$LOG"
    exit 1
fi
 
# PASSO 3 - Instalar o Fail2ban.
# O Fail2ban nao vem nos repositorios do CentOS, esta no repositorio EPEL.
# O pacote fail2ban inclui o fail2ban-firewalld, que bloqueia os IPs no firewalld.
echo "PASSO 3 - Instalacao do EPEL e do Fail2ban" | tee -a "$LOG"
dnf install -y epel-release >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel instalar o repositorio EPEL." | tee -a "$LOG"
    exit 1
fi
 
dnf install -y fail2ban >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel instalar o Fail2ban." | tee -a "$LOG"
    exit 1
fi
echo "OK: Fail2ban instalado." | tee -a "$LOG"

# PASSO 3B - Preparar o envio de email pelo Gmail (Postfix como relay).
# O servidor nao recebe email: o Postfix so aceita mensagens da propria
# maquina (loopback-only) e entrega-as ao Gmail pela porta 587 com TLS.
# A palavra-passe de app do Gmail e pedida aqui e NUNCA vai para o repositorio.
if [ -n "$EMAIL" ]; then
    echo "PASSO 3B - Envio de email pelo Gmail (Postfix)" | tee -a "$LOG"
    # whois: o Fail2ban junta ao alerta a informacao do IP bloqueado.
    dnf install -y postfix cyrus-sasl-plain s-nail whois >> "$LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "ERRO: nao foi possivel instalar o Postfix." | tee -a "$LOG"
        exit 1
    fi

    # texthash le o ficheiro diretamente (o CentOS 10 ja nao usa o formato hash).
    postconf -e "relayhost = [smtp.gmail.com]:587" \
        "smtp_sasl_auth_enable = yes" \
        "smtp_sasl_password_maps = texthash:/etc/postfix/sasl_passwd" \
        "smtp_sasl_security_options = noanonymous" \
        "smtp_tls_security_level = encrypt" \
        "smtp_tls_CAfile = /etc/pki/tls/certs/ca-bundle.crt" \
        "inet_interfaces = loopback-only"

    # So pede a palavra-passe se ainda nao estiver guardada.
    if [ ! -s /etc/postfix/sasl_passwd ]; then
        APP=""
        while [ -z "$APP" ]; do
            read -r -s -p "Palavra-passe de app do Gmail ($EMAIL), sem espacos: " APP; echo
        done
        umask 077
        echo "[smtp.gmail.com]:587 $EMAIL:$APP" > /etc/postfix/sasl_passwd
        unset APP
        chmod 600 /etc/postfix/sasl_passwd
        echo "OK: palavra-passe de app guardada em /etc/postfix/sasl_passwd (chmod 600)." | tee -a "$LOG"
    else
        echo "OK: palavra-passe de app ja configurada." | tee -a "$LOG"
    fi

    # Repor as etiquetas SELinux: com etiquetas erradas o Postfix nao arranca
    # pelo systemd (erro "master.lock: Permission denied").
    restorecon -R /var/lib/postfix /var/spool/postfix /etc/postfix

    systemctl enable postfix >> "$LOG" 2>&1
    systemctl restart postfix
    if [ $? -ne 0 ]; then
        echo "ERRO: o Postfix nao arrancou. Ver: journalctl -u postfix" | tee -a "$LOG"
        exit 1
    fi

    echo "Teste de envio do script 05 em $(date)" | mail -s "UC00636 - teste de email ($(hostname))" "$EMAIL"
    echo "OK: Postfix ativo; email de teste enviado para $EMAIL." | tee -a "$LOG"
    echo "Confirmar envio: journalctl -u postfix | grep status=" | tee -a "$LOG"
fi
 
# PASSO 4 - Escolher a acao quando um IP e bloqueado.
# action_   -> so bloqueia o IP
# action_mw -> bloqueia e envia email com informacao sobre o IP
if [ -n "$EMAIL" ]; then
    ACAO="%(action_mw)s"
else
    ACAO="%(action_)s"
    echo "AVISO: sem email definido, os bloqueios nao enviam alerta." | tee -a "$LOG"
fi
 
# PASSO 5 - Criar a configuracao das jails.
# Nunca se altera o jail.conf (e substituido nas atualizacoes),
# as nossas regras ficam no jail.local, que tem prioridade.
# O cat com <<EOF escreve no ficheiro todas as linhas ate ao EOF.
echo "PASSO 5 - Configuracao das jails (SSH e Apache)" | tee -a "$LOG"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# 3 tentativas falhadas em 10 minutos = bloqueio de 1 hora
maxretry = 3
findtime = 10m
bantime  = 1h
 
# nunca bloquear o proprio servidor
ignoreip = 127.0.0.1/8 ::1
 
destemail = $EMAIL
sender    = fail2ban@$(hostname)
action    = $ACAO
 
# tentativas de login falhadas no SSH (lidas do journal do systemd)
[sshd]
enabled = true
port    = ssh
backend = systemd
 
# tentativas de login falhadas em paginas protegidas do Apache
[apache-auth]
enabled = true
port    = http,https
logpath = /var/log/httpd/*error_log
backend = auto
EOF
 
# PASSO 6 - Testar a configuracao antes de iniciar o servico.
fail2ban-client -t >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: a configuracao do Fail2ban tem erros. Ver $LOG" | tee -a "$LOG"
    exit 1
fi
echo "OK: configuracao valida." | tee -a "$LOG"
 
# PASSO 7 - Iniciar o Fail2ban e ativa-lo no arranque.
# restart em vez de start para aplicar a configuracao se o script for corrido de novo.
echo "PASSO 7 - Ativacao do servico" | tee -a "$LOG"
systemctl enable fail2ban >> "$LOG" 2>&1
systemctl restart fail2ban
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel iniciar o Fail2ban." | tee -a "$LOG"
    exit 1
fi
 
# O Fail2ban demora uns segundos a carregar as jails.
sleep 3
 
# PASSO 8 - Confirmar que as duas jails estao ativas.
for jail in sshd apache-auth; do
    fail2ban-client status "$jail" >> "$LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "ERRO: a jail $jail nao esta ativa." | tee -a "$LOG"
        exit 1
    fi
    echo "OK: jail $jail ativa." | tee -a "$LOG"
done
 
# PASSO 9 - Mostrar o estado final.
# Os IPs bloqueados ficam registados em /var/log/fail2ban.log (linhas "Ban").
echo "" | tee -a "$LOG"
fail2ban-client status | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "Ver IPs bloqueados:   fail2ban-client status sshd" | tee -a "$LOG"
echo "Historico de bloqueios: grep Ban /var/log/fail2ban.log" | tee -a "$LOG"
echo "Desbloquear um IP:    fail2ban-client set sshd unbanip <IP>" | tee -a "$LOG"
 
echo "===== Script 05 concluido: $(date) =====" | tee -a "$LOG"
