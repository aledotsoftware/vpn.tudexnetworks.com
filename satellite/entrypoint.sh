#!/bin/bash
# set -e  # Desactivar temporalmente para depuración

echo "🚀 TUDEX SATELLITE NODE - DEBUG BOOT"

# 0. TUN
if [ ! -c /dev/net/tun ]; then
    echo "🔧 Creando interfaz TUN..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
fi

# 1. Tailscaled
echo "📡 [MESH] Iniciando motor de enlace (Daemon)..."
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /var/log/tailscaled.log 2>&1 &

# 2. Apache
echo "🌐 [WEB] Iniciando Apache (Foreground)..."
# Lanzar Apache primero para asegurar que el balanceo por Docker funcione
apache2-foreground &
APACHE_PID=$!

# 3. Tailscale Join (Background Loop)
echo "📡 [MESH] Iniciando bucle de unión a la malla..."
(
    while true; do
        if tailscale --socket=/var/run/tailscale/tailscaled.sock up --login-server "$VPN_SERVER_URL" --authkey "$VPN_AUTH_KEY" --hostname "$NODE_NAME" --accept-routes --accept-dns=false; then
            echo "✅ [MESH] Link established."
            break
        fi
        echo "⏳ [MESH] Reintentando conexión en 10s..."
        sleep 10
    done
) &

# Mantener vivo el contenedor
wait $APACHE_PID
