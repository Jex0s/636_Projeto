#!/bin/bash
# MENU PRINCIPAL

if [ "$EUID" -ne 0 ]; then
	echo "Tens de correr o menu como root: sudo $0"
	exit 1
fi

# PASTA ONDE ESTÁ O MENU (OS OUTROS SCRIPTS ESTÃO NA MESMA PASTA)
pasta=$(dirname "$0")

opcao=""

while [ "$opcao" != "0" ]; do
	clear
	echo "========================================"
	echo "   Servidor Web CentOS 10 - Projeto"
	echo "========================================"
	echo " 1 - Instalar Apache, PHP e MariaDB"
	echo " 2 - Configuração segura do MariaDB"
	echo " 3 - Rede e firewall"
	echo " 4 - SELinux"
	echo " 5 - Fail2ban"
	echo " 6 - Mod_security"
	echo " 7 - Tuning do Apache"
	echo " 8 - Tuning do MariaDB"
	echo " 9 - Ajustes do PHP"
	echo "10 - Atualizações e backup"
	echo "11 - Monitorização"
	echo "12 - Correr todos (1 a 11)"
	echo " 0 - Sair"
	echo "========================================"
	read -p "Escolhe uma opção: " opcao

	case $opcao in
		1) 	script="01_instalar_servicos.sh" ;;
		2) 	script="02_mariadb_seguro.sh" ;;
		3) 	script="03_rede_firewall.sh" ;;
		4) 	script="04_selinux.sh" ;;
		5) 	script="05_fail2ban.sh" ;;
		6) 	script="06_modsecurity.sh" ;;
		7) 	script="07_tuning_apache.sh" ;;
		8) 	script="08_tuning_mariadb.sh" ;;
		9) 	script="09_php.sh" ;;
		10) 	script="10_backup.sh" ;;
		11) 	script="11_monitorizacao.sh" ;;
		12) 	script="todos" ;;
		0) 	echo "A sair..."
			exit 0 ;;
		*)	echo "Opção inválida."
			script="" ;;
	esac

# CORRE TODOS OS SCRIPTS POR ORDEM, OU O SCRIPT ESCOLHIDO
# SE A OPÇÃO FOR INVÁLIDA, $script FICA VAZIO E NÃO CORRE NADA

	if [ "$script" = "todos" ]; then	# corre todos por ordem
		for s in "$pasta"/[0-9][0-9]_*.sh; do
			echo ""
			echo ">>> A correr $s"
			bash "$s"
			if [ $? -ne 0 ]; then
				echo "O script $s falhou. Os restantes não foram corridos."
				break
			fi
		done
	elif [ -n "$script" ]; then		# verifica se $script tem alguma coisa
		if [ -f "$pasta/$script" ]; then
			bash "$pasta/$script"
		else
			echo "O script $script ainda não existe." # para evitar erros durante a elaboração
		fi
	fi


	echo ""
	read -p "Carrega Enter para voltar ao menu..."
done
