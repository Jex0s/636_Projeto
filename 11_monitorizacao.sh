#!/bin/bash

# ==============================================================
# UC00636 - Projeto de Automatizacao em CentOS Stream 10
# SCRIPT 11 - Monitorizacao
# Objetivo:
#  - sincronizar a hora por NTP (chrony)
#  - gerar relatorios dos logs do Apache e do SSH
#  - alertar automaticamente quando ha falhas de seguranca
# Este script deve ser executado com: sudo ./11_monitorizacao.sh
# ==============================================================

# Email para os alertas (o envio e configurado no script 05).
# Vazio = o alerta fica so registado nos logs.
EMAIL="centosservidorweb@gmail.com"

# PASSO 1 - Confirmar que o utilizador tem permissoes de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: deves executar este script com sudo."
    exit 1
fi

mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/11_monitorizacao.log"

echo "===== Inicio do Script 11: $(date) =====" | tee -a "$LOG"

# PASSO 2 - Sincronizacao horaria por NTP.
# O chrony e o cliente NTP do CentOS. Uma hora certa e essencial
# para os logs, para os certificados SSL e para o Fail2ban.
echo "PASSO 2 - Sincronizacao horaria (NTP)" | tee -a "$LOG"
dnf install -y chrony >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel instalar o chrony." | tee -a "$LOG"
    exit 1
fi

timedatectl set-timezone Europe/Lisbon
systemctl enable --now chronyd >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel iniciar o chronyd." | tee -a "$LOG"
    exit 1
fi
timedatectl set-ntp true

# A primeira sincronizacao pode demorar uns segundos: espera ate 30 s.
SINCRONIZADO="no"
for i in 1 2 3 4 5 6; do
    SINCRONIZADO=$(timedatectl show -p NTPSynchronized --value)
    if [ "$SINCRONIZADO" = "yes" ]; then
        break
    fi
    sleep 5
done

if [ "$SINCRONIZADO" = "yes" ]; then
    echo "OK: hora sincronizada por NTP (fuso Europe/Lisbon)." | tee -a "$LOG"
else
    echo "AVISO: o chrony esta ativo mas ainda nao sincronizou. Ver: chronyc sources" | tee -a "$LOG"
fi
chronyc tracking | grep -E "Reference ID|System time" | tee -a "$LOG"

# PASSO 3 - Criar o script que gera o relatorio e os alertas.
# Fica em /usr/local/bin para ser corrido de hora a hora pelo cron.
# O 'FIM' entre aspas faz com que as variaveis la dentro ($...) NAO sejam
# substituidas agora, mas sim quando o relatorio for gerado.
echo "PASSO 3 - Criacao do gerador de relatorios" | tee -a "$LOG"
RELATORIO_SH="/usr/local/bin/uc00636_relatorio.sh"

cat > "$RELATORIO_SH" <<'FIM'
#!/bin/bash
# Gerado pelo script 11 (UC00636). Corre de hora a hora pelo cron.
# Analisa os logs de HOJE e gera um relatorio; alerta se houver falhas novas.

EMAIL=""
PASTA="/var/log/uc00636/relatorios"
mkdir -p "$PASTA"
RELATORIO="$PASTA/relatorio_$(date +%Y-%m-%d).txt"
ESTADO="/var/log/uc00636/.ultimo_alerta"

ACCESS="/var/log/httpd/access_log"
ERROR="/var/log/httpd/error_log"

# Formatos de data usados em cada log:
# Apache access_log: 26/Oct/2026   | Apache error_log: Mon Oct 26
# /var/log/secure:   Oct 26 (dia com espaco se < 10) | fail2ban.log: 2026-10-26
HOJE_ACCESS=$(LC_ALL=C date +%d/%b/%Y)
HOJE_ERROR=$(LC_ALL=C date "+%a %b %d")
HOJE_SECURE=$(LC_ALL=C date "+%b %e")
HOJE_F2B=$(date +%Y-%m-%d)

