#!/bin/bash
set -e

echo "🚀 TUDEX SATELLITE NODE - BOOT SEQUENCER"

# 0. Asegurar dispositivo TUN
if [ ! -c /dev/net/tun ]; then
    echo "🔧 Creando interfaz TUN..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
fi

# 1. Iniciar Tailscaled en segundo plano
echo "📡 [MESH] Iniciando motor de enlace..."
mkdir -p /var/run/tailscale /var/lib/tailscale
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /var/log/tailscaled.log 2>&1 &

# Active polling para asegurar que el daemon esté listo
echo "⏳ [MESH] Esperando inicialización del daemon de tailscale..."
TS_RETRIES=0
while [ ! -S /var/run/tailscale/tailscaled.sock ] && [ $TS_RETRIES -lt 15 ]; do
    sleep 1
    TS_RETRIES=$((TS_RETRIES + 1))
done

# 2. Conexión Mesh (Headscale) en segundo plano para no bloquear Apache
echo "📡 [MESH] Intentando unión a la malla: $NODE_NAME..."
(
    while true; do
        if tailscale up --login-server "$VPN_SERVER_URL" --authkey "$VPN_AUTH_KEY" --hostname "$NODE_NAME" --accept-routes --accept-dns=false; then
            echo "✅ [MESH] Conexión establecida con $VPN_SERVER_URL."
            break
        fi
        echo "⏳ [MESH] Reintentando conexión en 10s..."
        sleep 10
    done
) &

# 3. Lanzar Apache (PHP)
echo "🌐 [WEB] Iniciando servidor PHP..."
apache2-foreground
