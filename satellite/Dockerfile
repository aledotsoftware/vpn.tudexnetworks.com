FROM php:8.2-apache

# Evitar prompts interactivos
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Instalar dependencias necesarias
# hadolint ignore=DL3008,DL3015
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    iptables \
    iproute2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Instalar Tailscale
# hadolint ignore=DL3008,DL3015,DL4006
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# Configurar Apache
RUN a2enmod rewrite && \
    rm -f /var/www/html/index.html

# Copiar archivos
COPY index.php /var/www/html/index.php
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

STOPSIGNAL SIGTERM

# Exponer el puerto HTTP
EXPOSE 80

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:80/ || exit 1

# Comando de inicio
ENTRYPOINT ["/entrypoint.sh"]
