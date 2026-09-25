#!/bin/bash
set -e

SAMBA_REALM=${SAMBA_REALM:-SWAT.LOCAL}
SAMBA_DOMAIN=${SAMBA_DOMAIN:-SWAT}
SAMBA_ADMIN_PASSWORD=${SAMBA_ADMIN_PASSWORD:-ChangeThisPassword}
SAMBA_DNS_FORWARDER=${SAMBA_DNS_FORWARDER:-1.1.1.1}
NETBIRD_DNS_PORT=${NETBIRD_DNS_PORT:-5053}
HOSTNAME_DC=${HOSTNAME_DC:-dc1}

if [ -z "$SAMBA_ADMIN_PASSWORD" ] || [ "$SAMBA_ADMIN_PASSWORD" = "ChangeThisPassword" ]; then
    echo "ERROR: SAMBA_ADMIN_PASSWORD must be set (do not use the placeholder default)."
    exit 1
fi

# ── NetBird mesh (optional) ─────────────────────────────
# Daemon sobe primeiro (sem connect); o connect acontece DEPOIS do
# provisionamento do Samba — assim a :53 já está do Samba e o netbird
# 0.71.x sobe o resolver local na 5053 (padrão do deploy de referência).
# A wt0 só ganha IP no connect; o /etc/hosts e o A record da malha são
# aplicados logo após o connect.
NETBIRD_CONNECT_URL=""
NETBIRD_CONNECT_KEY=""
if [ -n "$NETBIRD_SETUP_KEY" ]; then
    echo "==> NetBird: starting..."

    if [ ! -c /dev/net/tun ]; then
        echo "ERROR: /dev/net/tun not available. Add 'devices: - /dev/net/tun' to the container." >&2
        exit 1
    fi
    if [ -z "$NETBIRD_MANAGEMENT_URL" ]; then
        echo "ERROR: NETBIRD_MANAGEMENT_URL is required when NETBIRD_SETUP_KEY is set." >&2
        exit 1
    fi

    if [ -n "$NETBIRD_PEER_IP" ]; then
        echo "==> NetBird: expected mesh IP ${NETBIRD_PEER_IP} (informational)"
    fi

    rm -f /var/run/netbird.sock

    # Porta do DNS do netbird: 5053 (53 fica exclusiva do Samba).
    # "netbird service start" daemoniza via systemd e PERDE o ambiente —
    # no container rodamos o daemon direto ("service run") para herdar a env.
    export NB_DNS_FORWARDER_PORT="$NETBIRD_DNS_PORT"
    echo "NB_DNS_FORWARDER_PORT=$NETBIRD_DNS_PORT" > /etc/sysconfig/netbird 2>/dev/null || true

    netbird service run --log-level info \
        --daemon-addr unix:///var/run/netbird.sock \
        --log-file /var/log/netbird/client.log \
        >> /var/log/netbird/console.log 2>&1 &
    NB_PID=$!
    disown "$NB_PID" 2>/dev/null || true

    for _ in {1..10}; do
        if netbird status --check live >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    NETBIRD_CONNECT_URL="$NETBIRD_MANAGEMENT_URL"
    NETBIRD_CONNECT_KEY="$NETBIRD_SETUP_KEY"
fi

# ── Identidade do DC: hostname FQDN + /etc/hosts (item 10 do ref) ──
# O hostname do container é fixado pelo docker compose (hostname: dc1).
# /etc/hosts: FQDN aponta para o IP principal (wt0 se netbird ativo, senão eth0).
if ! grep -q "${HOSTNAME}.${SAMBA_REALM,,}" /etc/hosts 2>/dev/null; then
    L_REALM_LOWER=$(echo "${SAMBA_REALM}" | tr 'A-Z' 'a-z')
    _PRIMARY_IP=$(ip -4 -o addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -z "$_PRIMARY_IP" ] && _PRIMARY_IP=$(hostname -I | awk '{print $1}')
    if [ -n "$_PRIMARY_IP" ]; then
        echo "==> /etc/hosts: ${_PRIMARY_IP} ${HOSTNAME}.${L_REALM_LOWER} ${HOSTNAME}"
        echo "${_PRIMARY_IP} ${HOSTNAME}.${L_REALM_LOWER} ${HOSTNAME}" >> /etc/hosts
    else
        echo "WARN: sem IP primário para /etc/hosts (wt0 ausente e hostname -I vazio)." >&2
    fi
