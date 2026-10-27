# UC00636 — Dashboard dinâmico (opcional)

Painel web de leitura, inspirado em Zabbix, **sem instalar Zabbix** e sem alterar os Scripts 01–11.

## Instalação em qualquer VM CentOS Stream 10

1. Executar o Script 01 (Apache instalado e ativo).
2. (Uma vez) executar `bash dashboard/integrar_menu.sh` para acrescentar a opção **13**; depois escolher **13** em `sudo bash menu.sh` ou usar `sudo bash dashboard/install.sh` diretamente.
3. Abrir `http://IP_DA_VM/dashboard.html` na rede local.
4. Para acesso externo, executar Script 07 `https-preparar`, `cert-producao IP_PUBLICO`, `https-aplicar` e configurar no router/host/VMware as portas necessárias. Cada colega usa o **seu IP público**, não o do ensaio.

## Como funciona

- `dashboard/install.sh`: instala os ficheiros e um serviço/temporizador systemd **opcionais**.
- `dashboard/collect.sh`: recolhe indicadores agregados do servidor e grava `/var/www/html/dashboard-status.json` a cada minuto.
- `dashboard/dashboard.html`: lê o JSON a cada 20 segundos e apresenta os valores; se não houver atualização, indica que os dados estão indisponíveis.
- A instalação não substitui `index.html`, não modifica a configuração Apache e não abre novas portas. A integração no menu acrescenta somente a opção 13; as opções 1–12 mantêm-se intactas.

## Dados publicados e segurança

O JSON publicado inclui apenas percentagens CPU/RAM/disco, uptime, estado de serviços, modo SELinux, existência/validade local do certificado TLS, contagens agregadas HTTP do dia e data do último backup. **Não publica** utilizadores, IPs internos, pedidos individuais, logs completos, passwords, tokens nem chave privada. HTTPS validado localmente **não** significa que esteja acessível a partir da Internet.

A página não permite iniciar/parar serviços e não oferece terminal remoto. A porta 80 deve ser disponibilizada apenas quando necessária para validar/renovar o certificado HTTPS. Para exposição externa, usar HTTPS e limitar a abertura do router às portas estritamente necessárias; para maior privacidade, publicar numa VPN ou proteger o painel com autenticação.

## Comandos úteis

```bash
sudo systemctl status uc00636-dashboard.timer --no-pager
sudo systemctl start uc00636-dashboard.service
cat /var/www/html/dashboard-status.json
sudo systemctl disable --now uc00636-dashboard.timer
```

A recolha é feita com privilégios locais porque alguns indicadores (como o estado de backups) exigem leitura protegida. O Apache apenas serve um ficheiro JSON **pré-gerado**, sem permissões para executar os comandos de recolha.

### Importante

Os resultados históricos do ensaio continuam identificados separadamente na página. Os estados em tempo real vêm exclusivamente da VM em que o instalador foi executado.
