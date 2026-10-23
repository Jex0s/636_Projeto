#!/bin/bash
# =====================================================================
# UC00636 - SCRIPT 07 - Tuning do Apache (etapa 1: desempenho)
# CentOS Stream 10 - Apache HTTP Server 2.4 / MPM event
#
# O que faz:
#   1. Verifica os pre-requisitos e o MPM ativo.
#   2. Cria uma copia da configuracao de tuning anterior, se existir.
#   3. Ativa KeepAlive, compressao gzip para estaticos e limites conservadores.
#   4. Testa a sintaxe antes de recarregar o Apache.
#   5. Restaura a configuracao anterior em caso de falha.
#
# IMPORTANTE: SSL/TLS e Let's Encrypt fazem parte do Script 07, mas
# ficam para a etapa 2, depois de preparar o acesso publico autorizado.
#
# Executar: sudo ./07_tuning_apache.sh
# =====================================================================

# PASSO 1 - Confirmar privilegios de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: executa este script com sudo."
    exit 1
fi

# PASSO 2 - Preparar log e caminhos utilizados.
mkdir -p /var/log/uc00636 || exit 1
LOG="/var/log/uc00636/07_tuning_apache.log"
touch "$LOG" || exit 1
chmod 600 "$LOG"
CONF="/etc/httpd/conf.d/uc00636-tuning.conf"
BACKUP_DIR="/root/uc00636_backup_apache"
mkdir -p "$BACKUP_DIR" || exit 1
BACKUP=""
TENTATIVA_NOVA=0

echo "=== Script 07 iniciado: $(date) ===" | tee -a "$LOG"

# PASSO 3 - Validar os servicos e modulos antes de alterar ficheiros.
if ! systemctl is-active --quiet httpd; then
    echo "ERRO: o Apache nao esta ativo." | tee -a "$LOG"
    exit 1
fi

if ! httpd -M 2>/dev/null | grep -q 'mpm_event_module'; then
    echo "ERRO: este tuning foi preparado para o MPM event." | tee -a "$LOG"
    exit 1
fi

if ! httpd -M 2>/dev/null | grep -q 'deflate_module'; then
    echo "ERRO: mod_deflate nao esta carregado." | tee -a "$LOG"
    exit 1
fi

# Ler a memoria total da VM para justificar a escolha dos limites.
MEM_MB=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
if [ -z "$MEM_MB" ]; then
    echo "ERRO: nao foi possivel identificar a memoria." | tee -a "$LOG"
    exit 1
fi

# O MPM event utiliza, por omissao, 25 threads por processo.
# 50 ou 100 workers sao limites conservadores para o laboratorio.
# Numa instalacao de producao, ajustar apos medir a carga real.
if [ "$MEM_MB" -ge 4096 ]; then
    WORKERS=100
else
    WORKERS=50
fi

echo "PASSO 3 - Memoria: ${MEM_MB} MB; MaxRequestWorkers: $WORKERS" | tee -a "$LOG"

# PASSO 4 - Fazer backup apenas se ja existir configuracao propria.
if [ -f "$CONF" ]; then
    BACKUP="$BACKUP_DIR/uc00636-tuning-$(date +%Y%m%d-%H%M%S).conf"
    if ! cp -p "$CONF" "$BACKUP"; then
        echo "ERRO: nao foi possivel guardar a configuracao anterior." | tee -a "$LOG"
        exit 1
    fi
    echo "OK: copia anterior em $BACKUP" | tee -a "$LOG"
else
    TENTATIVA_NOVA=1
fi

# PASSO 5 - Criar um ficheiro temporario no diretorio do Apache.
# So o renomeamos para .conf quando o conteudo estiver escrito.
TEMP=$(mktemp /etc/httpd/conf.d/.uc00636-tuning.XXXXXX) || exit 1
cat > "$TEMP" <<EOCONF
# UC00636 - Parametros de desempenho do Apache
# Gerado pelo Script 07; nao editar ao mesmo tempo que o script.
# Confirmado: Apache 2.4 e MPM event.

# KeepAlive reutiliza a mesma ligacao para varios pedidos HTTP.
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 3

# Tempo maximo para determinadas operacoes do servidor (segundos).
Timeout 30

# MaxRequestWorkers e o equivalente atual ao antigo MaxClients.
# Com ThreadsPerChild=25, 100 workers representam 4 processos.
<IfModule mpm_event_module>
    ThreadsPerChild 25
    MaxRequestWorkers $WORKERS
</IfModule>

# Compressao gzip atraves do mod_deflate.
# A regra por MIME e mantida para tipos de conteudo textuais.
# O FilesMatch aplica explicitamente o filtro aos ficheiros estaticos:
# esta foi a correcao confirmada no teste HTTP do projeto UC00636.
# Evitar aplicar SetOutputFilter a paginas PHP com dados sensiveis.
<IfModule deflate_module>
    AddOutputFilterByType DEFLATE text/html text/plain text/css text/javascript application/javascript application/json application/xml text/xml
    <FilesMatch "\.(html|txt|css|js)$">
        SetOutputFilter DEFLATE
    </FilesMatch>
</IfModule>
EOCONF

if [ $? -ne 0 ]; then
    rm -f "$TEMP"
    echo "ERRO: nao foi possivel escrever o ficheiro temporario." | tee -a "$LOG"
    exit 1
fi
chmod 644 "$TEMP"
if ! mv -f "$TEMP" "$CONF"; then
    rm -f "$TEMP"
    echo "ERRO: nao foi possivel instalar a configuracao." | tee -a "$LOG"
    exit 1
fi

# Funcao de recuperacao: apenas o nosso ficheiro e restaurado.
# Nao modificar ficheiros de ModSecurity ou de outros scripts.
restaurar_configuracao() {
    if [ "$TENTATIVA_NOVA" -eq 1 ]; then
        rm -f "$CONF"
    else
        cp -p "$BACKUP" "$CONF"
    fi
    httpd -t >> "$LOG" 2>&1
    systemctl reload httpd >> "$LOG" 2>&1
}

# PASSO 6 - Validar antes de recarregar o servico.
echo "PASSO 6 - Verificar sintaxe do Apache" | tee -a "$LOG"
if ! httpd -t >> "$LOG" 2>&1; then
    echo "ERRO: configuracao invalida. A restaurar o ficheiro anterior." | tee -a "$LOG"
    restaurar_configuracao
    exit 1
fi

# PASSO 7 - Aplicar as alteracoes sem reiniciar a VM.
echo "PASSO 7 - Recarregar Apache" | tee -a "$LOG"
if ! systemctl reload httpd >> "$LOG" 2>&1; then
    echo "ERRO: falhou o reload. A restaurar o ficheiro anterior." | tee -a "$LOG"
    restaurar_configuracao
    exit 1
fi

if ! systemctl is-active --quiet httpd; then
    echo "ERRO: Apache deixou de estar ativo. A restaurar." | tee -a "$LOG"
    restaurar_configuracao
    exit 1
fi

echo "OK: configuracao de desempenho aplicada em $CONF" | tee -a "$LOG"
echo "NOTA: SSL/TLS - Let's Encrypt continua pendente da etapa 2." | tee -a "$LOG"
echo "=== Script 07 (desempenho) concluido: $(date) ===" | tee -a "$LOG"