fi

PROVISIONED_FLAG="/var/lib/samba/.provisioned"

if [ ! -f "$PROVISIONED_FLAG" ]; then
    echo "==> Provisioning Samba AD DC for realm ${SAMBA_REALM}..."

    # Remove default config
    rm -f /etc/samba/smb.conf

    # Provision the domain (functional level 2016, igual ao deploy de referência)
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="${SAMBA_REALM}" \
        --domain="${SAMBA_DOMAIN}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --function-level=2016 \
        --adminpass="${SAMBA_ADMIN_PASSWORD}" \
        --option="dns forwarder = ${SAMBA_DNS_FORWARDER}" \
        --option="ad dc functional level = 2016" \
        --option="template homedir = /home/%D/%U" \
        --option="template shell = /bin/bash" \
        --option="winbind enum users = yes" \
        --option="winbind enum groups = yes" \
        --option="winbind use default domain = yes" \
        --option="winbind separator = @" \
        --option="vfs objects = dfs_samba4 acl_xattr full_audit shadow_copy2 recycle" \
        --option="full_audit:success = mkdirat linkat renameat unlinkat" \
        --option="full_audit:prefix = %U|%M|%S" \
        --option="full_audit:failure = none" \
        --option="full_audit:facility = local5" \
        --option="full_audit:priority = alert" \
        --option="full_audit:syslog = true" \
        --option="shadow:snapdir = /mnt/data/.snapshots" \
        --option="shadow:basedir = /mnt/data/" \
        --option="shadow:sort = desc" \
        --option="shadow:localtime = yes" \
        --option="shadow:format = %Y-%m-%d-%H%M" \
        --option="map to guest = bad user" \
        --option="map acl inherit = yes" \
        --option="acl_xattr:ignore system acl = yes" \
        --option="store dos attributes = yes" \
        --option="inherit acls = yes" \
        --option="inherit permissions = yes" \
        --option="idmap config * : backend = tdb" \
        --option="idmap config * : range = 3000-7999" \
        --option="log level = 1" \
        --option="log file = /var/log/samba/samba.log"

    # Copy Kerberos config
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

    # Allow plain LDAP binds (no TLS required) — DEV ONLY
    echo "==> Configuring LDAP to allow simple binds..."
    sed -i '/\[global\]/a\\tldap server require strong auth = no' /etc/samba/smb.conf

    # ── Estrutura organizacional e conta de serviço ──────────
    # Sufixo DN derivado do realm (ex.: SWAT.LOCAL → DC=swat,DC=local)
    DC_SUFFIX=$(echo "${SAMBA_REALM}" | tr 'A-Z' 'a-z' | sed 's/\./,DC=/g; s/^/DC=/')

    # ── Interfaces: IP principal = NetBird (wt0) ─────────────
    # wt0 primeiro → seu IP fica como A record primário do DC no DNS;
    # lo e eth0 mantêm LDAP/DNS/SMB acessíveis dentro do host docker.
    echo "==> Configuring interfaces (NetBird wt0 as primary)..."
    sed -i '/\[global\]/a\\tinterfaces = lo wt0 eth0' /etc/samba/smb.conf

    echo "==> Creating base OUs (raiz + TIC)..."
    samba-tool ou create "OU=${SAMBA_DOMAIN},${DC_SUFFIX}" || true
    samba-tool ou create "OU=Tecnologia da Informação e Comunicação,OU=${SAMBA_DOMAIN},${DC_SUFFIX}" || true

    echo "==> Creating sample user 'gobah' and TIC group..."
    samba-tool user add gobah Default23 \
        --given-name="Gobah!" --surname="Soluções em TI" \
        --userou="OU=Tecnologia da Informação e Comunicação,OU=${SAMBA_DOMAIN}" || true
    samba-tool group add "Tecnologia da Informação e Comunicação" \
        --groupou="OU=Tecnologia da Informação e Comunicação,OU=${SAMBA_DOMAIN}" || true

    # Renomeia grupo para sAMAccountName TIC, mantendo o CN completo
    samba-tool group rename "Tecnologia da Informação e Comunicação" \
        --samaccountname=TIC \
        --force-new-cn="Tecnologia da Informação e Comunicação" || true

    samba-tool group addmembers TIC gobah || true
    samba-tool group addmembers 'Account Operators' TIC || true

    # ── Política de senhas (padrão do deploy de referência) ───
    echo "==> Configuring password policy (no max age, no complexity)..."
    samba-tool domain passwordsettings set --max-pwd-age=0 || true
    samba-tool domain passwordsettings set --complexity=off || true

    # ── Shares Corporativo/Pessoal/TIC no smb.conf ───────────
    echo "==> Configuring file shares..."
    cat >> /etc/samba/smb.conf <<EOF

