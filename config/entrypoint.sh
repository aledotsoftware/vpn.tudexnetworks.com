#!/bin/sh
set -e

echo "🔄 Iniciando sistema de Auto-Sincronización (Backend: MySQL)..."

# 1. Esperar a MySQL
until mysqladmin ping -h "$DB_HOST" --silent; do
  echo "⏳ Esperando a que MySQL esté listo en $DB_HOST..."
  sleep 2
done

# 2. Sincronización de secretos (Igual que antes)
mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "CREATE TABLE IF NOT EXISTS headscale_secrets (key_name VARCHAR(64) PRIMARY KEY, key_content TEXT);"
PRIVATE_KEY=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';")
NOISE_KEY=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';")

mkdir -p /var/lib/headscale
if [ -n "$PRIVATE_KEY" ] && [ -n "$NOISE_KEY" ]; then
    echo "✅ Claves sincronizadas desde MySQL."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
else
    /bin/headscale nodes list > /dev/null 2>&1 || true
    if [ ! -f /var/lib/headscale/private.key ]; then /bin/headscale generate-private-key > /var/lib/headscale/private.key; fi
    timeout 2 /bin/headscale serve -c /etc/headscale/config.yaml || true
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
fi

# 4. Iniciar HAProxy (Balanceador Mesh)
echo "⚖️ Iniciando Balanceador HAProxy Mesh..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

# 5. Iniciar Headscale (Cerebro)
echo "🎯 Iniciando Headscale..."
exec /bin/headscale serve -c /etc/headscale/config.yaml
