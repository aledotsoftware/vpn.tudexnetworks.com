FROM php:8.2-apache

# Evitar prompts interactivos
ENV DEBIAN_FRONTEND=noninteractive

# Instalar dependencias necesarias
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    iptables \
    iproute2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Instalar Tailscale
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y tailscale \
    && rm -rf /var/lib/apt/lists/*

# Configurar Apache
RUN a2enmod rewrite

# Copiar archivos
COPY index.php /var/www/html/index.php
COPY entrypoint.sh /entrypoint.sh

# Asegurar permisos del entrypoint
RUN chmod +x /entrypoint.sh

# Eliminar el index.html por defecto para que muestre nuestro PHP
RUN rm -f /var/www/html/index.html

# Exponer el puerto HTTP
EXPOSE 80

# Comando de inicio
ENTRYPOINT ["/entrypoint.sh"]
