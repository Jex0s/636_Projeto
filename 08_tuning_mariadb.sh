#!/bin/bash

# ==============================================================
# UC00636 - Projeto de Automatizacao em CentOS Stream 10
# SCRIPT 08 - Tuning do MariaDB
# Objetivo: aplicar as otimizacoes pedidas no enunciado,
# reiniciar o MariaDB e validar os valores e o desempenho.
# Este script deve ser executado com: sudo ./08_tuning_mariadb.sh
# ==============================================================

# PASSO 1 - Confirmar que o utilizador tem permissoes de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: deves executar este script com sudo."
    exit 1
fi

mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/08_tuning_mariadb.log"

echo "===== Inicio do Script 08: $(date) =====" | tee -a "$LOG"

# PASSO 2 - Confirmar que o MariaDB esta ativo (script 01).
systemctl is-active --quiet mariadb
if [ $? -ne 0 ]; then
    echo "ERRO: o MariaDB nao esta ativo. Corre primeiro o script 01." | tee -a "$LOG"
    exit 1
fi

# PASSO 3 - Calcular 60% da RAM para o innodb_buffer_pool_size.
# /proc/meminfo mostra a memoria total em kB; dividir por 1024 da MB.
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$((RAM_KB / 1024))
BUFFER_MB=$((RAM_MB * 60 / 100))

echo "PASSO 3 - Calculo do buffer pool" | tee -a "$LOG"
echo "RAM total: ${RAM_MB}M -> innodb_buffer_pool_size (60%): ${BUFFER_MB}M" | tee -a "$LOG"

# PASSO 4 - Escrever a configuracao.
# O /etc/my.cnf inclui todos os ficheiros de /etc/my.cnf.d/ (linha !includedir).
# Usamos um ficheiro proprio, como no script 02, para nao misturar com a
# configuracao original e para ser facil de remover.
# O 99 no nome garante que e lido em ultimo lugar e tem prioridade.
CONFIG="/etc/my.cnf.d/99-uc00636-tuning.cnf"

if [ -f "$CONFIG" ]; then
    cp "$CONFIG" "$CONFIG.bak"
fi

echo "PASSO 4 - Escrita da configuracao em $CONFIG" | tee -a "$LOG"
cat > "$CONFIG" <<EOF
[mysqld]
# 60% da RAM do servidor (calculado pelo script 08)
innodb_buffer_pool_size = ${BUFFER_MB}M
innodb_log_file_size    = 256M
max_connections         = 100

# A cache de queries vem desligada no MariaDB.
# query_cache_type = 1 liga-a, para o query_cache_size ter efeito.
query_cache_type = 1
query_cache_size = 32M
EOF
chmod 644 "$CONFIG"
restorecon "$CONFIG"

# PASSO 5 - Reiniciar o MariaDB para aplicar a configuracao.
# Se nao arrancar, repoe a configuracao anterior e volta a arrancar.
echo "PASSO 5 - Reinicio do MariaDB" | tee -a "$LOG"
systemctl restart mariadb
if [ $? -ne 0 ]; then
    echo "ERRO: o MariaDB nao arrancou com a configuracao nova." | tee -a "$LOG"
    if [ -f "$CONFIG.bak" ]; then
        cp "$CONFIG.bak" "$CONFIG"
    else
        rm -f "$CONFIG"
    fi
    systemctl restart mariadb
    echo "A configuracao anterior foi reposta. Ver: journalctl -u mariadb" | tee -a "$LOG"
    exit 1
fi
echo "OK: MariaDB reiniciado." | tee -a "$LOG"

# PASSO 6 - Validar os valores aplicados.
# O MariaDB pode arredondar o buffer pool para cima (multiplos de 128M),
# por isso o valor real tem de ser igual ou maior que o pedido.
echo "" | tee -a "$LOG"
echo "PASSO 6 - Validacao dos valores" | tee -a "$LOG"

ERROS=0

BUFFER_REAL=$(mariadb -N -B -e "SELECT @@innodb_buffer_pool_size DIV 1048576;")
if [ "$BUFFER_REAL" -ge "$BUFFER_MB" ]; then
    echo "OK: innodb_buffer_pool_size = ${BUFFER_REAL}M" | tee -a "$LOG"
else
    echo "ERRO: innodb_buffer_pool_size = ${BUFFER_REAL}M (pedido ${BUFFER_MB}M)" | tee -a "$LOG"
    ERROS=1
fi

# Para os outros valores, a lista tem o formato variavel=valor esperado (em MB ou numero).
for par in innodb_log_file_size=256 max_connections=100 query_cache_size=32; do
    variavel=$(echo "$par" | cut -d= -f1)
    esperado=$(echo "$par" | cut -d= -f2)

    if [ "$variavel" = "max_connections" ]; then
        real=$(mariadb -N -B -e "SELECT @@$variavel;")
        unidade=""
    else
        real=$(mariadb -N -B -e "SELECT @@$variavel DIV 1048576;")
        unidade="M"
    fi

    if [ "$real" = "$esperado" ]; then
        echo "OK: $variavel = $real$unidade" | tee -a "$LOG"
    else
        echo "ERRO: $variavel = $real$unidade (esperado $esperado$unidade)" | tee -a "$LOG"
        ERROS=1
    fi
done

if [ $ERROS -ne 0 ]; then
    echo "ERRO: nem todos os valores foram aplicados." | tee -a "$LOG"
    exit 1
fi

# PASSO 7 - Validar o desempenho.
# Cria-se uma base de dados de teste e repete-se a mesma consulta 5 vezes:
# a partir da segunda, o resultado deve vir da cache (Qcache_hits aumenta).
# (As tabelas do sistema, como mysql.*, nao entram na cache, por isso usa-se uma tabela propria.)
echo "" | tee -a "$LOG"
echo "PASSO 7 - Teste de desempenho" | tee -a "$LOG"

mariadb -e "CREATE DATABASE IF NOT EXISTS uc00636_teste;"
mariadb -e "CREATE TABLE IF NOT EXISTS uc00636_teste.numeros (n INT);"
mariadb -e "INSERT INTO uc00636_teste.numeros VALUES (1),(2),(3),(4),(5);"

HITS_ANTES=$(mariadb -N -B -e "SHOW GLOBAL STATUS LIKE 'Qcache_hits';" | awk '{print $2}')

for i in 1 2 3 4 5; do
    mariadb -N -B -e "SELECT SUM(n) FROM uc00636_teste.numeros;" > /dev/null
done

HITS_DEPOIS=$(mariadb -N -B -e "SHOW GLOBAL STATUS LIKE 'Qcache_hits';" | awk '{print $2}')

# Apagar a base de dados de teste.
mariadb -e "DROP DATABASE uc00636_teste;"

echo "Qcache_hits antes: $HITS_ANTES / depois: $HITS_DEPOIS" | tee -a "$LOG"
if [ "$HITS_DEPOIS" -gt "$HITS_ANTES" ]; then
    echo "OK: a cache de queries esta a responder a consultas repetidas." | tee -a "$LOG"
else
    echo "AVISO: a cache de queries nao registou acertos." | tee -a "$LOG"
fi

# Estado geral do servidor: tempo ativo, ligacoes, consultas por segundo.
mariadb-admin status | tee -a "$LOG"

echo "===== Script 08 concluido: $(date) =====" | tee -a "$LOG"
