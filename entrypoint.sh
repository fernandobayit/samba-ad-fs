#!/bin/bash
set -e

SAMBA_REALM=${SAMBA_REALM:-SWAT.LOCAL}
SAMBA_DOMAIN=${SAMBA_DOMAIN:-SWAT}
SAMBA_ADMIN_PASSWORD=${SAMBA_ADMIN_PASSWORD:-ChangeThisPassword}
SAMBA_DNS_FORWARDER=${SAMBA_DNS_FORWARDER:-1.1.1.1}

if [ -z "$SAMBA_ADMIN_PASSWORD" ] || [ "$SAMBA_ADMIN_PASSWORD" = "ChangeThisPassword" ]; then
    echo "ERROR: SAMBA_ADMIN_PASSWORD must be set (do not use the placeholder default)."
    exit 1
fi

PROVISIONED_FLAG="/var/lib/samba/.provisioned"

if [ ! -f "$PROVISIONED_FLAG" ]; then
    echo "==> Provisioning Samba AD DC for realm ${SAMBA_REALM}..."

    # Remove default config
    rm -f /etc/samba/smb.conf

    # Provision the domain
    samba-tool domain provision \
        --use-rfc2307 \
        --realm="${SAMBA_REALM}" \
        --domain="${SAMBA_DOMAIN}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass="${SAMBA_ADMIN_PASSWORD}" \
        --option="dns forwarder = ${SAMBA_DNS_FORWARDER}" \
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

    # ── Shares, NSS e mkhomedir ──────────────────────────────
    echo "==> Creating share directories..."
    mkdir -p /mnt/data/{Corporativo,Pessoal,Profile,TIC,.snapshots}

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

    touch "$PROVISIONED_FLAG"
    echo "==> Samba AD DC provisioned successfully!"
else
    echo "==> Samba AD DC already provisioned, starting..."
fi

# Create log directory
mkdir -p /var/log/samba

# ── NetBird mesh (optional) ─────────────────────────────
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

    netbird service start --log-file console || {
        echo "ERROR: failed to start NetBird daemon." >&2
        exit 1
    }
    for _ in {1..10}; do
        if netbird status --check live >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    netbird up --management-url "$NETBIRD_MANAGEMENT_URL" --setup-key "$NETBIRD_SETUP_KEY" 2>&1 || {
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
fi

echo "==> Starting Samba AD DC..."
exec samba --foreground --no-process-group
