# 636_Projeto
UC00636 - Projeto de Scripting 


----------

<h1>30/09/2026</h1> 
~ Configuração inicial, estruturação dos scripts e configuração do .gitignore ~

----------

<h1>21/10/2026</h1>
~ Criação do menu principal (menu.sh) com while e case ~

~ Definição dos nomes dos scripts (01 a 11) usados pelo menu ~

----------

<h1>23/10/2026</h1>

~ Testados na VM os scripts 01 (instalação) e 02 (MariaDB seguro) ~

~ Script 02: a password do root tem de ser definida (responder Y em "Change the root password?") ~

~ Criado e testado o script 05 (Fail2ban): bloqueio após 3 tentativas falhadas no SSH, desbloqueio com unbanip ~

~ Criado e testado o script 06 (Mod_security + OWASP CRS 4.22): pedido normal 200, ataques SQLi e XSS bloqueados com 403 ~

----------

<h1>24/10/2026</h1>

~ Criado o script 09 (Ajustes PHP): date.timezone, upload_max_filesize, post_max_size e memory_limit no php.ini, com cópia de segurança e reposição automática se falhar ~

~ Criado o script 03 (Rede e Firewall): diagnóstico de rede, firewalld só com SSH, HTTP e HTTPS (Cockpit removido), IP fixo por nmcli e guia de publicação no router ~

~ Script 03: acesso HTTP externo validado no ambiente de demonstração ~

~ Criado o script 04 (SELinux): confirma modo Enforcing e auditd, relatório com sealert e log centralizado em /var/log/seguranca.log ~

~ Criado o script 10 (Atualizações e Backup): backup validado do website e das bases de dados em /backups/uc00636, dnf update com backup prévio e timers do systemd ~

~ Script 10 integrado no menu, com submenu (backup, backup e atualização, estado) ~

----------

<h1>25/10/2026</h1>

~ Concluído o script 07 (Tuning Apache): KeepAlive, Timeouts, MaxRequestWorkers conforme a RAM, compressão gzip e HTTPS com Let's Encrypt (Certbot) e renovação preparada ~

~ Scripts 07, 09 e 10 juntados ao main ~

----------

<h1>26/10/2026</h1>

~ Criado e testado o script 08 (Tuning MariaDB): buffer pool 60% da RAM, log 256M, 100 ligações, query cache 32M validada com Qcache_hits ~

~ Criado e testado o script 11 (Monitorização): NTP com chrony, relatório horário dos logs por cron, alertas em /var/log/seguranca.log ~

~ Menu corrigido (opções 1-9 e 11 e backup na opção 12) e confirmação SIM antes de correr todos os scripts ~

~ Correções: teste pelo IP público no script 01, instalação automática do sealert no script 04, shebang na linha 1 do script 09 ~

~ Removidos os branches já juntados ao main ~

----------
