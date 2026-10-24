
#!/usr/bin/env bash
set -Eeuo pipefail

# Configuração PHP para CentOS 10
TIMEZONE="Europe/Lisbon"
UPLOAD_MAX="20M"
POST_MAX="25M"
MEMORY_LIMIT="256M"

BACKUP_DIR="/var/backups/php-config-$(date +%Y%m%d-%H%M%S)"
PHP_INI=""
PHP_FPM_SERVICE="php-fpm"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

erro() {
    log "ERRO: $*"
    exit 1
}

# 1. Verificar root
if [[ "${EUID}" -ne 0 ]]; then
    erro "Executa este script como root (sudo ou utilizador root)."
fi

# 2. Verificar PHP instalado
if ! command -v php >/dev/null 2>&1; then
    erro "PHP não está instalado ou não está no PATH."
fi

PHP_BIN="$(command -v php)"
PHP_VERSION="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)" ||
    erro "Não foi possível determinar a versão do PHP."
log "PHP instalado: ${PHP_VERSION}"
log "Executável: ${PHP_BIN}"

# 3. Detetar o php.ini carregado
PHP_INI="$(php -r 'echo php_ini_loaded_file();')"
[[ -n "$PHP_INI" && -f "$PHP_INI" ]] ||
    erro "Não foi possível localizar o php.ini carregado."

log "php.ini: ${PHP_INI}"

# 4. Verificar serviço PHP-FPM
if ! command -v systemctl >/dev/null 2>&1; then
    erro "systemctl não está disponível."
fi

if ! systemctl cat "$PHP_FPM_SERVICE" >/dev/null 2>&1; then
    erro "O serviço ${PHP_FPM_SERVICE} não existe."
fi

# 5. Criar backup antes de alterar
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

cp -a "$PHP_INI" "$BACKUP_DIR/php.ini"

log "Backup criado em: ${BACKUP_DIR}"

# Restaurar o php.ini se ocorrer uma falha antes da validação.
ALTERED=0
VALIDATED=0

rollback() {
    local rc=$?
    if [[ "$ALTERED" -eq 1 && "$VALIDATED" -eq 0 ]]; then
        log "Falha detetada. A restaurar o php.ini original."
        cp -a "$BACKUP_DIR/php.ini" "$PHP_INI" ||
            log "ATENÇÃO: falhou a restauração automática."
    fi
    exit "$rc"
}
trap rollback EXIT

# 6. Configurar diretivas sem duplicar entradas
set_ini_value() {
    local key="$1"
    local value="$2"
    local file="$3"

    if grep -Eq "^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E \
            "s|^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" \
            "$file"
    else
        printf '\n%s = %s\n' "$key" "$value" >> "$file"
    fi
}

ALTERED=1

set_ini_value "date.timezone" "$TIMEZONE" "$PHP_INI"
set_ini_value "upload_max_filesize" "$UPLOAD_MAX" "$PHP_INI"
set_ini_value "post_max_size" "$POST_MAX" "$PHP_INI"
set_ini_value "memory_limit" "$MEMORY_LIMIT" "$PHP_INI"

# 7. Validar sintaxe e valores efetivamente carregados
if ! "$PHP_BIN" -v >/dev/null 2>&1; then
    erro "Configuração PHP inválida. O ficheiro original será restaurado."
fi

EXPECTED="$TIMEZONE|$UPLOAD_MAX|$POST_MAX|$MEMORY_LIMIT"
ACTUAL="$("$PHP_BIN" -r '
printf("%s|%s|%s|%s",
    ini_get("date.timezone"),
    ini_get("upload_max_filesize"),
    ini_get("post_max_size"),
    ini_get("memory_limit")
);' 2>/dev/null)" || erro "Falha ao consultar as diretivas PHP."

if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    erro "Os valores carregados não correspondem aos pretendidos.
Esperado: $EXPECTED
Obtido:   $ACTUAL
Verifica ficheiros adicionais de configuração PHP."
fi

# A partir daqui, não restaurar automaticamente uma configuração válida
# apenas porque o serviço falha ao reiniciar.
VALIDATED=1

log "Configuração PHP validada:"
"$PHP_BIN" -r '
foreach (["date.timezone", "upload_max_filesize",
          "post_max_size", "memory_limit"] as $key) {
    printf("  %-22s %s\n", $key, ini_get($key));
}'

# 8. Validar a configuração do PHP-FPM, se suportado
FPM_BIN="$(command -v php-fpm || true)"

if [[ -n "$FPM_BIN" ]]; then
    if ! "$FPM_BIN" -t; then
        erro "O teste de configuração do PHP-FPM falhou. Serviço não reiniciado."
    fi
else
    log "Aviso: binário php-fpm não encontrado no PATH; teste FPM ignorado."
fi

# 9. Reiniciar apenas depois de todas as validações
if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
    systemctl restart "$PHP_FPM_SERVICE" ||
        erro "A configuração é válida, mas o reinício do PHP-FPM falhou."
    log "PHP-FPM reiniciado com sucesso."
else
    log "PHP-FPM não estava ativo; não foi iniciado automaticamente."
fi

log "Concluído. Backup disponível em: ${BACKUP_DIR}"
