#!/usr/bin/env bash
# UC00636 — Script 03, revisão 0.3 — Rede e Firewalld
# CentOS Stream 10 / NetworkManager + firewalld
# Execução: sudo ./03_rede_firewall.sh [base|diagnostico|firewall|ip-publico|ip-fixo|publicacao|teste|ajuda]
# A operação ip-fixo NUNCA altera a rede sem --aplicar e confirmação explícita.
# A configuração do router/VMware/Windows é específica do ambiente e não é alterada por este script.
set -Eeuo pipefail

LOG_DIR='/var/log/uc00636'
LOG_FILE="$LOG_DIR/03_rede_firewall.log"

ajuda() {
  cat <<'EOF'
UC00636 — Script 03 (v0.3) — Rede e Firewall
  ajuda                                 Mostra as opções; não modifica o sistema
  diagnostico                           Mostra interface, IP, gateway, DNS e firewalld
  ip-publico                            Consulta o IPv4 público de saída (não prova que seja fixo)
  firewall                              Autoriza ssh/http/https e retira cockpit da zona ativa
  teste                                 Confirma resposta HTTP do Apache local
  publicacao                            Mostra as etapas de publicação externa (sem alterar NAT)
  ip-fixo IP/CIDR GATEWAY DNS           Simula alteração para IP estático (não aplica)
  ip-fixo IP/CIDR GATEWAY DNS --aplicar  Configura e ativa IP fixo; EXIGE consola e confirmação
  base                                  Executa diagnostico + firewall + teste

Sem opção, usa 'base'. Não configurar o IP público na interface privada VMware.
As regras NOS/VMware/Windows e o IP público fixo requerem configuração externa.
EOF
}

log_init() {
  if (( EUID == 0 )); then
    install -d -m 0700 "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 0600 "$LOG_FILE"
  fi
}
msg() {
  printf '%s\n' "$*"
  if (( EUID == 0 )); then printf '%s | %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG_FILE"; fi
}
require_root() {
  (( EUID == 0 )) || { printf '%s\n' 'ERRO: esta opção exige sudo.' >&2; exit 1; }
}
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { msg "ERRO: programa '$1' indisponível."; exit 1; }
}
iface() {
  local dev
  dev="$(ip -4 route show default 2>/dev/null | awk '$1=="default" {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
  [[ -n "$dev" ]] || { msg 'ERRO: não foi encontrada rota IPv4 por omissão.'; return 1; }
  printf '%s\n' "$dev"
}
profile() {
  local con
  con="$(nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null | head -n 1)"
  [[ -n "$con" && "$con" != '--' ]] || { msg "ERRO: não foi encontrado perfil NetworkManager ativo para $1."; return 1; }
  printf '%s\n' "$con"
}
zone_for_iface() {
  local z
  z="$(firewall-cmd --get-zone-of-interface="$1" 2>/dev/null || true)"
  [[ -n "$z" && "$z" != 'no zone' ]] || { msg "ERRO: interface $1 sem zona firewalld identificada."; return 1; }
  printf '%s\n' "$z"
}

diagnostico() {
  require_cmd ip; require_cmd nmcli; require_cmd firewall-cmd
  local dev con
  dev="$(iface)"; con="$(profile "$dev")"
  msg "=== DIAGNOSTICO: interface=$dev | perfil=$con ==="
  nmcli -f IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show "$dev"
  nmcli -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns connection show "$con"
  # Verificamos primeiro os privilegios, para nao confundir falta de acesso
  # com um servico parado.
  if (( EUID != 0 )); then
    msg 'NOTA: para consultar o Firewalld, executa: sudo ./03_rede_firewall.sh diagnostico'
  elif ! systemctl is-active --quiet firewalld; then
    msg 'ATENCAO: servico firewalld inativo.'
  elif ! firewall-cmd --state >/dev/null 2>&1; then
    msg 'ERRO: firewalld ativo, mas firewall-cmd nao respondeu corretamente.'
  else
    local zona; zona="$(zone_for_iface "$dev")"
    msg "Firewalld ativo; zona de $dev: $zona"
    firewall-cmd --zone="$zona" --list-services
  fi
}

