# Build stage para descargar dependencias pesadas
FROM alpine:3.19 AS builder
RUN apk add --no-cache curl
RUN curl -L https://github.com/juanfont/headscale/releases/download/v0.22.3/headscale_0.22.3_linux_amd64 -o /bin/headscale && \
    chmod +x /bin/headscale

# Usamos Alpine como base para tener un shell y gestor de paquetes
FROM alpine:3.19

# Instalamos HAProxy y dependencias
# Generamos directorios necesarios (sin wget ya que no se usa)
RUN apk add --no-cache \
    haproxy \
    mariadb-client \
    mariadb-connector-c \
    ca-certificates \
    curl \
    tailscale \
    iptables \
    ip6tables && \
    mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copiamos el binario compilado/descargado desde la fase builder
COPY --from=builder /bin/headscale /bin/headscale

# Copiamos configuraciones
COPY ./config/entrypoint.sh /entrypoint.sh
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY ./config/config.yaml /etc/headscale/config.yaml
COPY ./config/dashboard.html /etc/headscale/dashboard.html
COPY ./config/acl.hujson /etc/headscale/acl.hujson
COPY ./config/errors /etc/headscale/errors
COPY ./database/schema.sql /etc/headscale/database/schema.sql

# Puertos
EXPOSE 80 443 8080 9090 8404

ENTRYPOINT ["/entrypoint.sh"]
