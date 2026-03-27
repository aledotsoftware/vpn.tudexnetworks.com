# Etapa 1: Builder
FROM alpine:3.19 AS builder
RUN apk add --no-cache curl && \
    curl -L https://github.com/juanfont/headscale/releases/download/v0.22.3/headscale_0.22.3_linux_amd64 -o /bin/headscale && \
    chmod +x /bin/headscale

# Etapa 2: Imagen Final
FROM alpine:3.19

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
RUN apk add --no-cache \
    haproxy \
    jq \
    ca-certificates \
    curl \
    tailscale \
    iptables \
    xxd \
    ip6tables && \
    mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy
    mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copiamos el binario compilado/descargado desde la fase builder
COPY --from=builder /bin/headscale /bin/headscale

# Copiar el binario desde la etapa builder
COPY --from=builder /bin/headscale /bin/headscale

# Copiamos configuraciones
COPY ./config/entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY ./config/config.yaml /etc/headscale/config.yaml
COPY ./config/dashboard.html /etc/headscale/dashboard.html
COPY ./config/admin-panel.html /etc/headscale/admin-panel.html
COPY ./config/acl.hujson /etc/headscale/acl.hujson
COPY ./config/domain-map.txt /etc/headscale/domain-map.txt
COPY ./config/errors /etc/headscale/errors

# Puertos
EXPOSE 80 443 8080 9090 8404

ENTRYPOINT ["/entrypoint.sh"]
