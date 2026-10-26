#!/bin/bash

# ==============================================================
# UC00636 - Projeto de Automatizacao em CentOS Stream 10
# SCRIPT 01 - Instalacao dos servicos principais
# Objetivo: instalar Apache, PHP e MariaDB e verificar se funcionam.
# Este script deve ser executado com: sudo ./01_instalar_servicos.sh
# ==============================================================

# PASSO 1 - Confirmar que o utilizador tem permissoes de administrador.
# EUID e o numero que identifica o utilizador: o root tem o numero 0.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: deves executar este script com sudo."
    exit 1
fi

# PASSO 2 - Criar a pasta para guardar os registos deste projeto.
# A opcao -p evita erros se a pasta ja existir.
mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/01_instalar_servicos.log"

# tee mostra a mensagem no terminal e tambem a guarda no ficheiro LOG.
echo "===== Inicio do Script 01: $(date) =====" | tee -a "$LOG"

# PASSO 3 - Instalar os pacotes necessarios.
# httpd: servidor web Apache.
# php e php-fpm: interpretacao de paginas PHP no Apache.
# php-mysqlnd: ligacao entre PHP e MariaDB.
# mariadb-server: servidor de base de dados.
# curl: permite testar pedidos HTTP no terminal.
echo "PASSO 3 - Instalacao de Apache, PHP e MariaDB" | tee -a "$LOG"
dnf install -y httpd php php-fpm php-mysqlnd mariadb-server curl

# $? guarda o resultado do ultimo comando: 0 significa sucesso.
if [ $? -ne 0 ]; then
    echo "ERRO: a instalacao dos pacotes falhou." | tee -a "$LOG"
    exit 1
fi

echo "OK: pacotes instalados." | tee -a "$LOG"

# PASSO 4 - Criar a pagina inicial do website.
# So criamos o ficheiro se ainda nao existir uma pagina inicial.
echo "PASSO 4 - Preparacao do website" | tee -a "$LOG"
mkdir -p /var/www/html
if [ ! -f /var/www/html/index.html ] && [ ! -f /var/www/html/index.php ]; then
    echo '<h1>UC00636 - Servidor operacional</h1>' > /var/www/html/index.html
fi

# PASSO 5 - Criar a pagina info.php, pedida no enunciado.
# phpinfo() apresenta a versao e as configuracoes do PHP.
if [ ! -f /var/www/html/info.php ]; then
    echo '<?php phpinfo(); ?>' > /var/www/html/info.php
fi

# PASSO 6 - Impedir o acesso remoto ao info.php por seguranca.
# "Require local" permite consultar esta pagina apenas no servidor.
# Os tres echo escrevem a configuracao num ficheiro do Apache.
echo '<Files "info.php">' > /etc/httpd/conf.d/uc00636-info-local.conf
echo '    Require local' >> /etc/httpd/conf.d/uc00636-info-local.conf
echo '</Files>' >> /etc/httpd/conf.d/uc00636-info-local.conf

# PASSO 7 - Corrigir os contextos de seguranca SELinux do website.
# Nao desativamos o SELinux, que ja esta no modo Enforcing.
restorecon -R /var/www/html
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel aplicar os contextos SELinux." | tee -a "$LOG"
    exit 1
fi

# PASSO 8 - Confirmar a sintaxe do Apache antes de iniciar o servico.
echo "PASSO 8 - Verificacao da configuracao Apache" | tee -a "$LOG"
httpd -t
if [ $? -ne 0 ]; then
    echo "ERRO: a configuracao do Apache tem problemas." | tee -a "$LOG"
    exit 1
fi

# PASSO 9 - Iniciar os servicos e ativa-los no arranque do CentOS.
# O ciclo for executa os mesmos comandos para os tres servicos.
echo "PASSO 9 - Ativacao dos servicos" | tee -a "$LOG"
for servico in php-fpm mariadb httpd; do
    systemctl enable --now "$servico"
    if [ $? -ne 0 ]; then
        echo "ERRO: nao foi possivel iniciar $servico." | tee -a "$LOG"
        exit 1
    fi
    echo "OK: $servico iniciado e ativado." | tee -a "$LOG"
