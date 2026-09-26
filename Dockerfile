FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Sao_Paulo

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-ad-dc \
    samba-ad-provision \
    samba-dsdb-modules \
    samba-vfs-modules \
    winbind \
    libnss-winbind \
    libpam-winbind \
    ldb-tools \
    krb5-user \
    krb5-config \
    dnsutils \
    iproute2 \
    e2fsprogs \
    ca-certificates \
    curl \
    gnupg \
    supervisor \
    procps \
    && rm -rf /var/lib/apt/lists/*

# NetBird (mesh VPN) — optional, enabled via NETBIRD_SETUP_KEY
# Versão 0.79.0: o resolver local escuta em --dns-resolver-address
# (definido no entrypoint como 127.0.0.1:5053) — a :53 fica do Samba.
RUN case "$(dpkg --print-architecture)" in \
      amd64) NB_ARCH=amd64 ;; \
      arm64) NB_ARCH=arm64 ;; \
      *) NB_ARCH=amd64 ;; \
    esac && \
    curl -sSL -o /tmp/netbird.deb "https://github.com/netbirdio/netbird/releases/download/v0.79.0/netbird_0.79.0_linux_${NB_ARCH}.deb" && \
    apt-get install -y --no-install-recommends /tmp/netbird.deb && \
    rm -f /tmp/netbird.deb

# Environment defaults
ENV SAMBA_REALM=SWAT.LOCAL
ENV SAMBA_DOMAIN=SWAT
ENV SAMBA_ADMIN_PASSWORD=ChangeThisPassword
ENV SAMBA_DNS_FORWARDER=8.8.8.8

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 53 88 135 139 389 445 464 636 3268 3269

ENTRYPOINT ["/entrypoint.sh"]
