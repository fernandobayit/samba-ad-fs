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

    # Create sample OUs
    echo "==> Creating sample OUs..."
    samba-tool ou create "OU=Company,DC=swat,DC=local" || true
    samba-tool ou create "OU=Users,OU=Company,DC=swat,DC=local" || true
    samba-tool ou create "OU=Groups,OU=Company,DC=swat,DC=local" || true
    samba-tool ou create "OU=IT,OU=Company,DC=swat,DC=local" || true
    samba-tool ou create "OU=HR,OU=Company,DC=swat,DC=local" || true

    # Create sample users
    echo "==> Creating sample users..."
    samba-tool user create john.doe "${SAMBA_ADMIN_PASSWORD}" \
        --given-name="John" --surname="Doe" --mail-address="john.doe@swat.local" \
        --userou="OU=Users,OU=Company" || true
    samba-tool user create jane.smith "${SAMBA_ADMIN_PASSWORD}" \
        --given-name="Jane" --surname="Smith" --mail-address="jane.smith@swat.local" \
        --userou="OU=Users,OU=Company" || true
    samba-tool user create bob.wilson "${SAMBA_ADMIN_PASSWORD}" \
        --given-name="Bob" --surname="Wilson" --mail-address="bob.wilson@swat.local" \
        --userou="OU=IT,OU=Company" || true

    # Create sample groups
    echo "==> Creating sample groups..."
    samba-tool group create "IT Staff" --groupou="OU=Groups,OU=Company" --description="IT Department Staff" || true
    samba-tool group create "HR Team" --groupou="OU=Groups,OU=Company" --description="HR Department" || true
    samba-tool group create "Managers" --groupou="OU=Groups,OU=Company" --description="Company Managers" || true

    # Add users to groups
    samba-tool group addmembers "IT Staff" bob.wilson || true
    samba-tool group addmembers "HR Team" jane.smith || true
    samba-tool group addmembers "Managers" john.doe || true

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