ip_publico() {
  require_cmd curl
  local public_ip
  public_ip="$(curl --ipv4 --silent --show-error --fail --connect-timeout 5 --max-time 10 https://ifconfig.me/ip)" || {
    msg 'AVISO: consulta do IPv4 público indisponível; verificar DNS e Internet.'; return 1;
  }
  [[ "$public_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { msg 'ERRO: resposta inesperada ao consultar IP público.'; return 1; }
  msg "IPv4 público de SAÍDA: $public_ip"
  msg 'NOTA: a consulta NÃO comprova que o IP é fixo nem que aceita ligações de entrada.'
}

firewall_regras() {
  require_root; require_cmd firewall-cmd; require_cmd ip
  firewall-cmd --state >/dev/null 2>&1 || { msg 'ERRO: firewalld inativo; configurar/iniciar antes desta etapa.'; exit 1; }
  local dev zona service alterado=0 carimbo backup
  dev="$(iface)"; zona="$(zone_for_iface "$dev")"
  carimbo="$(date +%Y%m%d_%H%M%S)"
  backup="$LOG_DIR/03_firewall_antes_${carimbo}.txt"
  firewall-cmd --permanent --zone="$zona" --list-all > "$backup"
  chmod 0600 "$backup"
  msg "Zona em uso: $zona | cópia da configuração anterior: $backup"
  for service in ssh http https; do
    if firewall-cmd --permanent --zone="$zona" --query-service="$service" >/dev/null 2>&1; then
      msg "OK: $service já permitido."
    else
      firewall-cmd --permanent --zone="$zona" --add-service="$service" >/dev/null
      msg "OK: $service autorizado."; alterado=1
    fi
  done
  if firewall-cmd --permanent --zone="$zona" --query-service=cockpit >/dev/null 2>&1; then
    firewall-cmd --permanent --zone="$zona" --remove-service=cockpit >/dev/null
    msg 'OK: autorização de cockpit retirada da zona.'; alterado=1
  else
    msg 'OK: cockpit já não estava autorizado.'
  fi
  if (( alterado )); then firewall-cmd --reload >/dev/null; fi
  for service in ssh http https; do
    firewall-cmd --zone="$zona" --query-service="$service" >/dev/null || { msg "ERRO: $service não permitido após validação."; exit 1; }
  done
  if firewall-cmd --zone="$zona" --query-service=cockpit >/dev/null; then
    msg 'ERRO: cockpit ainda permitido.'; exit 1
  fi
  msg 'OK: SSH, HTTP e HTTPS ativos; Cockpit não autorizado.'
}

teste_http() {
  require_cmd curl
  local code
  code="$(curl --noproxy '*' -sS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1/)" || {
    msg 'ERRO: sem resposta HTTP local; confirmar Script 01/Apache.'; return 1;
  }
  case "$code" in
    200|301|302) msg "OK: Apache respondeu HTTP $code em 127.0.0.1." ;;
    *) msg "AVISO: Apache respondeu HTTP $code; confirmar o website."; return 1 ;;
  esac
}

ip_fixo() {
  require_cmd ip; require_cmd nmcli
  [[ $# -ge 3 ]] || { ajuda; exit 2; }
  local cidr="$1" gateway="$2" dns="$3" modo="${4:-}" dev con
  [[ "$cidr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/([0-9]|[12][0-9]|3[0-2])$ ]] || { msg 'ERRO: IP/CIDR incorreto.'; exit 2; }
  [[ "$gateway" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { msg 'ERRO: gateway incorreto.'; exit 2; }
  [[ "$dns" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { msg 'ERRO: DNS incorreto.'; exit 2; }
  dev="$(iface)"; con="$(profile "$dev")"
  msg "Plano IP fixo | interface: $dev | perfil: $con | IP: $cidr | gateway: $gateway | DNS: $dns"
  [[ -n "$modo" && "$modo" != '--aplicar' ]] && { msg 'ERRO: opção desconhecida.'; exit 2; }
  if [[ "$modo" != '--aplicar' ]]; then msg 'SIMULACAO: nada alterado. Para aplicar, acrescentar --aplicar.'; return; fi
  require_root
  [[ -z "${SSH_CONNECTION:-}" && -t 0 ]] || { msg 'ERRO: aplicar apenas na consola local interativa da VM.'; exit 1; }
  printf 'ATENCAO: a ligação poderá cair. Escreve APLICAR para continuar: '
  local reply; read -r reply
  [[ "$reply" == APLICAR ]] || { msg 'Cancelado: nenhuma alteração realizada.'; return; }
  local backup="$LOG_DIR/03_networkmanager_antes_$(date +%Y%m%d_%H%M%S).txt"
  nmcli -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns connection show "$con" > "$backup"
  chmod 0600 "$backup"
  nmcli connection modify "$con" ipv4.method manual ipv4.addresses "$cidr" ipv4.gateway "$gateway" ipv4.dns "$dns"
  nmcli connection up "$con"
  msg "OK: perfil '$con' ativado com IP fixo. Estado anterior em $backup"
}

publicacao() {
  cat <<'EOF'
UC00636 — Publicação pela Internet (GUIA, SEM ALTERAR A REDE)
1. Confirmar com ISP IP público realmente FIXO (curl mostra só IP de saída).
2. Confirmar IP do Windows/Lenovo e configuração VMware NAT.
3. CentOS Apache responde na LAN; remover páginas de diagnóstico expostas.
4. Rever HTTPS/TLS, ModSecurity/Fail2ban e acesso público controlado.
5. Configuração específica do ambiente (não aplicável automaticamente por Bash no CentOS):
   Router NOS porta externa TCP 80/443 -> IP LAN Windows -> VMware NAT -> IP VM:80/443.
   Windows Firewall necessita regra de entrada adequada e restrita.
6. NÃO utilizar DMZ. NÃO expor MariaDB TCP 3306 nem SSH TCP 22 indiscriminadamente.
7. Após a defesa, retirar regras temporárias do router/Windows/VMware.
NOTA: HTTP externo validado no ambiente de demonstracao em 24/10/2026 via 4G+.
HTTPS e IP publico fixo continuam pendentes.
EOF
}

main() {
  local cmd="${1:-base}"
  case "$cmd" in
    ajuda|-h|--help|help) ajuda ;;
    diagnostico) log_init; diagnostico ;;
    ip-publico) log_init; ip_publico ;;
    firewall) require_root; log_init; firewall_regras ;;
    teste) log_init; teste_http ;;
    publicacao) publicacao ;;
    ip-fixo) shift; log_init; ip_fixo "$@" ;;
    base) require_root; log_init; msg '=== Script 03 iniciado ==='; diagnostico; firewall_regras; teste_http; msg '=== Script 03 concluído ===' ;;
    *) printf 'ERRO: opção desconhecida: %s\n' "$cmd" >&2; ajuda; exit 2 ;;
  esac
}
main "$@"
