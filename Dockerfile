# Build stage para descargar dependencias pesadas
FROM alpine:3.19 AS builder
# hadolint ignore=DL3018
RUN apk add --no-cache curl && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then HS_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then HS_ARCH="arm64"; \
    else HS_ARCH="amd64"; fi && \
    echo "Descargando Headscale para arquitectura: $HS_ARCH ($ARCH)" && \
    curl -L "https://github.com/juanfont/headscale/releases/download/v0.22.3/headscale_0.22.3_linux_${HS_ARCH}" -o /bin/headscale && \
    chmod +x /bin/headscale

# Usamos Alpine como base para tener un shell y gestor de paquetes
FROM alpine:3.19

ENV TZ=UTC

# Instalamos HAProxy y dependencias
# jq reemplaza a mariadb-client para parsear respuestas JSON de Firebase
# mariadb-client es añadido de vuelta para compatibilidad de logs legacy
# hadolint ignore=DL3018
RUN apk add --no-cache \
    haproxy \
    jq \
    mariadb-client \
    ca-certificates \
    curl \
    tailscale \
    iptables \
    xxd \
    ip6tables && \
    mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copiamos el binario compilado/descargado desde la fase builder
COPY --from=builder /bin/headscale /bin/headscale
# Copiamos configuraciones y preparamos el entorno en menos capas consolidando copias
COPY ./config/ ./database/ /tmp/setup/

RUN mv /tmp/setup/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg && \
    mv /tmp/setup/config.yaml /tmp/setup/dashboard.html /tmp/setup/admin-panel.html /tmp/setup/acl.hujson /tmp/setup/domain-map.txt /tmp/setup/schema.sql /etc/headscale/ && \
    mv /tmp/setup/errors /etc/headscale/errors && \
    mv /tmp/setup/entrypoint.sh /entrypoint.sh && \
    rm -rf /tmp/setup && \
    sed -i 's/\r$//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Puertos
STOPSIGNAL SIGTERM

EXPOSE 80 443 8080 9090 8404

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
