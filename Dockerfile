# Usamos Alpine como base para tener un shell y gestor de paquetes
FROM alpine:latest

# Instalamos Headscale, HAProxy y dependencias
RUN apk add --no-cache \
    haproxy \
    mariadb-client \
    mariadb-connector-c \
    ca-certificates \
    curl \
    wget

# Descargamos el binario oficial de Headscale (ajustado a la arquitectura)
# Nota: Usamos la versión estable actual
RUN curl -L https://github.com/juanfont/headscale/releases/download/v0.22.3/headscale_0.22.3_linux_amd64 -o /bin/headscale && \
    chmod +x /bin/headscale

# Generamos directorios necesarios
RUN mkdir -p /etc/headscale /var/lib/headscale /var/run/headscale /usr/local/etc/haproxy

# Copiamos configuraciones
COPY ./config/entrypoint.sh /entrypoint.sh
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY ./config/config.yaml /etc/headscale/config.yaml
COPY ./config/dashboard.html /etc/headscale/dashboard.html

RUN chmod +x /entrypoint.sh

# Puertos
EXPOSE 80 443 8080 9090 8404

ENTRYPOINT ["/entrypoint.sh"]
