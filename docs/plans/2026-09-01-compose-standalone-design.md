# Design: docker-compose.yml standalone + README no samba-ad-fs

> Data: 2026-09-01 | Status: Aprovado

## Objetivo

Cada repositorio tem seu proprio modelo de `docker-compose.yml`. O repo
`samba-ad-fs` ganha um compose standalone completo do Samba AD DC com acesso
**somente via mesh NetBird** (sem portas publicadas no host), mais um
`README.md`.

## Decisoes

- Standalone completo (porte: build local da imagem, privileged, volumes)
- **Sem `ports:`** — acesso apenas pela malha NetBird (wt0)
- **Sem `.env`** — todas as variaveis na secao `environment:` do compose
- Valores sensiveis via interpolacao `${VAR:-placeholder}`:
  - `${SAMBA_ADMIN_PASSWORD:-ChangeThisPassword}` — entrypoint recusa o
    placeholder (fail-fast existente)
  - `${NETBIRD_SETUP_KEY:-}` — vazio desativa o NetBird
  - `${NETBIRD_MANAGEMENT_URL:-https://netbird.example.com:33073}`
- Senha/setup key reais definidas no shell (`export`) ou editadas no arquivo
  antes do deploy; nunca commitadas
- Healthcheck (`samba-tool processes`) + `restart: unless-stopped`

## Conteudos

### docker-compose.yml

- service `samba-dc`: build `.`, hostname `dc1`, domainname `swat.local`,
  `privileged: true`, `devices: /dev/net/tun`, `environment:` (SAMBA_REALM,
  SAMBA_DOMAIN, SAMBA_ADMIN_PASSWORD, SAMBA_DNS_FORWARDER,
  SAMBA_BASE_DN?, NETBIRD_MANAGEMENT_URL, NETBIRD_SETUP_KEY,
  NETBIRD_PEER_IP comentado opcional), volumes:
  - `samba-dados:/var/lib/samba`
  - `samba-config:/etc/samba`
  - `samba-logs:/var/log/samba`
  - `netbird-config:/etc/netbird` + `netbird-estado:/var/lib/netbird`
    (identidade do peer preservada entre recriacoes)
- volumes nomeados declarados; sem networks custom (bridge default)

### README.md (PT)

- O que e o projeto (Samba 4 AD DC em container com NetBird embutido)
- Requisitos (Docker + Docker Compose)
- Quick start: editar `environment:` → `docker compose up -d` → acompanhar logs
- Tabela de env vars (Samba + NetBird)
- Nota de seguranca (nao commitar valores reais; placeholder falha de proposito)
- Acesso exclusivo via mesh: configurar no painel NetBird IP estatico do peer +
  DNS do dominio apontando para o IP mesh
- Integracao com swat4 (clone em `./samba-dc`; compose do swat4 continua sendo o
  stack completo)