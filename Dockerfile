FROM headscale/headscale:latest-debug

# Instalamos HAProxy y herramientas de red
USER root
RUN apk add --no-cache mariadb-client mariadb-connector-c haproxy

# Copiamos configuraciones
COPY ./config/entrypoint.sh /entrypoint.sh
COPY ./config/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
RUN chmod +x /entrypoint.sh

# Exponemos puertos: 80 (HTTP), 443 (HTTPS), 8080 (Headscale), 8404 (Stats HAProxy)
EXPOSE 80 443 8080 9090 8404

ENTRYPOINT ["/entrypoint.sh"]
