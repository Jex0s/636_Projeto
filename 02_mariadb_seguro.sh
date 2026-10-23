#!/bin/bash

# ==============================================================
# UC00636 - Automatização em CentOS Stream 10
# Script 02 - Configuração segura do MariaDB
# Executar com: sudo ./02_mariadb_seguro.sh
# A password nunca é escrita no script nem no ficheiro de log.
# ==============================================================

# 1. Verificar as permissões de administrador.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: executa o script com sudo."
    exit 1
fi

# 2. Preparar o registo de execução.
mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/02_mariadb_seguro.log"
touch "$LOG"
chmod 600 "$LOG"
echo "=== Script 02 iniciado: $(date) ===" | tee -a "$LOG"

# 3. Confirmar que o MariaDB está ativo e permite administração local.
if ! systemctl is-active --quiet mariadb; then
    echo "ERRO: o serviço MariaDB não está ativo." | tee -a "$LOG"
    exit 1
fi
if ! mariadb -e "SELECT 1;" > /dev/null; then
    echo "ERRO: não foi possível administrar o MariaDB localmente." | tee -a "$LOG"
    exit 1
fi
echo "OK: MariaDB ativo e acesso local funcional." | tee -a "$LOG"

# 4. Verificar se o processo de segurança já foi realizado.
# Os números abaixo são contagens ou indicadores, nunca passwords.
ANONIMOS=$(mariadb -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='';")
ROOT_REMOTO=$(mariadb -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');")
BASE_TESTE=$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='test';")
SOCKET_OK=$(mariadb -N -B -e "SELECT IF(JSON_SEARCH(Priv,'one','unix_socket') IS NULL,0,1) FROM mysql.global_priv WHERE User='root' AND Host='localhost';")
PASSWORD_OK=$(mariadb -N -B -e "SELECT IF(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(Priv, '\$.authentication_string')), 'invalid') NOT IN ('','invalid'),1,0) FROM mysql.global_priv WHERE User='root' AND Host='localhost';")

# Verificar se todas as consultas anteriores devolveram valores válidos.
if [ -z "$ANONIMOS" ] || [ -z "$ROOT_REMOTO" ] || [ -z "$BASE_TESTE" ] || [ -z "$SOCKET_OK" ] || [ -z "$PASSWORD_OK" ]; then
    echo "ERRO: não foi possível consultar o estado de segurança." | tee -a "$LOG"
    exit 1
fi

if [ "$ANONIMOS" = "0" ] && [ "$ROOT_REMOTO" = "0" ] && [ "$BASE_TESTE" = "0" ] && [ "$SOCKET_OK" = "1" ] && [ "$PASSWORD_OK" = "1" ]; then
    echo "OK: contas e autenticação já estão protegidas; não é necessário repetir a configuração." | tee -a "$LOG"
else
    # Numa instalação nova, a ferramenta oficial pede confirmação e password.
    # Mantém unix_socket e responde SIM à remoção de acessos inseguros.
    echo "A configuração das contas ainda não está completa." | tee -a "$LOG"
    echo "A ferramenta oficial irá pedir respostas e, se necessário, uma password."
    if command -v mariadb-secure-installation > /dev/null 2>&1; then
        mariadb-secure-installation
    else
        mysql_secure_installation
    fi
    if [ $? -ne 0 ]; then
        echo "ERRO: a configuração interativa não terminou corretamente." | tee -a "$LOG"
        exit 1
    fi
fi

# 5. Preparar uma configuração separada para a escuta TCP local.
CONFIG="/etc/my.cnf.d/99-uc00636-seguranca.cnf"
NOVA_CONFIG=0

if [ -f "$CONFIG" ]; then
    # Não substituir configurações que possam ter sido alteradas por terceiros.
    if ! grep -Eq '^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*127\.0\.0\.1[[:space:]]*$' "$CONFIG"; then
        echo "ERRO: $CONFIG já existe, mas contém uma configuração diferente." | tee -a "$LOG"
        echo "Verifica esse ficheiro manualmente; não foi substituído." | tee -a "$LOG"
        exit 1
    fi
    echo "OK: o ficheiro de configuração local já existe." | tee -a "$LOG"
else
    cat > "$CONFIG" <<'FIM_CONFIG'
[mysqld]
# Aceitar ligações TCP apenas no próprio servidor.
bind-address = 127.0.0.1
FIM_CONFIG
    chmod 644 "$CONFIG"
    if command -v restorecon > /dev/null 2>&1; then
        restorecon "$CONFIG"
    fi
    NOVA_CONFIG=1
    echo "OK: configuração de rede criada." | tee -a "$LOG"
fi

# 6. Reiniciar apenas se a configuração ainda não estiver aplicada.
BIND=$(mariadb -N -B -e "SELECT @@GLOBAL.bind_address;")
if [ "$BIND" != "127.0.0.1" ]; then
    echo "A aplicar bind-address = 127.0.0.1..." | tee -a "$LOG"
    if ! systemctl restart mariadb; then
        echo "ERRO: o MariaDB não arrancou com a configuração nova." | tee -a "$LOG"
        if [ "$NOVA_CONFIG" -eq 1 ]; then
            rm -f "$CONFIG"
            systemctl restart mariadb
        fi
        exit 1
    fi
else
    echo "OK: porta 3306 já limitada ao servidor local; reinício dispensado." | tee -a "$LOG"
fi

# 7. Confirmar a segurança e registar apenas resultados, sem segredos.
if ! mariadb -e "FLUSH PRIVILEGES;" > /dev/null; then
    echo "ERRO: não foi possível recarregar privilégios." | tee -a "$LOG"
    exit 1
fi

ANONIMOS=$(mariadb -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='';")
ROOT_REMOTO=$(mariadb -N -B -e "SELECT COUNT(*) FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1');")
BASE_TESTE=$(mariadb -N -B -e "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='test';")
SOCKET_OK=$(mariadb -N -B -e "SELECT IF(JSON_SEARCH(Priv,'one','unix_socket') IS NULL,0,1) FROM mysql.global_priv WHERE User='root' AND Host='localhost';")
PASSWORD_OK=$(mariadb -N -B -e "SELECT IF(COALESCE(JSON_UNQUOTE(JSON_EXTRACT(Priv, '\$.authentication_string')), 'invalid') NOT IN ('','invalid'),1,0) FROM mysql.global_priv WHERE User='root' AND Host='localhost';")
BIND=$(mariadb -N -B -e "SELECT @@GLOBAL.bind_address;")

if [ "$ANONIMOS" != "0" ] || [ "$ROOT_REMOTO" != "0" ] || [ "$BASE_TESTE" != "0" ] || [ "$SOCKET_OK" != "1" ] || [ "$PASSWORD_OK" != "1" ] || [ "$BIND" != "127.0.0.1" ]; then
    echo "ERRO: nem todos os requisitos de segurança foram confirmados." | tee -a "$LOG"
    exit 1
fi

echo "OK: sem utilizadores anónimos ou root remoto; sem base de teste." | tee -a "$LOG"
echo "OK: password definida e autenticação unix_socket preservada." | tee -a "$LOG"
echo "OK: bind-address = 127.0.0.1." | tee -a "$LOG"
echo "=== Script 02 concluído: $(date) ===" | tee -a "$LOG"
