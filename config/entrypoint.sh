#!/bin/sh
echo "🔄 Iniciando sistema Tudex (V9 - CLUSTER & SCHEMA)..."

# 1. Conexión y Migraciones de Esquema Central
until mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" --silent; do
  echo "⏳ Esperando MySQL..."
  sleep 2
done

echo "📦 Inicializando Esquema de Datos..."
# Tabla de Secretos (Identidad de Red)
mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
CREATE TABLE IF NOT EXISTS headscale_secrets (
    key_name VARCHAR(64) PRIMARY KEY, 
    key_content TEXT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS network_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    node_count INT,
    traffic_in BIGINT,
    traffic_out BIGINT,
    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS cluster_config (
    config_key VARCHAR(64) PRIMARY KEY,
    config_value TEXT
);
"

# 2. Sincronización de Identidad Global
PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ]; then
    echo "✅ Identidad recuperada del cluster."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    echo "🚀 Creando Claves Raíz de la Malla..."
    echo "9f8488347f892182747182747182747182747182747182747182747182747182" > /var/lib/headscale/private.key
    echo "7f8488347f892182747182747182747182747182747182747182747182747181" > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
fi

# 3. Lanzar Plano de Control
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!

echo "⏳ Calibrando servicios (10s)..."
sleep 10

# 4. Obtener/Generar API KEY
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';")
if [ -z "$API_KEY" ]; then
    echo "🔑 Creando AuthToken Maestro..."
    headscale users create tudex-admin || true
    RAW_KEY=$(headscale apikeys create --expiration 3650d)
    API_KEY=$(echo "$RAW_KEY" | grep -oE "[a-zA-Z0-9\._-]{30,}" | tail -n 1)
    mariadb -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('api_key', '$API_KEY');"
fi

# 5. Inyección Dinámica en Dashboard
MASTER_IP=$(hostname -i | awk '{print $1}')
# Extraer dominio de la config (formato: server_url: https://dominio:puerto)
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|:.*||')

echo "💉 Setup Dashboard: Domain=$MASTER_DOMAIN | IP=$MASTER_IP"

sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html

# 6. Lanzar HAProxy
echo "⚖️ Iniciando HAProxy..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

echo "🌐 TUDEX MESH ONLINE"
wait $HS_PID
筋
