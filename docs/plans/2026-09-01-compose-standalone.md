# Compose standalone + README (samba-ad-fs) — Plano de Implementacao

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Adicionar ao repo `samba-ad-fs` um `docker-compose.yml` standalone completo do DC (acesso so via NetBird) e um `README.md`.

**Architecture:** Compose unico de servico `samba-dc` (build local, privileged, `/dev/net/tun`, environment inline com interpolacao de placeholders, volumes persistentes incluindo identidade NetBird). Sem `ports:`. Sem `.env`.

**Tech Stack:** Docker Compose, Bash (entrypoint existente), Markdown.

---

## Task 1: docker-compose.yml standalone

**Files:**
- Create: `docker-compose.yml`

**Step 1: Escrever o arquivo**

```yaml
# Samba 4 AD DC — deploy standalone
# Acesso exclusivo via malha NetBird (nenhuma porta publicada no host).
# Defina os valores no shell antes de subir (export SAMBA_ADMIN_PASSWORD=...)
# ou edite os placeholders abaixo. Nunca commite valores reais.

services:
  samba-dc:
    build: .
    image: samba-ad-fs:latest
    container_name: samba-ad-dc1
    hostname: dc1
    domainname: swat.local
    privileged: true
    devices:
      - /dev/net/tun
    environment:
      SAMBA_REALM: ${SAMBA_REALM:-SWAT.LOCAL}
      SAMBA_DOMAIN: ${SAMBA_DOMAIN:-SWAT}
      SAMBA_ADMIN_PASSWORD: ${SAMBA_ADMIN_PASSWORD:-ChangeThisPassword}
      SAMBA_DNS_FORWARDER: ${SAMBA_DNS_FORWARDER:-1.1.1.1}
      NETBIRD_MANAGEMENT_URL: ${NETBIRD_MANAGEMENT_URL:-https://netbird.example.com:33073}
      NETBIRD_SETUP_KEY: ${NETBIRD_SETUP_KEY:-}
      # NETBIRD_PEER_IP: ${NETBIRD_PEER_IP:-}   # informativa apenas
    volumes:
      - samba-dados:/var/lib/samba
      - samba-config:/etc/samba
      - samba-logs:/var/log/samba
      - netbird-config:/etc/netbird
      - netbird-estado:/var/lib/netbird
    restart: unless-stopped
    healthcheck:
      test: [ "CMD", "samba-tool", "processes", "--configfile=/etc/samba/smb.conf" ]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 120s

volumes:
  samba-dados:
  samba-config:
  samba-logs:
  netbird-config:
  netbird-estado:
```

**Step 2: Validar**

Run: `docker compose config -q; echo exit=$?` (nao imprimir o config completo)
Expected: `exit=0`

**Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: docker-compose standalone do DC com acesso via NetBird"
```

---

## Task 2: README.md

**Files:**
- Create: `README.md`

**Step 1: Escrever o README (PT)**

- Titulo + descricao (Samba 4 Active Directory DC em container, NetBird embutido)
- Requisitos: Docker + Docker Compose
- Quick start: revisar `environment:` no compose → `export` das variaveis reais
  (ex.: `export SAMBA_ADMIN_PASSWORD='...'` e `export NETBIRD_SETUP_KEY='...'`) →
  `docker compose up -d`
- Tabela de variaveis (Samba e NetBird; obrigatoriedade; default)
- Nota: placeholder `ChangeThisPassword` faz o container recusar subir (fail-fast)
- Acesso pela mesh: IP estatico do peer + DNS do dominio no painel NetBird
- Persistencia: volumes nomeados (inclui identidade do peer NetBird)
- Integracao com swat4: clone em `./samba-dc` dentro do projeto swat4

**Step 2: Revisar leitura e links**

Run: `cat README.md`
Expected: sem valores sensiveis, comandos corretos.

**Step 3: Commit**

```bash
git add README.md docs/plans/2026-09-01-compose-standalone-design.md
git commit -m "docs: README e design do compose standalone"
```

---

## Task 3: Verificacao final + push

**Step 1: Varredura de segredos no que sera commitado**

Run: `git grep --cached -n -iE "Admin@1234|ghp_|gho_|NETBIRD_SETUP_KEY: [^$]"`
Expected: nenhum match com valor real (so `${NETBIRD_SETUP_KEY:-}`).

**Step 2: Push**

```bash
git push origin main
```