done

# Recarregar o Apache para aplicar a protecao do ficheiro info.php,
# mesmo quando o script e executado mais do que uma vez.
systemctl reload httpd
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel recarregar o Apache." | tee -a "$LOG"
    exit 1
fi

# PASSO 10 - Confirmar que os tres servicos estao ativos.
for servico in httpd php-fpm mariadb; do
    systemctl is-active "$servico"
    if [ $? -ne 0 ]; then
        echo "ERRO: $servico nao esta ativo." | tee -a "$LOG"
        exit 1
    fi
done

# PASSO 11 - Testar a pagina inicial atraves do proprio servidor.
# O endereco 127.0.0.1 representa o servidor local (localhost).
# -f deteta erros HTTP; -sS mostra apenas os erros; -o descarta o HTML.
echo "PASSO 11 - Teste HTTP local" | tee -a "$LOG"
curl -fsS -o /dev/null http://127.0.0.1/
if [ $? -ne 0 ]; then
    echo "ERRO: o website local nao respondeu corretamente." | tee -a "$LOG"
    exit 1
fi
echo "OK: website acessivel em http://127.0.0.1/" | tee -a "$LOG"

# PASSO 12 - Confirmar que o Apache interpreta PHP.
# Criamos um ficheiro temporario para guardar a resposta de info.php
# Isto evita erros causados pela leitura incompleta da resposta.

echo "PASSO 12 - Teste de PHP" | tee -a "$LOG"

FICHEIRO_TESTE=$(mktemp)

# Verificar se foi possivel criar o ficheiro temporario.
if [ $? -ne 0 ]; then
    echo "ERRO: nao foi possivel criar o ficheiro temporario." | tee -a "$LOG"
    exit 1
fi

# Guardar a resposta da pagina PHP no ficheiro temporário
curl -fsS -o "$FICHEIRO_TESTE" http://127.0.0.1/info.php

if [ $? -ne 0 ]; then
    echo "ERRO: a pagina PHP nao respondeu." | tee -a "$LOG"
    rm -f "$FICHEIRO_TESTE"
    exit 1
fi

# Procurar a expressao PHP Version na resposta.
grep -q "PHP Version" "$FICHEIRO_TESTE"

if [ $? -ne 0 ]; then
    echo "ERRO: o PHP não foi interpretado corretamente." | tee -a "$LOG"
    rm -f "$FICHEIRO_TESTE"
    exit 1
fi

# Apagar o ficheiro temporario porque ja nao e necessario
rm -f "$FICHEIRO_TESTE"



echo "OK: PHP interpretado corretamente pelo Apache." | tee -a "$LOG"

# PASSO 13 - Testar o acesso pelo IP publico (so informativo).
# Nao termina com erro: o acesso externo depende do router e da porta 80,
# que so e aberta no script 03.
echo "PASSO 13 - Teste pelo IP publico" | tee -a "$LOG"
IP_PUBLICO=$(curl -4 -s --max-time 5 ifconfig.me)
if [ -z "$IP_PUBLICO" ]; then
    echo "AVISO: nao foi possivel obter o IP publico." | tee -a "$LOG"
else
    echo "IP publico detetado: $IP_PUBLICO" | tee -a "$LOG"
    curl -s --max-time 5 -o /dev/null "http://$IP_PUBLICO/"
    if [ $? -eq 0 ]; then
        echo "OK: website acessivel pelo IP publico." | tee -a "$LOG"
    else
        echo "AVISO: sem acesso pelo IP publico (falta port forwarding no router ou rede em CGNAT)." | tee -a "$LOG"
    fi
fi

echo "===== Script 01 concluido: $(date) =====" | tee -a "$LOG"
