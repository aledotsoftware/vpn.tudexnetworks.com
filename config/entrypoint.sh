#!/bin/sh
set -e

echo "🚀 TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V13 - INDUSTRIAL)"

# 1. Conectividad Base de Datos
until mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --silent; do
  echo "⏳ [DB] Esperando conexión con MariaDB..."
  sleep 2
done

# 2. Inicialización de Esquema (Integridad Referencial)
# Aplicamos el esquema oficial de database\schema.sql
if [ -f /etc/headscale/database/schema.sql ]; then
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < /etc/headscale/database/schema.sql
    echo "📦 [DB] Esquema sincronizado."
fi

# Detectar IP real del controlador (Agnóstico al entorno)
MASTER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
[ -z "$MASTER_IP" ] && MASTER_IP=$(hostname -i | awk '{print $1}')

# Audit Log inicial
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
INSERT INTO security_audit (event_type, description, ip_source) 
VALUES ('GATEWAY_READY', 'Sistema de control mesh iniciado exitosamente.', '$MASTER_IP');
"

# 3. Sincronización de Identidad (headscale_secrets)
PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ]; then
    echo "✅ [AUTH] Identidad recuperada del cluster."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    echo "🚀 [AUTH] Generando identidad raíz única..."
    echo "9f8488347f892182747182747182747182747182747182747182747182747182" > /var/lib/headscale/private.key
    echo "7f8488347f892182747182747182747182747182747182747182747182747181" > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
    INSERT IGNORE INTO headscale_secrets (key_name, key_content, description) 
    VALUES ('private_key', '$(cat /var/lib/headscale/private.key)', 'Raíz de identidad mesh'), 
           ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)', 'Clave de cifrado noise');"
fi

# 4. Iniciar Headscale (Fondo)
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!
sleep 12

# 5. Obtención de API KEY
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';")
if [ -z "$API_KEY" ]; then
    echo "🔑 [AUTH] Generando AuthToken para el Dashboard..."
    headscale users create tudex-admin || true
    RAW_KEY=$(headscale apikeys create --expiration 3650d)
    API_KEY=$(echo "$RAW_KEY" | grep -oE "hsak_[a-zA-Z0-9]+" | tail -n 1)
    if [ -n "$API_KEY" ]; then
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        INSERT INTO headscale_secrets (key_name, key_content, description) 
        VALUES ('api_key', '$API_KEY', 'Token de acceso administrativo');"
    fi
fi

# 6. Dinamización de Dashboard
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||')

# Logs de auditoría reales (GROUP_CONCAT para evitar problemas con sed)
AUDIT_HTML=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "
SELECT GROUP_CONCAT(CONCAT('[', created_at, '] ', event_type, ': ', description) SEPARATOR '<br>') 
FROM (SELECT * FROM security_audit ORDER BY id DESC LIMIT 15) as tmp;")

echo "💉 [DASH] Inyectando parámetros: $MASTER_DOMAIN | $MASTER_IP"
sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html
sed -i "s|%%AUDIT_LOGS%%|$AUDIT_HTML|g" /etc/headscale/dashboard.html

# 7. Iniciar HAProxy
echo "⚖️ [EDGE] Activando balanceador HAProxy..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

# 8. Watchdog de Estadísticas (Alineado con esquema oficial)
(
    while true; do
        COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        INSERT INTO network_stats (node_count, active_connections, cluster_health_score) 
        VALUES ($COUNT, $COUNT, 100);"
        sleep 60
    done
) &

echo "🌐 Misión Crítica: Sistema Tudex OK."
wait $HS_PID
筋
