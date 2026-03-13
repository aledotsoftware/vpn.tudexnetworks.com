# Usamos Alpine como base para tener un shell y gestor de paquetes
FROM alpine:3.19

# Instalamos Headscale, HAProxy y dependencias
# Descargamos el binario oficial de Headscale (ajustado a la arquitectura)
# Generamos directorios necesarios
RUN apk add --no-cache \
    haproxy \
    mariadb-client \
    mariadb-connector-c \
    ca-certificates \
    curl \
    wget \
    tailscale \
    iptables \
    ip6tables && \
    curl -L https://github.com/juanfont/headscale/releases/download/v0.22.3/headscale_0.22.3_linux_amd64 -o /bin/headscale && \
    chmod +x /bin/headscale && \
    mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy

# Copiamos configuraciones
COPY ./config/entrypoint.sh /entrypoint.sh
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY ./config/config.yaml /etc/headscale/config.yaml
COPY ./config/dashboard.html /etc/headscale/dashboard.html
COPY ./database/schema.sql /etc/headscale/database/schema.sql

# Puertos
EXPOSE 80 443 8080 9090 8404

ENTRYPOINT ["/entrypoint.sh"]
