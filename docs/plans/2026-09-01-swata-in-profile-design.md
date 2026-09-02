# Design: swat4 junto do DC no compose do samba-ad-fs (profile swat4)

> Data: 2026-09-01 | Status: Aprovado

## Objetivo

O `docker-compose.yml` do samba-ad-fs passa a subir tambem o gerenciador web
swat4 (backend + frontend, imagens GHCR), preservando o modo DC puro como
padrao.

## Decisoes

- Servicos swat4 sob `profiles: ["swat4"]`:
  - `docker compose up -d` — comportamento atual (so o DC, acesso mesh)
  - `docker compose --profile swat4 up -d` — DC + gerenciador web
- Portas da UI publicadas apenas em `127.0.0.1` (filosofia mesh/segura)
- Config via `environment:` inline com interpolacao `${VAR:-default}`; os
  servicos swat4 compartilham as mesmas variaveis do DC (um unico export
  `SAMBA_ADMIN_PASSWORD` alimenta ambos)
- Rede: os servicos swat4 usam a rede default do proprio projeto para alcancar
  `samba-ad-dc1` (sem rede externa)
- Volumes do proprio projeto diretamente: `samba-config`, `samba-logs` (ro),
  `samba-shares` + novo volume `swat4-data:/app/data`

## Mudancas

### docker-compose.yml (samba-ad-fs)

1. Novo servico `swat4-backend` (profile swat4):
   - `ghcr.io/fernandobayit/swat4-backend:latest` + `pull_policy: always`
   - env: `SAMBA_DC_HOST=samba-ad-dc1`, `LDAP_URL=ldap://samba-ad-dc1:389`,
     `SAMBA_REALM/DOMAIN/BASE_DN/ADMIN_USER/ADMIN_PASSWORD` via interpolacao
     compartilhada, `JWT_SECRET`, `ALLOWED_LOGIN_GROUPS`, `TZ`, `SAMBA_LOG_PATH`
   - volumes: samba-config, samba-logs (ro), samba-shares, swat4-data
   - `ports: 127.0.0.1:8000:8000`; `depends_on: samba-dc (service_healthy)`
2. Novo servico `swat4-frontend` (profile swat4):
   - `ghcr.io/fernandobayit/swat4-frontend:latest` + `pull_policy: always`
   - env: `NEXT_PUBLIC_API_URL=${SWAT4_API_URL:-http://localhost:8000}`,
     `API_URL=http://swat4-backend:8000`
   - `ports: 127.0.0.1:3000:3000`; `depends_on: swat4-backend`
3. Novo volume `swat4-data`

### README.md (samba-ad-fs)

Nova secao "Subir com o gerenciador web (swat4)": comando com profile, aviso de
que as portas ficam apenas em localhost, exemplo de exports (senha admin +
JWT_SECRET) e URL de acesso.

## Testes

- `docker compose config -q` (padrao) → so samba-dc
- `docker compose --profile swat4 config -q` → 3 servicos
- E2E: `--profile swat4 up` → healthcheck DC, login na API em
  `http://localhost:8000`, frontend 200 em localhost; confirmar binds apenas
  127.0.0.1; down -v ao final