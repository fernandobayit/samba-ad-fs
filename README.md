# samba-ad-fs

Container Docker do Samba 4 Active Directory Domain Controller com cliente NetBird embutido (opcional). Desenhado para ser o DNS primário do domínio acessível via malha NetBird (mesh VPN self-hosted), sem expor portas na internet.

## Requisitos

- Docker + Docker Compose
- NetBird self-hosted com Management Server (para acesso via mesh)

## Quick Start

1. Confira a seção `environment:` do docker-compose.yml para conhecer as variáveis disponíveis.
2. Defina as variáveis reais no shell antes de subir o container. Por exemplo:

```bash
export SAMBA_ADMIN_PASSWORD='sua-senha-forte'
export NETBIRD_SETUP_KEY='sua-setup-key'
export NETBIRD_MANAGEMENT_URL='https://seu-management:33073'
```

3. Suba o container:

```bash
docker compose up -d
```

4. Acompanhe a inicialização:

```bash
docker compose logs -f samba-dc
```

Atenção: o primeiro boot provisiona o domínio do zero, o que leva alguns minutos. Aguarde o log indicar que o provisionamento terminou antes de usar o DC.

## Variáveis de ambiente

| Nome | Obrigatória | Default | Descrição |
|------|-------------|---------|-----------|
| SAMBA_REALM | não | SWAT.LOCAL | Realm Kerberos do domínio. |
| SAMBA_DOMAIN | não | SWAT | Nome NetBIOS/curto do domínio. |
| SAMBA_ADMIN_PASSWORD | sim | — | Senha do Administrator. Sem ela o container recusa subir; o placeholder ChangeThisPassword também é recusado. |
| SAMBA_DNS_FORWARDER | não | 1.1.1.1 | Servidor DNS para onde o DC encaminha resoluções externas. |
| NETBIRD_MANAGEMENT_URL | sim para mesh | — | URL do Management Server NetBird (ex.: https://netbird.example.com:33073). |
| NETBIRD_SETUP_KEY | não | vazio | Setup Key do NetBird. Vazio desativa o cliente NetBird. |
| NETBIRD_PEER_IP | não | — | Apenas informativa; mostra no log o IP mesh esperado para o peer. |

## Acesso via NetBird

Nenhuma porta é publicada no host: o acesso ao DC acontece exclusivamente pela malha. No painel NetBird:

1. Gere uma Setup Key para o peer.
2. Defina um IP estático para o peer (facilita apontar serviços de forma determinística).
3. Aponte o DNS do domínio (ou a zona swat.local) para o IP mesh do DC, para que as máquinas do domínio resolvam LDAP, Kerberos e DNS corretamente.

## Persistência

Todos os dados ficam em volumes nomeados: `samba-dados`, `samba-config`, `samba-logs`, `netbird-config` e `netbird-estado`. Com isso, a identidade do peer NetBird (e todo o estado do domínio) é preservada entre recriações do container.

## Integração com swat4

Este repo pode ser clonado em `./samba-dc` dentro do projeto swat4 (gerenciador web), cujo docker-compose.yml faz referência a esse caminho como build context, permitindo subir o DC junto com a stack do gerenciador.