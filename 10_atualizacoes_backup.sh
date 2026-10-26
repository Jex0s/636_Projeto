#!/usr/bin/env bash
# ============================================================================
# UC00636 | Script 10 - Atualizacoes e backups (Bash / CentOS Stream 10)
# Versao 0.2 - backup/restauro testados; politica de retencao e timer seguro
#
# Uso:
#   bash 10_atualizacoes_backup.sh help                 # sem alteracoes
#   sudo bash 10_atualizacoes_backup.sh backup          # backup unico, validado
#   sudo bash 10_atualizacoes_backup.sh update          # backup + dnf update -y
#   sudo bash 10_atualizacoes_backup.sh enable-backups  # timer diario
#   sudo bash 10_atualizacoes_backup.sh enable-updates  # timer semanal (EXPLICITO)
#   sudo bash 10_atualizacoes_backup.sh status          # consulta timers/backups
#
# Importante: nenhuma atualizacao ou timer e ativado por omissao.
# O ficheiro deve ser mantido fora do repositorio ate revisao da equipa.
# ============================================================================
set -Eeuo pipefail
umask 077

readonly BACKUP_ROOT='/backups/uc00636'
readonly RETENTION_KEEP=14  # Manter os 14 backups mais recentes (diretorios datados).
readonly LOG_DIR='/var/log/uc00636'
readonly LOG_FILE="${LOG_DIR}/10_atualizacoes_backup.log"
readonly INSTALLED_SCRIPT='/usr/local/sbin/uc00636-script10'
readonly BACKUP_SERVICE='/etc/systemd/system/uc00636-backup.service'
readonly BACKUP_TIMER='/etc/systemd/system/uc00636-backup.timer'
readonly UPDATE_SERVICE='/etc/systemd/system/uc00636-update.service'
readonly UPDATE_TIMER='/etc/systemd/system/uc00636-update.timer'

STAGING_DIR=''

usage() {
  cat <<'HELP'
UC00636 - SCRIPT 10 | Atualizacoes e backups

Comandos disponiveis:
  help            Mostra estas instrucoes (nao modifica o sistema).
  backup          Cria e valida backups do website e de todas as bases MariaDB.
  update          Cria um backup e, so se for valido, executa dnf update -y.
  enable-backups  Instala e ativa um timer de backup diario (02:30 hora local).
  enable-updates  Instala e ativa um timer de atualizacoes semanais (dom. 04:00).
  status          Consulta os backups e os agendamentos existentes.

Saida dos backups: /backups/uc00636/AAAAmmdd_HHMMSS/
Log de operacoes:   /var/log/uc00636/10_atualizacoes_backup.log

Avisos:
  - Exige root para tarefas administrativas; nao inclui credenciais.
  - O agendamento pressupoe que a VM esta ligada na hora prevista ou mais tarde.
  - A exportacao com --single-transaction e consistente para tabelas InnoDB;
    outros motores e alteracoes DDL concorrentes exigem cuidados adicionais.
  - Mantem os 14 backups datados mais recentes; os mais antigos sao eliminados
    apenas depois de concluir e validar um novo backup.
  - Backups guardados no mesmo disco NAO substituem copias externas.
  - O restauro ainda nao e executado automaticamente: exige ensaio controlado.
  - Ativar as atualizacoes AUTOMATICAS apenas apos os testes de integracao.
  - Atualizacoes perdidas durante o desligamento NAO sao executadas ao arranque.
HELP
}

require_root() {
  if (( EUID != 0 )); then
    printf 'ERRO: executa com sudo para esta operacao.\n' >&2
    exit 1
  fi
}