{
echo "=============================================="
echo " Relatorio de monitorizacao - $(hostname)"
echo " Gerado em: $(date)"
echo "=============================================="

echo ""
echo "--- Apache (pedidos de hoje) ---"
if [ -f "$ACCESS" ]; then
    echo "Total de pedidos: $(grep -c "$HOJE_ACCESS" "$ACCESS")"
    # No formato do Apache, o campo 9 e o codigo HTTP e o campo 1 o IP.
    echo "Erros 4xx: $(grep "$HOJE_ACCESS" "$ACCESS" | awk '$9 ~ /^4/' | wc -l)"
    echo "Erros 5xx: $(grep "$HOJE_ACCESS" "$ACCESS" | awk '$9 ~ /^5/' | wc -l)"
    echo "IPs com mais pedidos:"
    grep "$HOJE_ACCESS" "$ACCESS" | awk '{print $1}' | sort | uniq -c | sort -rn | head -5
else
    echo "Sem $ACCESS"
fi

MODSEC=0
if [ -f "$ERROR" ]; then
    MODSEC=$(grep "$HOJE_ERROR" "$ERROR" | grep -c "ModSecurity: Access denied")
fi
echo ""
echo "--- Mod_security ---"
echo "Ataques bloqueados hoje: $MODSEC"

echo ""
echo "--- SSH (logins falhados hoje) ---"
if [ -f /var/log/secure ]; then
    FALHAS=$(grep "^$HOJE_SECURE" /var/log/secure | grep "Failed password")
else
    # Se nao existir /var/log/secure, os registos estao no journal do systemd.
    FALHAS=$(journalctl -u sshd --since today --no-pager | grep "Failed password")
fi
SSH=$(echo "$FALHAS" | grep -c "Failed password")
echo "Tentativas falhadas: $SSH"
if [ "$SSH" -gt 0 ]; then
    echo "IPs de origem:"
    # Linha tipo: "Failed password for USER from IP port N ssh2" -> IP e o 4.o campo a contar do fim.
    echo "$FALHAS" | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -5
fi

BANS=0
if [ -f /var/log/fail2ban.log ]; then
    BANS=$(grep "^$HOJE_F2B" /var/log/fail2ban.log | grep -c " Ban ")
fi
echo ""
echo "--- Fail2ban ---"
echo "IPs bloqueados hoje: $BANS"
fail2ban-client status sshd 2>/dev/null | grep "Banned IP list"
} > "$RELATORIO"

# --- Alerta ---
# Falhas de seguranca = logins SSH falhados + bloqueios do Fail2ban + ataques bloqueados.
# So se alerta se o total de hoje aumentou desde a ultima vez (para nao repetir alertas).
TOTAL=$((SSH + BANS + MODSEC))
ANTERIOR=0
if [ -f "$ESTADO" ] && [ "$(cut -d' ' -f1 "$ESTADO")" = "$HOJE_F2B" ]; then
    ANTERIOR=$(cut -d' ' -f2 "$ESTADO")
fi
echo "$HOJE_F2B $TOTAL" > "$ESTADO"

if [ "$TOTAL" -gt "$ANTERIOR" ]; then
    MENSAGEM="$(date '+%F %T') ALERTA: $((TOTAL - ANTERIOR)) novas falhas de seguranca (SSH: $SSH, Fail2ban: $BANS, Mod_security: $MODSEC). Relatorio: $RELATORIO"
    echo "$MENSAGEM" >> /var/log/seguranca.log
    echo "$MENSAGEM" >> /var/log/uc00636/alertas.log
    if [ -n "$EMAIL" ] && command -v mail > /dev/null; then
        mail -s "ALERTA de seguranca - $(hostname)" "$EMAIL" < "$RELATORIO"
    fi
fi
FIM

# Passar o email definido no topo deste script para o gerador.
sed -i "s|^EMAIL=\"\"|EMAIL=\"$EMAIL\"|" "$RELATORIO_SH"
chmod 700 "$RELATORIO_SH"
echo "OK: criado $RELATORIO_SH" | tee -a "$LOG"

# PASSO 4 - Agendar a execucao de hora a hora com o cron.
# Formato: minuto hora dia mes dia-da-semana utilizador comando
echo "PASSO 4 - Agendamento no cron" | tee -a "$LOG"
dnf install -y cronie >> "$LOG" 2>&1
systemctl enable --now crond >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel iniciar o crond." | tee -a "$LOG"
    exit 1
fi

echo "0 * * * * root $RELATORIO_SH" > /etc/cron.d/uc00636-monitorizacao
chmod 644 /etc/cron.d/uc00636-monitorizacao
echo "OK: relatorio agendado de hora a hora (/etc/cron.d/uc00636-monitorizacao)." | tee -a "$LOG"

if [ -z "$EMAIL" ]; then
    echo "AVISO: sem email definido, os alertas ficam em /var/log/seguranca.log" | tee -a "$LOG"
elif ! systemctl is-active --quiet postfix || ! command -v mail > /dev/null; then
    echo "AVISO: Postfix nao configurado (corre o script 05); os alertas ficam em /var/log/seguranca.log" | tee -a "$LOG"
else
    echo "OK: alertas enviados por email para $EMAIL" | tee -a "$LOG"
fi

# PASSO 5 - Gerar ja o primeiro relatorio e mostra-lo.
echo "" | tee -a "$LOG"
echo "PASSO 5 - Primeiro relatorio" | tee -a "$LOG"
"$RELATORIO_SH"
if [ $? -ne 0 ]; then
    echo "ERRO: o gerador de relatorios falhou." | tee -a "$LOG"
    exit 1
fi

cat "/var/log/uc00636/relatorios/relatorio_$(date +%Y-%m-%d).txt" | tee -a "$LOG"

echo "" | tee -a "$LOG"
echo "Alertas registados: /var/log/seguranca.log" | tee -a "$LOG"
echo "===== Script 11 concluido: $(date) =====" | tee -a "$LOG"
