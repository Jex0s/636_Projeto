#!/bin/bash

# ==============================================================
# UC00636 - Projeto de Automatizacao em CentOS Stream 10
# SCRIPT 06 - Mod_security
# Objetivo: instalar a firewall de aplicacao web (WAF) no Apache,
# carregar as regras OWASP CRS e testar ataques simulados (SQLi e XSS).
# Este script deve ser executado com: sudo ./06_modsecurity.sh
# ==============================================================

# PASSO 1 - Confirmar que o utilizador tem permissoes de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: deves executar este script com sudo."
    exit 1
fi

mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/06_modsecurity.log"

echo "===== Inicio do Script 06: $(date) =====" | tee -a "$LOG"

# PASSO 2 - Confirmar que o Apache ja esta instalado (script 01).
systemctl is-active --quiet httpd
if [ $? -ne 0 ]; then
    echo "ERRO: o Apache nao esta ativo. Corre primeiro o script 01." | tee -a "$LOG"
    exit 1
fi

# PASSO 3 - Instalar o Mod_security e as regras OWASP CRS.
# mod_security: esta no repositorio EPEL.
# mod_security_crs: conjunto de regras OWASP (Core Rule Set), esta no AppStream.
echo "PASSO 3 - Instalacao do Mod_security e das regras OWASP CRS" | tee -a "$LOG"
dnf install -y epel-release >> "$LOG" 2>&1
dnf install -y mod_security mod_security_crs >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel instalar o Mod_security. Ver $LOG" | tee -a "$LOG"
    exit 1
fi
echo "OK: Mod_security e regras OWASP CRS instalados." | tee -a "$LOG"

# PASSO 4 - Garantir que o motor de regras esta em modo de bloqueio.
# SecRuleEngine On            -> deteta e bloqueia
# SecRuleEngine DetectionOnly -> so regista, nao bloqueia
# O sed substitui a linha SecRuleEngine, seja qual for o valor que tinha.
CONF="/etc/httpd/conf.d/mod_security.conf"
if [ ! -f "$CONF" ]; then
    echo "ERRO: nao foi encontrado o ficheiro $CONF" | tee -a "$LOG"
    exit 1
fi

sed -i 's/^\s*SecRuleEngine .*/    SecRuleEngine On/' "$CONF"
grep -q "SecRuleEngine On" "$CONF"
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel ativar o SecRuleEngine." | tee -a "$LOG"
    exit 1
fi
echo "OK: SecRuleEngine em modo On (bloqueio)." | tee -a "$LOG"

# PASSO 5 - Confirmar a sintaxe do Apache e reiniciar para carregar o modulo.
echo "PASSO 5 - Verificacao e reinicio do Apache" | tee -a "$LOG"
httpd -t >> "$LOG" 2>&1
if [ $? -ne 0 ]; then
    echo "ERRO: a configuracao do Apache tem erros. Ver $LOG" | tee -a "$LOG"
    exit 1
fi

systemctl restart httpd
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel reiniciar o Apache." | tee -a "$LOG"
    exit 1
fi

# Confirmar que o modulo foi mesmo carregado pelo Apache.
httpd -M 2>/dev/null | grep -q security2_module
if [ $? -ne 0 ]; then
    echo "ERRO: o modulo security2 nao foi carregado pelo Apache." | tee -a "$LOG"
    exit 1
fi
echo "OK: modulo security2 carregado." | tee -a "$LOG"

# PASSO 6 - Testes.
# -w "%{http_code}" mostra so o codigo HTTP da resposta.
# -G com --data-urlencode junta o parametro ao endereco (?id=...)
# e converte os caracteres especiais (espacos, aspas, < >).
echo "" | tee -a "$LOG"
echo "PASSO 6 - Testes de protecao" | tee -a "$LOG"

# Teste 1: um pedido normal tem de continuar a funcionar (200).
CODIGO=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/)
echo "Pedido normal:  HTTP $CODIGO (esperado 200)" | tee -a "$LOG"
if [ "$CODIGO" != "200" ]; then
    echo "ERRO: o Mod_security esta a bloquear pedidos normais." | tee -a "$LOG"
    exit 1
fi

# Teste 2: SQL Injection.
CODIGO=$(curl -s -o /dev/null -w "%{http_code}" -G --data-urlencode "id=1' OR '1'='1" http://127.0.0.1/)
echo "Ataque SQLi:    HTTP $CODIGO (esperado 403)" | tee -a "$LOG"
if [ "$CODIGO" != "403" ]; then
    echo "ERRO: o ataque SQLi nao foi bloqueado." | tee -a "$LOG"
    exit 1
fi

# Teste 3: Cross-Site Scripting (XSS).
CODIGO=$(curl -s -o /dev/null -w "%{http_code}" -G --data-urlencode "q=<script>alert(1)</script>" http://127.0.0.1/)
echo "Ataque XSS:     HTTP $CODIGO (esperado 403)" | tee -a "$LOG"
if [ "$CODIGO" != "403" ]; then
    echo "ERRO: o ataque XSS nao foi bloqueado." | tee -a "$LOG"
    exit 1
fi

echo "OK: ataques SQLi e XSS bloqueados." | tee -a "$LOG"

# PASSO 7 - Mostrar o registo dos bloqueios no log do Apache.
echo "" | tee -a "$LOG"
echo "Ultimos bloqueios registados pelo Mod_security:" | tee -a "$LOG"
grep "ModSecurity: Access denied" /var/log/httpd/error_log | tail -n 2 | tee -a "$LOG"

echo "===== Script 06 concluido: $(date) =====" | tee -a "$LOG"
