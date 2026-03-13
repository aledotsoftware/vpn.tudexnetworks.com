#!/bin/sh
set -e

echo "🚀 TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V17 - EXIT NODE ENABLED)"

# 1. Capa de Datos
until mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --silent; do
  echo "⏳ [DB] Sincronizando con MariaDB Backbone..."
  sleep 2
done

# Aplicar esquema oficial
SCHEMA_FILE="/etc/headscale/database/schema.sql"
if [ -f "$SCHEMA_FILE" ]; then
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SCHEMA_FILE"
    echo "✅ [DB] Esquema oficial aplicado."
fi

# Descubrimiento de red
MASTER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
[ -z "$MASTER_IP" ] && MASTER_IP=$(hostname -i | awk '{print $1}')
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||')

# 2. Gestión de Identidad del Cluster
PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ]; then
    echo "✅ [AUTH] Identidad recuperada."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    echo "🚀 [AUTH] Creando raíz de identidad de malla..."
    echo "9f8488347f892182747182747182747182747182747182747182747182747182" > /var/lib/headscale/private.key
    echo "7f8488347f892182747182747182747182747182747182747182747182747181" > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
fi

# 3. Lanzar Plano de Control (Headscale)
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!
sleep 15

# 4. Aprovisionamiento de Claves
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';")
if [ -z "$API_KEY" ]; then
    headscale users create tudex-admin || true
    API_KEY=$(headscale apikeys create --expiration 3650d | grep -oE "hsak_[a-zA-Z0-9]+" | tail -n 1)
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('api_key', '$API_KEY');"
fi

# Generar Reusable Pre-AuthKey para Satélites
SATELLITE_KEY=$(headscale preauthkeys create -u tudex-admin --reusable --expiration 2160h | grep -oE "[a-f0-9]{48}" || echo "FAILED_KEY")
echo "🔑 [SATELLITE_KEY] $SATELLITE_KEY"

# 5. Gateway Mesh Participation (Self-Exit Node)
mkdir -p /var/run/tailscale /var/lib/tailscale
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 5
# El Gateway se une a su propia malla y se anuncia como Exit Node
tailscale up --login-server http://localhost:8080 --authkey "$SATELLITE_KEY" --hostname "master-gateway" --advertise-exit-node --accept-routes

# Pasos adicionales para routing real: Masquerade
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# 6. Dashboard Patching
LOGS_JSON=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT GROUP_CONCAT(CONCAT('[', created_at, '] ', event_type, ': ', description) SEPARATOR '<br>') FROM (SELECT * FROM security_audit ORDER BY id DESC LIMIT 10) as t;")
sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html
sed -i "s|%%AUDIT_LOGS%%|$LOGS_JSON|g" /etc/headscale/dashboard.html

# 7. HAProxy Edge
echo "⚖️ [EDGE] Iniciando HAProxy Gateway..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

# 8. Watchdog
(
    while true; do
        COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO network_stats (node_count, active_connections, cluster_health_score) VALUES ($COUNT, $COUNT, 100);"
        sleep 60
    done
) &

echo "🌐 TUDEX MESH: EXIT NODE & SATELLITE HUB OPERATIONAL"
wait $HS_PID
筋
