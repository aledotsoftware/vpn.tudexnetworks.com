#!/bin/sh
set -e

echo "🚀 TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V20 - PRODUCTION READY)"

# 0. Asegurar dispositivo TUN (Crítico para servidores de Internet)
if [ ! -c /dev/net/tun ]; then
    echo "🔧 Creando interfaz TUN..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
fi

# 1. Capa de Datos
export MYSQL_PWD="$DB_PASS"
until mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" --silent; do
  echo "⏳ [DB] Sincronizando con MariaDB Backbone..."
  sleep 2
done

# Aplicar esquema oficial
SCHEMA_FILE="/etc/headscale/database/schema.sql"
if [ -f "$SCHEMA_FILE" ]; then
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < "$SCHEMA_FILE"
    echo "✅ [DB] Esquema oficial aplicado."
fi

# Descubrimiento de red
MASTER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
[ -z "$MASTER_IP" ] && MASTER_IP=$(hostname -i | awk '{print $1}')
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||')

mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('GATEWAY_BOOT', 'Tudex Operational Gateway started', '$MASTER_IP');"

# 2. Gestión de Identidad del Cluster
PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ]; then
    echo "✅ [AUTH] Identidad recuperada."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    echo "🚀 [AUTH] Generando raíz de identidad de malla..."
    head -c 32 /dev/urandom | hexdump -v -e '/1 "%02x"' > /var/lib/headscale/private.key
    head -c 32 /dev/urandom | hexdump -v -e '/1 "%02x"' > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('KEY_GENERATION', 'Generación de nueva raíz de identidad de malla', '$MASTER_IP');"
fi

# 3. Lanzar Plano de Control (Headscale)
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!
sleep 15

# 4. Aprovisionamiento de Claves
headscale users create tudex-admin || true

# API Key Dashboard
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';")
if [ -z "$API_KEY" ]; then
    API_KEY=$(headscale apikeys create --expiration 3650d | grep -oE "hsak_[a-zA-Z0-9]+" | tail -n 1)
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('api_key', '$API_KEY') ON DUPLICATE KEY UPDATE key_content='$API_KEY';"
fi

# Satellite Pre-AuthKey (Persistent for Lab)
SATELLITE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='satellite_auth_key';")
if [ -z "$SATELLITE_KEY" ]; then
    SATELLITE_KEY=$(headscale preauthkeys create -u tudex-admin --reusable --expiration 2160h | grep -oE "[a-f0-9]{48}" || echo "")
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('satellite_auth_key', '$SATELLITE_KEY') ON DUPLICATE KEY UPDATE key_content='$SATELLITE_KEY';"
fi

# 5. Gateway Mesh Node (Self-Exit Node)
mkdir -p /var/run/tailscale /var/lib/tailscale
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 5
tailscale up --login-server http://localhost:8080 --authkey "$SATELLITE_KEY" --hostname "master-gateway" --advertise-exit-node --accept-routes || true

# Routing (IP Masquerade para el Exit Node)
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE || true

# 6. Dashboard Patching
LOGS_HTML=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT GROUP_CONCAT(CONCAT('[', created_at, '] ', event_type, ': ', description) SEPARATOR '<br>') FROM (SELECT * FROM security_audit ORDER BY id DESC LIMIT 10) as t;" || echo "No logs")
KEYS_HTML=$(headscale preauthkeys list -u tudex-admin --output json-line | awk '{print "<tr><td><b>" $1 "</b></td><td>" $2 "</td><td>" $3 "</td><td>" $4 "</td></tr>"}' || echo "<tr><td colspan='4'>No active keys</td></tr>")

sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html
sed -i "s|%%AUDIT_LOGS%%|$LOGS_HTML|g" /etc/headscale/dashboard.html
sed -i "s|%%ACTIVE_KEYS%%|$KEYS_HTML|g" /etc/headscale/dashboard.html

# 7. HAProxy Edge
echo "⚖️ [EDGE] Iniciando HAProxy Gateway..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

# 8. Watchdog
(
    while true; do
        COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
        COUNT_NUM=$(echo "$COUNT" | tr -cd '0-9')
        [ -z "$COUNT_NUM" ] && COUNT_NUM=0
        mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO network_stats (node_count, active_connections, cluster_health_score) VALUES ($COUNT_NUM, $COUNT_NUM, 100);"
        sleep 60
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA DE PRODUCCIÓN INICIADA"
wait $HS_PID
筋
