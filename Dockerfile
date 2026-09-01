FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-dsdb-modules \
    samba-vfs-modules \
    winbind \
    ldb-tools \
    krb5-user \
    krb5-config \
    dnsutils \
    ca-certificates \
    curl \
    gnupg \
    supervisor \
    procps \
    && rm -rf /var/lib/apt/lists/*

# NetBird (mesh VPN) — optional, enabled via NETBIRD_SETUP_KEY
RUN curl -sSL https://pkgs.netbird.io/debian/public.key | \
    gpg --dearmor -o /usr/share/keyrings/netbird.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/netbird.gpg] https://pkgs.netbird.io/debian stable main" > \
    /etc/apt/sources.list.d/netbird.list && \
    apt-get update && apt-get install -y --no-install-recommends netbird && \
    rm -rf /var/lib/apt/lists/*

# Environment defaults
ENV SAMBA_REALM=SWAT.LOCAL
ENV SAMBA_DOMAIN=SWAT
ENV SAMBA_ADMIN_PASSWORD=ChangeThisPassword
ENV SAMBA_DNS_FORWARDER=8.8.8.8

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53 88 135 139 389 445 464 636 3268 3269

ENTRYPOINT ["/entrypoint.sh"]
