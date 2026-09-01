# NetBird embutido no container Samba AD DC — Plano de Implementacao

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Adicionar o cliente NetBird na imagem do Samba AD DC, com registro automatico via Setup Key, opcional (sem key = sem NetBird) e fail-fast com erro claro.

**Architecture:** NetBird instalado via repo oficial `pkgs.netbird.io` no Ubuntu 22.04. Entrypoint provisiona o AD (fluxo atual), sobe o NetBird (se chave presente), valida conexao e entao `exec samba`. O compose ganha o device `/dev/net/tun`.

**Tech Stack:** Ubuntu 22.04, Samba 4 (AD DC), NetBird client (apt), Bash, Docker Compose.

---

## Task 1: Instalar NetBird no Dockerfile

**Files:**
- Modify: `Dockerfile` (samba-dc/)

**Step 1: Adicionar repo e pacote NetBird**

Adicione apos o bloco `apt-get install` existente:

```dockerfile
# NetBird (mesh VPN) — optional, enabled via NETBIRD_SETUP_KEY
RUN curl -sSL https://pkgs.netbird.io/debian/public.key | \
    gpg --dearmor -o /usr/share/keyrings/netbird.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/netbird.gpg] https://pkgs.netbird.io/debian stable main" > \
    /etc/apt/sources.list.d/netbird.list && \
    apt-get update && apt-get install -y --no-install-recommends netbird && \
    rm -rf /var/lib/apt/lists/*
```

E adicione `curl` e `gnupg` ao bloco de instalacao de pacotes existente no `RUN` acima (linha com `samba`, `winbind` etc.).

**Step 2: Verificar sintaxe visual do Dockerfile**

Run: `cat Dockerfile`
Expected: repos adicionados corretamente, sem erros de sintaxe.

**Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat: instalar cliente NetBird na imagem"
```

(Repo: `samba-dc/` — samba-ad-fs)

---

## Task 2: Entrypoint — subir NetBird (opcional + fail-fast)

**Files:**
- Modify: `entrypoint.sh` (samba-dc/)

**Step 1: Adicionar bloco NetBird**

Insira entre a criacao de `/var/log/samba` e o `exec samba`:

```bash
# ── NetBird mesh (optional) ─────────────────────────────
if [ -n "$NETBIRD_SETUP_KEY" ]; then
    echo "==> NetBird: starting..."

    if [ ! -e /dev/net/tun ]; then
        echo "ERROR: /dev/net/tun not available. Add 'devices: - /dev/net/tun' to the container." >&2
        exit 1
    fi
    if [ -z "$NETBIRD_MANAGEMENT_URL" ]; then
        echo "ERROR: NETBIRD_MANAGEMENT_URL is required when NETBIRD_SETUP_KEY is set." >&2
        exit 1
    fi

    if [ -n "$NETBIRD_PEER_IP" ]; then
        echo "==> NetBird: expected mesh IP $NETBIRD_PEER_IP (informational)"
    fi

    netbird up --management-url "$NETBIRD_MANAGEMENT_URL" --setup-key "$NETBIRD_SETUP_KEY" 2>&1 || {
        echo "ERROR: netbird up failed. Check NETBIRD_MANAGEMENT_URL and NETBIRD_SETUP_KEY." >&2
        exit 1
    }

    connected=0
    for _ in $(seq 1 30); do
        if netbird status 2>/dev/null | grep -qi "connected"; then
            connected=1
            break
        fi
        sleep 3
    done

    if [ "$connected" -ne 1 ]; then
        echo "ERROR: NetBird did not reach Connected state within 90s." >&2
        netbird status 2>&1 | head -20 >&2
        exit 1
    fi

    echo "==> NetBird: connected."
fi
```

Mantenha ao final: `echo "==> Starting Samba AD DC..."` + `exec samba --foreground --no-process-group` (inalterados).

**Step 2: Verificar sintaxe do script**

Run: `bash -n entrypoint.sh`
Expected: sem saida (sintaxe OK).

**Step 3: Teste rapido de comportamento (negativo) em shell local**

Run (simula chave sem management URL):
```bash
NETBIRD_SETUP_KEY=x bash -c 'if [ -n "$NETBIRD_SETUP_KEY" ]; then netbird up 2>&1 && exit 0 || echo "sem binary: esperado local"; fi'
```
Expected: falha controlada (netbird nao existe no host local) — apenas confirma o fluxo de guardas; a validacao real acontece no container (Task 4).

**Step 4: Commit**

```bash
git add entrypoint.sh
git commit -m "feat: netbird opcional com fail-fast no entrypoint"
```

---

## Task 3: Compose (repo swat4) — /dev/net/tun + env documentado

**Files:**
- Modify: `docker-compose.yml` (raiz do repo swat4)
- Modify: `.env.example` (raiz do repo swat4)

**Step 1: Adicionar device ao servico samba-dc**

No servico `samba-dc` adicione (apos `privileged: true`):

```yaml
    devices:
      - /dev/net/tun
