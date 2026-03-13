# Etapa 1: Builder
FROM alpine:3.19 AS builder
RUN apk add --no-cache curl && \
    curl -L https://github.com/juanfont/headscale/releases/download/v0.22.3/headscale_0.22.3_linux_amd64 -o /bin/headscale && \
    chmod +x /bin/headscale

# Etapa 2: Imagen Final
FROM alpine:3.19

RUN apk add --no-cache \
    haproxy \
    mariadb-client \
    mariadb-connector-c \
    ca-certificates \
    curl \
    tailscale \
    iptables \
    xxd \
    ip6tables && \
    mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy

# Copiar el binario desde la etapa builder
COPY --from=builder /bin/headscale /bin/headscale

# Copiamos configuraciones
COPY ./config/entrypoint.sh /entrypoint.sh
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY ./config/config.yaml /etc/headscale/config.yaml
COPY ./config/dashboard.html /etc/headscale/dashboard.html
COPY ./database/schema.sql /etc/headscale/database/schema.sql

# Puertos
EXPOSE 80 443 8080 9090 8404

ENTRYPOINT ["/entrypoint.sh"]