init_dirs() {
  install -d -m 0700 -o root -g root "$BACKUP_ROOT" "$LOG_DIR"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

log() {
  local message="$1"
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$message" | tee -a "$LOG_FILE"
}

fail() {
  log "ERRO: $1" >&2
  exit 1
}

cleanup() {
  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}
trap cleanup EXIT

lock_operations() {
  command -v flock >/dev/null || fail 'Comando flock indisponivel (util-linux).'
  exec 9> /run/lock/uc00636-script10.lock
  flock -n 9 || fail 'Outra operacao do Script 10 esta em execucao.'
}

# A limpeza e feita APENAS depois de um backup novo ter sido criado com sucesso.
# Aceita unicamente nomes com o formato gerado pelo script (AAAAMMDD_HHMMSS).
# Nunca remove .tmp.* nem diretorios arbitrarios na raiz dos backups.
prune_old_backups() {
  local name index=0
  while IFS= read -r name; do
    [[ "$name" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
    (( index += 1 ))
    if (( index > RETENTION_KEEP )); then
      rm -rf -- "${BACKUP_ROOT}/${name}" || fail "Falha ao eliminar backup antigo: $name"
      log "Retencao: backup antigo removido: $name"
    fi
  done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort -r)
}

backup_data() {
  local stamp final
  for cmd in tar gzip sha256sum mariadb mariadb-dump; do
    command -v "$cmd" >/dev/null || fail "Dependencia ausente: $cmd"
  done
  [[ -d /var/www/html ]] || fail 'Diretorio /var/www/html inexistente.'
  mariadb --protocol=socket --batch --skip-column-names -e 'SELECT 1' >/dev/null \
    || fail 'MariaDB inacessivel por socket. Nao alterar passwords automaticamente.'

  stamp="$(date '+%Y%m%d_%H%M%S')"
  final="${BACKUP_ROOT}/${stamp}"
  [[ ! -e "$final" ]] || fail "Ja existe um backup com este identificador: $final"
  STAGING_DIR="$(mktemp -d "${BACKUP_ROOT}/.tmp.XXXXXXXX")" \
    || fail 'Nao foi possivel criar diretorio temporario de backup.'

  log 'A iniciar copia de seguranca do website e bases de dados.'
  tar -C /var/www -czf "${STAGING_DIR}/website.tar.gz" html \
    || fail 'Falha ao arquivar /var/www/html.'

  # O dump e comprimido em fluxo, sem criar SQL desprotegido no disco.
  mariadb-dump --protocol=socket --all-databases --single-transaction \
    --routines --events --triggers --hex-blob \
    | gzip -c > "${STAGING_DIR}/mariadb.sql.gz" \
    || fail 'Falha na exportacao/compressao MariaDB.'

  tar -tzf "${STAGING_DIR}/website.tar.gz" >/dev/null \
    || fail 'Backup website invalido.'
  gzip -t "${STAGING_DIR}/mariadb.sql.gz" \
    || fail 'Backup MariaDB invalido.'

  (
    cd "$STAGING_DIR"
    sha256sum website.tar.gz mariadb.sql.gz > SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  ) || fail 'Verificacao de integridade SHA256 falhou.'

  cat > "${STAGING_DIR}/README_RECUPERACAO.txt" <<'README'
UC00636 - Copia de seguranca, acesso reservado ao administrador.
website.tar.gz  -> estrutura relativa html/ (raiz /var/www/).
mariadb.sql.gz  -> dump SQL das bases de dados MariaDB.
SHA256SUMS      -> hash de cada arquivo.

Verificar:
  cd /backups/uc00636/AAAAmmdd_HHMMSS && sha256sum -c SHA256SUMS

Nao restaurar diretamente numa VM de producao sem snapshot e plano de rollback.
Exemplo de leitura nao destrutiva: gzip -dc mariadb.sql.gz | head -n 15
Para recuperar, ensaiar numa VM isolada e validar dados/permissions/SELinux.
README

  chmod 0600 "${STAGING_DIR}"/*
  mv -- "$STAGING_DIR" "$final" || fail 'Falha ao consolidar o backup.'
  STAGING_DIR=''
  log "Backup concluido e verificado: $final"
  du -sh "$final"
  prune_old_backups
}

run_updates() {
  command -v dnf >/dev/null || fail 'Gestor de pacotes dnf indisponivel.'
  log 'A fazer backup antes da atualizacao (nao prossegue se falhar).'
  backup_data
  log 'A iniciar atualizacao de pacotes: dnf update -y.'
  if dnf update -y >> "$LOG_FILE" 2>&1; then
    log 'Atualizacao DNF concluida. Verificar servicos e necessidade de reboot.'
  else
    fail 'DNF falhou; consultar o log e o estado dos pacotes.'
  fi
}

install_executable() {
  local source_path
  source_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  [[ -f "$source_path" ]] || fail 'Nao foi possivel localizar o script original.'
  install -m 0750 -o root -g root "$source_path" "$INSTALLED_SCRIPT"
}

schedule_backups() {
  command -v systemctl >/dev/null || fail 'systemctl indisponivel.'
  install_executable
  cat > "$BACKUP_SERVICE" <<EOF_SERVICE
[Unit]
Description=UC00636 - Backup website e MariaDB
After=network.target mariadb.service

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=${INSTALLED_SCRIPT} backup
EOF_SERVICE
  cat > "$BACKUP_TIMER" <<'EOF_TIMER'
[Unit]
Description=UC00636 - Backup diario

[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
Unit=uc00636-backup.service

[Install]
WantedBy=timers.target
EOF_TIMER
  chmod 0644 "$BACKUP_SERVICE" "$BACKUP_TIMER"
  systemctl daemon-reload
  systemctl enable --now uc00636-backup.timer
  log 'Timer de backups diarios instalado (02:30, hora local da VM); script instalado atualizado.'
}

schedule_updates() {
  command -v systemctl >/dev/null || fail 'systemctl indisponivel.'
  install_executable
  cat > "$UPDATE_SERVICE" <<EOF_SERVICE
[Unit]
Description=UC00636 - Backup e atualizacoes DNF
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
User=root
UMask=0077
ExecStart=${INSTALLED_SCRIPT} update
EOF_SERVICE
  cat > "$UPDATE_TIMER" <<'EOF_TIMER'
[Unit]
Description=UC00636 - Atualizacoes semanais (ATIVACAO EXPLICITA)

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=false
Unit=uc00636-update.service

[Install]
WantedBy=timers.target
EOF_TIMER
  chmod 0644 "$UPDATE_SERVICE" "$UPDATE_TIMER"
  systemctl daemon-reload
  systemctl enable --now uc00636-update.timer
  log 'Timer de updates ativado explicitamente: domingo, 04:00 hora local; sem catch-up apos desligamentos.'
}

status() {
  printf '\nBackups existentes em %s:\n' "$BACKUP_ROOT"
  if [[ -d "$BACKUP_ROOT" ]]; then
    if (( EUID == 0 )); then
      find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.tmp.*' -printf '%f\n' | sort
    else
      printf '(acesso reservado ao root: usar sudo para consultar os backups)\n'
    fi
  else
    printf '(diretorio ainda nao criado)\n'
  fi
  printf '\nAgendamentos (se disponiveis):\n'
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl list-timers --all 'uc00636-*.timer' --no-pager || true
  else
    printf '(systemd nao esta em execucao neste ambiente)\n'
  fi
}

main() {
  local mode="${1:-help}"
  case "$mode" in
    help|-h|--help) usage ;;
    status) status ;;
    backup|update|enable-backups|enable-updates)
      require_root
      init_dirs
      lock_operations
      case "$mode" in
        backup) backup_data ;;
        update) run_updates ;;
        enable-backups) schedule_backups ;;
        enable-updates) schedule_updates ;;
      esac
      ;;
    *) printf 'Opcao desconhecida: %s\n' "$mode" >&2; usage; exit 2 ;;
  esac
}

main "$@"
