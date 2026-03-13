#!/bin/sh
set -e

# Configurar trap para salir limpiamente
trap 'echo "🛑 Recibido SIGTERM/SIGINT. Saliendo..."; exit 0' TERM INT

echo "🚀 TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V21 - TOTAL RESILIENCE)"

# 0. Asegurar dispositivo TUN
if [ ! -c /dev/net/tun ]; then
    echo "🔧 Creando interfaz TUN..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
fi

# 1. Capa de Datos
MAX_RETRIES=30
RETRY_COUNT=0
DB_AVAILABLE=false

echo "⏳ [DB] Sincronizando con MariaDB Backbone..."
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --silent; then
    DB_AVAILABLE=true
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "⏳ [DB] Reintento $RETRY_COUNT/$MAX_RETRIES..."
  sleep 2
done

if [ "$DB_AVAILABLE" = "false" ]; then
  echo "❌ [DB] Error crítico: No se pudo conectar a la base de datos después de $MAX_RETRIES intentos."
  echo "⚠️ Saliendo del proceso de inicio. Verifica la configuración de la BD."
  exit 1
fi

echo "✅ [DB] Conexión establecida."

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
PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';" || echo "")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';" || echo "")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ] && [ -n "$NOISE_KEY" ]; then
    echo "✅ [AUTH] Identidad recuperada."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    echo "🚀 [AUTH] Generando raíz de identidad de malla dinámicamente..."
    # Generar claves aleatorias seguras (64 hex chars = 32 bytes)
    head -c 32 /dev/urandom | xxd -p -c 32 > /var/lib/headscale/private.key
    head -c 32 /dev/urandom | xxd -p -c 32 > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('KEY_ROTATION', 'Generación inicial dinámica de claves WireGuard/Noise', '$MASTER_IP');"
fi

# 3. Lanzar Plano de Control (Headscale)
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!
sleep 10

# 4. Aprovisionamiento de Claves
headscale users create tudex-admin || true

# API Key Dashboard - Verificación de Validez (Self-Healing)
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';" || echo "")
VALID_KEY=false

if [ -n "$API_KEY" ]; then
    # Probar si la llave actual funciona
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" http://localhost:8080/api/v1/machine)
    if [ "$CODE" = "200" ]; then
        VALID_KEY=true
        echo "✅ [AUTH] API Key válida recuperada."
    fi
fi

if [ "$VALID_KEY" = "false" ]; then
    echo "🔄 [AUTH] Generando nueva API Key (la anterior no era válida)..."
    API_KEY=$(headscale apikeys create --expiration 3650d | grep -oE "[a-zA-Z0-9._-]+" | tail -n 1)
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('api_key', '$API_KEY') ON DUPLICATE KEY UPDATE key_content='$API_KEY';"
fi

# Satellite Pre-AuthKey
SATELLITE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='satellite_auth_key';" || echo "")
if [ -z "$SATELLITE_KEY" ]; then
    SATELLITE_KEY=$(headscale preauthkeys create -u tudex-admin --reusable --expiration 2160h | grep -oE "[a-f0-9]{48}" || echo "")
    if [ -n "$SATELLITE_KEY" ]; then
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('satellite_auth_key', '$SATELLITE_KEY') ON DUPLICATE KEY UPDATE key_content='$SATELLITE_KEY';"
    fi
fi

# 5. Dashboard Patching
LOGS_HTML=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT GROUP_CONCAT(CONCAT('[', created_at, '] ', event_type, ': ', description) SEPARATOR '<br>') FROM (SELECT * FROM security_audit ORDER BY id DESC LIMIT 10) as t;" || echo "No logs")
KEYS_HTML=$(headscale preauthkeys list -u tudex-admin --output json-line | awk '{print "<tr><td><b>" $1 "</b></td><td>" $2 "</td><td>" $3 "</td><td>" $4 "</td></tr>"}' || echo "<tr><td colspan='4'>No active keys</td></tr>")

sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html
sed -i "s|%%AUDIT_LOGS%%|$LOGS_HTML|g" /etc/headscale/dashboard.html
sed -i "s|%%ACTIVE_KEYS%%|$KEYS_HTML|g" /etc/headscale/dashboard.html

# 6. Activar HAProxy (ANTES de la conexión mesh para evitar bloqueos)
echo "⚖️ [EDGE] Iniciando HAProxy Gateway..."
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('GATEWAY_BOOT', 'HAProxy Edge Gateway iniciado exitosamente', '$MASTER_IP');"
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

# 7. Conexión Mesh en Background (Evita que el boot se cuelgue si el 401 persiste)
(
    echo "📡 [MESH] Iniciando motor de enlace..."
    mkdir -p /var/run/tailscale /var/lib/tailscale
    tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /var/log/tailscaled.log 2>&1 &
    sleep 5
    
    # Reintentar hasta conectar
    while true; do
        if tailscale up --login-server http://localhost:8080 --authkey "$SATELLITE_KEY" --hostname "master-gateway-$MASTER_IP" --advertise-exit-node --accept-routes; then
            echo "✅ [MESH] Link established."
            break
        fi
        echo "⏳ [MESH] Reintentando conexión en 10s (AuthKey might be invalid yet)..."
        sleep 10
    done
) &

# 8. Watchdog de Telemetría
(
    while true; do
        COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
        COUNT_NUM=$(echo "$COUNT" | tr -cd '0-9')
        [ -z "$COUNT_NUM" ] && COUNT_NUM=0
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO network_stats (node_count, active_connections, cluster_health_score) VALUES ($COUNT_NUM, $COUNT_NUM, 100);"
        sleep 60
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA"
wait $HS_PID
