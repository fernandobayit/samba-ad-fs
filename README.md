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

3. Suba o container (a imagem é baixada do GitHub Container Registry — `ghcr.io/fernandobayit/samba-ad-fs:latest`; para build local, veja o comentário no docker-compose.yml):

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
| NETBIRD_MANAGEMENT_URL | sim para mesh | https://netbird.example.com:33073 | URL do Management Server NetBird self-hosted. |
| NETBIRD_SETUP_KEY | não | vazio | Setup Key do NetBird. Vazio desativa o cliente NetBird. |
| NETBIRD_PEER_IP | não | — | Apenas informativa; mostra no log o IP mesh esperado para o peer. |

## Acesso via NetBird

Nenhuma porta é publicada no host: o acesso ao DC acontece exclusivamente pela malha. No painel NetBird:

1. Gere uma Setup Key para o peer.
2. Defina um IP estático para o peer (facilita apontar serviços de forma determinística).
3. Aponte o DNS do domínio (ou a zona swat.local) para o IP mesh do DC, para que as máquinas do domínio resolvam LDAP, Kerberos e DNS corretamente.

## Persistência

Todos os dados ficam em volumes nomeados: `samba-dados`, `samba-config`, `samba-logs`, `samba-shares`, `netbird-config` e `netbird-estado`. Com isso, a identidade do peer NetBird (e todo o estado do domínio) é preservada entre recriações do container.

## Integração com swat4

Quando o swat4 roda no modo containerizado, ele entra na rede docker compartilhada `swat-net` e monta os volumes nomeados deste stack por nome (`<nome-do-projeto>_samba-config`, `<nome-do-projeto>_samba-logs`, `<nome-do-projeto>_samba-shares`). Por isso o diretório do projeto deve se chamar `samba-ad-fs` (ou informe `SAMBA_DC_COMPOSE_PROJECT` ao swat4); a rede `swat-net` é criada por quem subir primeiro.

### Subir com o gerenciador web (swat4) embutido

Este docker-compose.yml também traz o gerenciador web (backend + frontend do
swat4) como serviços opcionais:

```bash
export SAMBA_ADMIN_PASSWORD='sua-senha-forte'
export JWT_SECRET='um-segredo-longo-e-aleatorio'
docker compose --profile swat4 up -d
```

Acesse a interface em http://localhost:3000 (entre com uma conta de um grupo
listado em `ALLOWED_LOGIN_GROUPS`, ex.: Domain Admins). As portas 8000 e 3000
ficam publicadas apenas em 127.0.0.1 do host; para acesso remoto, use túnel
SSH, a malha NetBird ou edite o bind. Sem `--profile swat4`, somente o DC sobe
(comportamento padrão).