#!/bin/bash
# =====================================================================
# UC00636 - SCRIPT 04 - SELinux e politicas de seguranca
# CentOS Stream 10 | Projeto de automatizacao
#
# Objetivo:
#  1. Confirmar que o SELinux esta ativo em modo Enforcing.
#  2. Confirmar que o servico auditd esta ativo.
#  3. Analisar o registo de auditoria com a ferramenta sealert.
#  4. Guardar o resumo em /var/log/seguranca.log.
#
# Seguranca: este script NAO desativa o SELinux, NAO altera politicas
# e NAO cria bloqueios artificiais para produzir eventos de auditoria.
# =====================================================================

LOG="/var/log/seguranca.log"
AUDIT_LOG="/var/log/audit/audit.log"
PASTA_RELATORIOS="/var/log/uc00636"
RELATORIO="$PASTA_RELATORIOS/04_selinux_sealert.txt"

# Criar ficheiros novos apenas com permissao para o administrador.
umask 077

# PASSO 1 - Confirmar privilegios de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: execute este script com sudo."
    exit 1
fi

# Preparar o diretorio de relatorios e o log centralizado.
mkdir -p "$PASTA_RELATORIOS"
if [ "$?" -ne 0 ]; then
    echo "ERRO: nao foi possivel criar $PASTA_RELATORIOS."
    exit 1
fi

touch "$LOG"
if [ "$?" -ne 0 ]; then
    echo "ERRO: nao foi possivel escrever em $LOG."
    exit 1
fi

printf '\n=== Script 04 iniciado: %s ===\n' "$(date)" | tee -a "$LOG"

# PASSO 2 - Confirmar o estado real do SELinux.
echo "PASSO 2 - Verificar SELinux" | tee -a "$LOG"
MODO=$(getenforce)
if [ "$?" -ne 0 ]; then
    echo "ERRO: nao foi possivel consultar o SELinux." | tee -a "$LOG"
    exit 1
fi

echo "Modo SELinux: $MODO" | tee -a "$LOG"
if [ "$MODO" != "Enforcing" ]; then
    echo "ERRO: SELinux nao esta em modo Enforcing." | tee -a "$LOG"
    echo "Acao necessaria: analisar a configuracao antes de alterar politicas." | tee -a "$LOG"
    exit 1
fi

echo "OK: SELinux ativo em modo Enforcing." | tee -a "$LOG"

# PASSO 3 - Confirmar o servico responsavel pelos registos de auditoria.
echo "PASSO 3 - Verificar auditd" | tee -a "$LOG"
if ! systemctl is-active --quiet auditd; then
    echo "ERRO: o servico auditd nao esta ativo." | tee -a "$LOG"
    exit 1
fi
echo "OK: auditd ativo." | tee -a "$LOG"

# PASSO 4 - Confirmar as ferramentas e a disponibilidade do registo.
echo "PASSO 4 - Verificar ficheiro de auditoria e ferramenta sealert" | tee -a "$LOG"

# Se o sealert nao existir, instala-se o pacote que o fornece.
if ! command -v sealert >/dev/null 2>&1; then
    echo "AVISO: sealert nao instalado; a instalar setroubleshoot-server." | tee -a "$LOG"
    dnf install -y setroubleshoot-server >> "$PASTA_RELATORIOS/04_dnf.log" 2>&1
    if ! command -v sealert >/dev/null 2>&1; then
        echo "ERRO: nao foi possivel instalar o sealert. Ver $PASTA_RELATORIOS/04_dnf.log" | tee -a "$LOG"
        exit 1
    fi
fi

if [ ! -r "$AUDIT_LOG" ]; then
    echo "ERRO: nao foi possivel ler $AUDIT_LOG." | tee -a "$LOG"
    exit 1
fi

echo "OK: sealert e registo de auditoria disponiveis." | tee -a "$LOG"

# PASSO 5 - Contar registos AVC presentes no audit.log.
# AVC significa Access Vector Cache; inclui decisoes SELinux registadas.
# A contagem e informativa e NAO representa, por si so, o numero de incidentes.
TOTAL_AVC=$(grep -c 'type=AVC' "$AUDIT_LOG")
echo "Registos com type=AVC no audit.log: $TOTAL_AVC" | tee -a "$LOG"

# PASSO 6 - Criar o relatorio com sealert.
# timeout limita o tempo de analise para evitar uma espera indefinida.
echo "PASSO 6 - Gerar relatorio sealert" | tee -a "$LOG"
timeout 90s sealert -a "$AUDIT_LOG" > "$RELATORIO" 2>&1
CODIGO=$?

if [ "$CODIGO" -ne 0 ]; then
    echo "ERRO: sealert nao concluiu a analise (codigo $CODIGO)." | tee -a "$LOG"
    echo "Consultar o diagnostico em: $RELATORIO" | tee -a "$LOG"
    exit 1
fi

# Se a ferramenta nao produzir texto, registar apenas esse facto.
if [ ! -s "$RELATORIO" ]; then
    echo "O comando sealert terminou sem produzir texto nesta execucao." > "$RELATORIO"
fi

echo "OK: relatorio guardado em $RELATORIO" | tee -a "$LOG"

# PASSO 7 - Registo final para a documentacao e defesa oral.
echo "OK: sem alteracoes as politicas SELinux." | tee -a "$LOG"
echo "=== Script 04 concluido: $(date) ===" | tee -a "$LOG"
exit 0
