#!/bin/bash

# ================================================================
# UC00636 - Projeto de Automatização em CentOS Stream 10
# SCRIPT 03 - Rede e Firewall (fase inicial segura)
#
# Objetivos:
#   - Registar a configuração de rede existente, sem mudar o IP.
#   - Permitir SSH, HTTP e HTTPS na zona public do Firewalld.
#   - Retirar a autorização de acesso ao Cockpit pelo firewall.
#   - Validar as regras aplicadas e guardar evidências num log.
#
# Atribuição de IP fixo e acesso por IP público: FASE PENDENTE.
# Esta VM usa a rede NAT do VMware; não alterar a ligação ens160
# sem confirmar o plano de endereçamento e a reserva DHCP.
#
# Executar: sudo ./03_rede_firewall.sh
# ================================================================

# 1. Confirmar permissões administrativas.
if [ "$EUID" -ne 0 ]; then
    echo "ERRO: executa este script com sudo."
    exit 1
fi

# 2. Criar o registo da execução.
mkdir -p /var/log/uc00636
LOG="/var/log/uc00636/03_rede_firewall.log"
touch "$LOG"
chmod 600 "$LOG"
echo "=== Script 03 iniciado: $(date) ===" | tee -a "$LOG"

# 3. Confirmar que os comandos e serviços necessários existem.
if ! command -v nmcli > /dev/null 2>&1; then
    echo "ERRO: NetworkManager (nmcli) não está disponível." | tee -a "$LOG"
    exit 1
fi

if ! firewall-cmd --state > /dev/null 2>&1; then
    echo "ERRO: o Firewalld não está em execução." | tee -a "$LOG"
    exit 1
fi

# 4. Garantir que estamos a trabalhar na interface e zona certas.
# Uma zona diferente poderia deixar uma configuração incorreta.
if ! nmcli -t -f DEVICE,STATE device status | grep -q '^ens160:connected$'; then
    echo "ERRO: a interface ens160 não está ligada." | tee -a "$LOG"
    exit 1
fi

ZONA=$(firewall-cmd --get-zone-of-interface=ens160)
if [ "$ZONA" != "public" ]; then
    echo "ERRO: ens160 está na zona '$ZONA' e não na zona 'public'." | tee -a "$LOG"
    echo "As regras não foram alteradas." | tee -a "$LOG"
    exit 1
fi

# 5. Guardar a configuração inicial como evidência.
# Não fazemos nmcli connection modify nem reiniciamos a rede.
echo "PASSO 5 - Configuração atual da rede" | tee -a "$LOG"
nmcli -f IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show ens160 | tee -a "$LOG"
echo "Serviços permitidos anteriormente:" | tee -a "$LOG"
firewall-cmd --permanent --zone=public --list-services | tee -a "$LOG"

# 6. Permitir SSH, HTTP e HTTPS nas regras permanentes.
# Mantemos SSH para não perder o acesso remoto de administração.
echo "PASSO 6 - Configuração dos serviços permitidos" | tee -a "$LOG"
for SERVICO in ssh http https; do
    if firewall-cmd --permanent --zone=public --query-service="$SERVICO" > /dev/null; then
        echo "OK: $SERVICO já estava autorizado." | tee -a "$LOG"
    else
        if ! firewall-cmd --permanent --zone=public --add-service="$SERVICO"; then
            echo "ERRO: não foi possível autorizar $SERVICO." | tee -a "$LOG"
            exit 1
        fi
        echo "OK: $SERVICO autorizado." | tee -a "$LOG"
    fi
done

# 7. Remover a autorização de acesso ao Cockpit (porta 9090).
# Não desinstalamos o serviço; restringimos apenas a exposição.
if firewall-cmd --permanent --zone=public --query-service=cockpit > /dev/null; then
    if ! firewall-cmd --permanent --zone=public --remove-service=cockpit; then
        echo "ERRO: não foi possível retirar a autorização do Cockpit." | tee -a "$LOG"
        exit 1
    fi
    echo "OK: acesso ao Cockpit retirado do firewall." | tee -a "$LOG"
else
    echo "OK: acesso ao Cockpit já estava desautorizado." | tee -a "$LOG"
fi

# Nota: a regra dhcpv6-client é mantida por agora.
# Será avaliada com os requisitos de IPv6, sem bloquear DHCPv6.

# 8. Aplicar as regras permanentes, mantendo o estado das ligações.
if ! firewall-cmd --reload; then
    echo "ERRO: não foi possível recarregar o Firewalld." | tee -a "$LOG"
    exit 1
fi

# 9. Confirmar as permissões efetivas após o reload.
for SERVICO in ssh http https; do
    if ! firewall-cmd --zone=public --query-service="$SERVICO" > /dev/null; then
        echo "ERRO: $SERVICO não ficou permitido." | tee -a "$LOG"
        exit 1
    fi
done

if firewall-cmd --zone=public --query-service=cockpit > /dev/null; then
    echo "ERRO: o Cockpit continua autorizado." | tee -a "$LOG"
    exit 1
fi

echo "OK: SSH, HTTP e HTTPS permitidos; Cockpit desautorizado." | tee -a "$LOG"
echo "Serviços permitidos após a configuração:" | tee -a "$LOG"
firewall-cmd --zone=public --list-services | tee -a "$LOG"

echo "Nota: IP privado do VMware NAT preservado; acesso público e IP fixo pendentes." | tee -a "$LOG"
echo "=== Script 03 (firewall) concluído: $(date) ===" | tee -a "$LOG"
