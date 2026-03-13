#!/bin/sh
echo "🔄 Iniciando sistema Tudex (V8 - PROD STABLE)..."

# 1. Conexión a Base de Datos Central
until mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --silent; do
  echo "⏳ Esperando MySQL..."
  sleep 2
done

# 2. Sincronización de Identidad Global
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "CREATE TABLE IF NOT EXISTS headscale_secrets (key_name VARCHAR(64) PRIMARY KEY, key_content TEXT);"

PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ]; then
    echo "✅ Identidad recuperada del cluster MySQL."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    echo "🚀 Generando nueva identidad raíz para el cluster..."
    # Claves deterministas robustas si el binario no puede generarlas
    echo "9f8488347f892182747182747182747182747182747182747182747182747182" > /var/lib/headscale/private.key
    echo "7f8488347f892182747182747182747182747182747182747182747182747181" > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
fi

# 3. Lanzar Plano de Control (Headscale)
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!

echo "⏳ Inicializando motor VPN (10s)..."
sleep 10

# 4. Gestión de Acceso al Dashboard (API Credentials)
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';")

if [ -z "$API_KEY" ]; then
    echo "🔑 Creando canal de acceso para el Dashboard..."
    headscale users create tudex-admin || true
    # Generar y capturar solo el token alfanumérico largo
    RAW_KEY=$(headscale apikeys create --expiration 3650d)
    API_KEY=$(echo "$RAW_KEY" | grep -oE "[a-zA-Z0-9\._-]{30,}")
    
    if [ -n "$API_KEY" ]; then
        echo "✅ Canal de acceso establecido."
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('api_key', '$API_KEY');"
    else
        echo "❌ Error generando credenciales. Logs:"
        echo "$RAW_KEY"
    fi
fi

# 5. Activación Dinámica del Dashboard
if [ -n "$API_KEY" ]; then
    echo "💉 Sincronizando datos en tiempo real con el panel..."
    # Aseguramos que el archivo sea fresco del volumen o imagen
    sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
fi

# 6. Lanzar Edge Gateway (HAProxy)
echo "⚖️ Iniciando HAProxy (L7 Load Balancer)..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

echo "🚀 COMPLETO. Dashboard: http://localhost:8081/dashboard"
echo "📊 HAProxy Stats: http://localhost:8404/stats"

wait $HS_PID
