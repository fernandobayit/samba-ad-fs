# Design: NetBird embutido no container Samba AD DC

> Data: 2026-09-01 | Status: Aprovado

## Objetivo

O container do Samba AD DC entra na mesh NetBird (self-hosted) para ser o
servidor DNS primario das maquinas ingressadas no dominio (`swat.local`),
acessivel remotamente via mesh sem abrir portas na internet.

## Decisoes do design

- NetBird instalado na propria imagem (Abordagem A - builtin)
- Registro via **Setup Key** automatica (env var) — sem interacao no painel
- **IP estatico do peer** definido no painel NetBird (responsabilidade do admin)
- **Sem atualizacao automatica de registro A** — administracao DNS do painel
  fica como responsabilidade manual
- `NETBIRD_PEER_IP` **opcional**: apenas env var documentada/passada, sem acao
  automatica atrelada
- NetBird e **opcional**: sem `NETBIRD_SETUP_KEY`, o container sobe so o Samba
- **Fail-fast**: com key definida, se a conexao a mesh falhar, aborta com erro
  claro (por padrao)

## Arquitetura

```
┌─────────────────────────────────────────┐
│ Container samba-dc (privileged)         │
│  /dev/net/tun                           │
│  ┌────────────────────┐ ┌─────────────┐ │
│  │ netbird daemon     │ │ samba       │ │
│  │ (wt0, background)  │ │ (foreground)│ │
│  └────────────────────┘ └─────────────┘ │
│  samba DNS interno: 0.0.0.0:53          │
└─────────────────────────────────────────┘
```

## Mudancas

### samba-ad-fs (`samba-dc/`)

1. **Dockerfile**: repo oficial `pkgs.netbird.io/debian` + instalacao do pacote
   `netbird` no Ubuntu 22.04
2. **entrypoint.sh**:
   - Fluxo atual de provisionamento AD (inalterado)
   - Se `NETBIRD_SETUP_KEY` definida:
     - Valida `/dev/net/tun` e `NETBIRD_MANAGEMENT_URL` (erro claro se faltar)
     - `netbird up --management-url ... --setup-key ...` (daemon fica em background)
     - Aguarda status "Connected" (timeout ~90s); falha → `exit 1` com mensagem
   - `exec samba` como hoje (sem supervisord; supervisao pode ser evolucao futura)

### swat4 (`docker-compose.yml`, servico samba-dc)

- `devices: /dev/net/tun`
- Passar env vars: `NETBIRD_MANAGEMENT_URL`, `NETBIRD_SETUP_KEY`,
  `NETBIRD_PEER_IP` (opcional) via env_file existente

## Env vars

| Variavel | Obrigatoria | Uso |
|---|---|---|
| `NETBIRD_MANAGEMENT_URL` | sim p/ mesh | URL do Management self-hosted |
| `NETBIRD_SETUP_KEY` | sim p/ mesh | Habilita NetBird + registro automatico |
| `NETBIRD_PEER_IP` | nao | Documentada; sem acao automatica |

## Erros e fail-fast

- Sem key → container sobe normalmente sem NetBird (log informativo)
- Com key, contexto: timeout/erro de conexao → mensagem de erro clara e `exit 1`

## Testes/verificacao

- Build da imagem (`docker build`)
- `docker exec` + `netbird status` → connected
- Consulta DNS `dig @<mesh-ip> dc1.swat.local` a partir de um peer da rede