```

**Step 2: Documentar vars no .env.example**

Adicione ao final:

```bash
# NetBird mesh (optional) — leave NETBIRD_SETUP_KEY empty to disable
NETBIRD_MANAGEMENT_URL=https://netbird.example.com:33073
NETBIRD_SETUP_KEY=
# NETBIRD_PEER_IP=100.80.0.2  # informational only
```

**Step 3: Validar YAML**

Run: `docker compose config -q` (daemon nao precisa estar ativo para parse)
Expected: sem erro de parse.

**Step 4: Commit**

```bash
git add docker-compose.yml .env.example
git commit -m "feat: habilitar /dev/net/tun e vars NetBird no servico samba-dc"
```

(Repo: swat4)

---

## Task 4: Build da imagem + smoke tests

**Prerequisito:** Docker Desktop rodando (daemon estava parado).

**Files:**
- Create: `docs/plans/2026-09-01-netbird-embutido-checks.md` (log dos testes, opcional)

**Step 1: Build**

Run: `docker build -t samba-ad-fs:test .`
Expected: imagem construida com sucesso incluindo o pacote netbird.

**Step 2: Smoke sem NetBird (key vazia)**

Run:
```bash
docker run --rm -e SAMBA_ADMIN_PASSWORD=Teste@123 samba-ad-fs:test &
sleep 40; docker ps
```
Expected: container ativo (Samba rodando), log "Starting Samba AD DC", sem mensagens de NetBird.

**Step 3: Smoke fail-fast (key com management URL invalida)**

Run:
```bash
docker run --rm -e SAMBA_ADMIN_PASSWORD=Teste@123 -e NETBIRD_SETUP_KEY=invalida -e NETBIRD_MANAGEMENT_URL=https://10.255.255.1:33073 --device /dev/net/tun samba-ad-fs:test 2>&1 | tail -5
```
Expected: container encerra com `ERROR: NetBird did not reach Connected state` (ou erro similar do `netbird up`).

**Step 4: Smoke completo (depende da sua infra)**

Run: com `NETBIRD_SETUP_KEY` e `NETBIRD_MANAGEMENT_URL` reais do seu NetBird self-hosted
Expected: log "NetBird: connected." e `netbird status` = Connected no peer (IP estatico configurado no painel).

**Step 5: Push**

```bash
git push origin main
```

(Repo samba-ad-fs)

---

## Notas

- `NETBIRD_PEER_IP` e apenas informativa (sem acao automatica)
- Sem `NETBIRD_SETUP_KEY` o comportamento permanece identico ao atual
- Supervisao do daemon NetBird (supervisor) pode ser evolucao futura
---

## Notas da execucao (post-implementacao)

Desvios/descobertas durante o build e smoke tests:

1. **ca-certificates** precisou ser adicionado ao primeiro RUN (curl HTTPS falhava)
2. **Poll troca de grep para `netbird status --check startup`** (grep `connected` casava
   com `Disconnected`; `--check` exige management+signal conectados; exige netbird >= 0.67)
3. **`netbird service start` antes do `netbird up`** — v0.70 exige daemon rodando;
   `service start` funciona no container sem systemd
4. **Smoke test exige `--privileged`** (xattr `security.NTACL` do provisionamento
   requer capacidades) e volumes — igual ao compose real
5. No Docker Desktop o `/dev/net/tun` existe mesmo sem `devices` (VM LinuxKit);
   o guard `-c /dev/net/tun` continua valido para outros runtimes

Smoke results:
- Sem `NETBIRD_SETUP_KEY`: container sobe normalmente ✅
- Key invalida/management inacessivel: daemon inicia, up falha, erro claro, exit 1 ✅
- Caminho "Connected": requer management + setup key reais (verificacao do usuario)
