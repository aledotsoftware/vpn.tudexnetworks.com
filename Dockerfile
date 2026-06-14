
# Build stage para descargar dependencias pesadas
FROM alpine:3.19 AS builder
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

# Instalamos HAProxy y dependencias
# jq reemplaza a mariadb-client para parsear respuestas JSON de Firebase
# mariadb-client es añadido de vuelta para compatibilidad de logs legacy
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
# Copiamos configuraciones y preparamos el entorno en menos capas
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY ./config/config.yaml ./config/dashboard.html ./config/admin-panel.html ./config/acl.hujson ./config/domain-map.txt ./config/errors ./database/schema.sql /etc/headscale/
COPY ./config/entrypoint.sh /entrypoint.sh

RUN mv /etc/headscale/errors /etc/headscale/errors_tmp && \
    mkdir -p /etc/headscale/errors && \
    mv /etc/headscale/errors_tmp/* /etc/headscale/errors/ || true && \
    rm -rf /etc/headscale/errors_tmp && \
    sed -i 's/\r$//' /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Puertos
EXPOSE 80 443 8080 9090 8404

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