[Corporativo]
	path = /mnt/data/Corporativo
	read only = no
	force user = root
	force group = root

[Pessoal]
	path = /mnt/data/Pessoal
	read only = no
	browseable = no
	full_audit:success = none
	full_audit:failure = none

[TIC]
	path = /mnt/data/TIC
	read only = no
	browseable = no
	full_audit:success = none
	full_audit:failure = none
EOF

    # Diretórios das shares (no volume samba-shares)
    echo "==> Creating share directories..."
    mkdir -p /mnt/data/{Corporativo,Pessoal,Profile,TIC,.snapshots}

    # ── resolv.conf: o DC é o resolvedor principal (item 10 do ref) ──
    # O netbird só deve tocar este arquivo DEPOIS do connect — e falha
    # porque ele ficará imutável (chattr +i), como no deploy de referência.
    echo "==> Configuring /etc/resolv.conf (DC as primary resolver)..."
    L_REALM_LOWER=$(echo "${SAMBA_REALM}" | tr 'A-Z' 'a-z')
    cat > /etc/resolv.conf <<EOF
search ${L_REALM_LOWER}
nameserver 127.0.0.1
EOF
    # Imutável durante a vida do container (como o chattr +i do ref).
    chattr +i /etc/resolv.conf 2>/dev/null || echo "WARN: chattr +i indisponível (resolv.conf poderá ser regravado pelo Docker)." >&2

    # NSS via winbind: permite resolver contas/grupos do AD (chown, etc.)
    if ! grep -q '^passwd:.*winbind' /etc/nsswitch.conf; then
        sed -i -E 's/^(passwd|group):([^#]*)$/\1\2 winbind/' /etc/nsswitch.conf
    fi

    # Criação automática de home dirs no primeiro login
    pam-auth-update --enable mkhomedir || true

    # ── SeDiskOperatorPrivilege + donos das pastas ───────────
    # net rpc e o mapeamento NSS exigem o serviço no ar: sobe
    # temporariamente, aplica e desliga antes do start definitivo.
    echo "==> Starting Samba temporarily (rights + share ownership)..."
    samba || echo "WARN: temporary 'samba' start exited nonzero; continuing." >&2

    dc_up=0
    for _ in {1..60}; do
        if (exec 3<>/dev/tcp/127.0.0.1/445) 2>/dev/null; then dc_up=1; break; fi
        sleep 2
    done

    if [ "$dc_up" -eq 1 ]; then
        echo "==> Granting SeDiskOperatorPrivilege to Domain Admins..."
        net rpc rights grant 'Domain Admins' SeDiskOperatorPrivilege \
            -U "administrator%${SAMBA_ADMIN_PASSWORD}" -S 127.0.0.1 \
            || echo "WARN: net rpc rights grant failed." >&2

        chown -R 'administrator':'Domain Admins' /mnt/data/* 2>/dev/null \
            || chown -R "${SAMBA_DOMAIN}\\administrator":"${SAMBA_DOMAIN}\\Domain Admins" /mnt/data/* 2>/dev/null \
            || echo "WARN: chown por contas do AD falhou (verificar winbind/NSS)." >&2
    else
        echo "WARN: Samba did not open port 445; SeDiskOperatorPrivilege/chown skipped." >&2
    fi

    echo "==> Stopping temporary Samba instance..."
    smbcontrol samba shutdown 2>/dev/null || true
    stopped=0
    for _ in {1..15}; do
        if ! (exec 3<>/dev/tcp/127.0.0.1/445) 2>/dev/null; then stopped=1; break; fi
        sleep 2
    done
    if [ "$stopped" -ne 1 ]; then
        kill "$(cat /run/samba/samba.pid 2>/dev/null)" 2>/dev/null || true
        sleep 2
        pkill -x samba 2>/dev/null || true
        pkill -x smbd 2>/dev/null || true
        pkill -x winbindd 2>/dev/null || true
        sleep 2
    fi

    # Registro DNS do DC: garantir o A record do IP principal (wt0/netbird).
    # O provision registra pelo IP da rota default (eth0); o IP da malha é
    # o que os peers devem resolver — adicionar explicitamente se divergir.
    if [ -n "$_PRIMARY_IP" ] && [ "$_PRIMARY_IP" != "$(hostname -I | awk '{print $1}')" ]; then
        L_REALM_LOWER2=$(echo "${SAMBA_REALM}" | tr 'A-Z' 'a-z')
        echo "==> Adding A record ${HOSTNAME}.${L_REALM_LOWER2} -> ${_PRIMARY_IP} (NetBird primary)"
        samba-tool dns add 127.0.0.1 "${L_REALM_LOWER2}" "${HOSTNAME}" A "$_PRIMARY_IP" \
            -U "administrator%${SAMBA_ADMIN_PASSWORD}" 2>/dev/null \
            || echo "WARN: falha ao adicionar A record do IP da malha (revisar manualmente)." >&2
    fi

    touch "$PROVISIONED_FLAG"
    echo "==> Samba AD DC provisioned successfully!"
else
    echo "==> Samba AD DC already provisioned, starting..."
fi

# ── NetBird: connect APÓS o Samba estar no ar ────────────
# Com a :53 ocupada pelo Samba, o netbird 0.71.x sobe o resolver local
# na 5053 (comportamento do deploy de referência, LSH-KLN01).
# O Samba definitivo é iniciado em background ANTES do connect para que a
# :53 nunca fique livre (o netbird conecta com o Samba já bindado).
echo "==> Starting Samba AD DC..."
samba --foreground --no-process-group &
SAMBA_PID=$!

if [ -n "$NETBIRD_CONNECT_URL" ]; then
    # Aguardar o dns[master] bindar a :53 antes do connect
    for _ in {1..30}; do
        if (exec 3<>/dev/tcp/127.0.0.1/53) 2>/dev/null; then break; fi
        sleep 1
    done

    echo "==> NetBird: connecting to management..."
    netbird up --management-url "$NETBIRD_CONNECT_URL" --setup-key "$NETBIRD_CONNECT_KEY" 2>&1 || {
        echo "ERROR: netbird up failed. Check NETBIRD_MANAGEMENT_URL and NETBIRD_SETUP_KEY." >&2
        exit 1
    }

    connected=0
    for _ in {1..30}; do
        if netbird status --check startup >/dev/null 2>&1; then
            connected=1
            break
        fi
        sleep 3
    done

    if [ "$connected" -ne 1 ]; then
        echo "ERROR: NetBird did not reach Connected state within 90s." >&2
        netbird status 2>&1 | head -n 20 >&2
        exit 1
    fi

    echo "==> NetBird: connected."

    # Agora sim a wt0 tem IP: FQDN no /etc/hosts + A record da malha no DNS.
    L_REALM_LOWER=$(echo "${SAMBA_REALM}" | tr 'A-Z' 'a-z')
    _MESH_IP=$(ip -4 -o addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$_MESH_IP" ]; then
        if ! grep -q "${HOSTNAME}.${L_REALM_LOWER}" /etc/hosts 2>/dev/null; then
            echo "==> /etc/hosts: ${_MESH_IP} ${HOSTNAME}.${L_REALM_LOWER} ${HOSTNAME}"
            echo "${_MESH_IP} ${HOSTNAME}.${L_REALM_LOWER} ${HOSTNAME}" >> /etc/hosts
        fi
        echo "==> Adding A record ${HOSTNAME}.${L_REALM_LOWER} -> ${_MESH_IP} (NetBird)"
        samba-tool dns add 127.0.0.1 "${L_REALM_LOWER}" "${HOSTNAME}" A "$_MESH_IP" \
            -U "administrator%${SAMBA_ADMIN_PASSWORD}" 2>/dev/null \
            || echo "WARN: falha ao adicionar A record do IP da malha (revisar manualmente)." >&2
    fi
fi

# Container vive enquanto o Samba viver
wait "$SAMBA_PID"
