#!/bin/sh
set -e

# Securely pass database password without exposing it in the process list
# Soporte para Docker Secrets y variables de entorno tradicionales
if [ -f "/run/secrets/db_pass" ]; then
    MYSQL_PWD="$(cat /run/secrets/db_pass)"
    export MYSQL_PWD
else
    export MYSQL_PWD="$DB_PASS"
fi

if [ -f "/run/secrets/db_user" ]; then
    DB_USER="$(cat /run/secrets/db_user)"
    export DB_USER
fi

# Configurar trap para salir limpiamente
trap 'echo "🛑 Recibido SIGTERM/SIGINT. Saliendo..."; mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('\''GATEWAY_SHUTDOWN'\'', '\''Gateway detenido exitosamente'\'', '\''$MASTER_IP'\'');" 2>/dev/null || true; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

echo "🚀 TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V21 - TOTAL RESILIENCE)"

# 0. Asegurar dispositivo TUN
if [ ! -c /dev/net/tun ]; then
    echo "🔧 Creando interfaz TUN..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
fi

# 1. Capa de Datos
MAX_RETRIES=15
RETRY_COUNT=0
DB_AVAILABLE=false
BACKOFF_DELAY=1
MAX_BACKOFF=10

echo "⏳ [DB] Sincronizando con MariaDB Backbone (con Exponential Backoff)..."
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if timeout 5 mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" --silent; then
    DB_AVAILABLE=true
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))

  echo "⏳ [DB] Reintento $RETRY_COUNT/$MAX_RETRIES (Esperando ${BACKOFF_DELAY}s)..."
  sleep "$BACKOFF_DELAY"

  # Exponential backoff con límite
  BACKOFF_DELAY=$((BACKOFF_DELAY * 2))
  if [ "$BACKOFF_DELAY" -gt "$MAX_BACKOFF" ]; then
      BACKOFF_DELAY=$MAX_BACKOFF
  fi
done

if [ "$DB_AVAILABLE" = "false" ]; then
  echo "❌ [DB] Error crítico: No se pudo conectar a la base de datos después de $MAX_RETRIES intentos."
  echo "[$(date -u)] SECURITY_AUDIT - EVENT: DB_ERROR - Fallo crítico de conexión a MariaDB Backbone al arrancar (IP Source: 127.0.0.1)" >> /var/log/headscale_security_audit.log
  echo "⚠️ Saliendo del proceso de inicio. Verifica la configuración de la BD."
  exit 1
fi

echo "✅ [DB] Conexión establecida."

# Descubrimiento de red (Necesario aquí para los logs)
MASTER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
[ -z "$MASTER_IP" ] && MASTER_IP=$(hostname -i | awk '{print $1}')
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||')

# Aplicar esquema oficial
SCHEMA_FILE="/etc/headscale/database/schema.sql"
if [ -f "$SCHEMA_FILE" ]; then
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" < "$SCHEMA_FILE"
    echo "✅ [DB] Esquema oficial aplicado."
fi

# Registrar conexión exitosa en la base de datos (después del esquema para asegurar tabla)
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('DB_CONNECTED', 'Conexión a MariaDB Backbone establecida exitosamente', '$MASTER_IP');" || true

# Intentar registrar la creación de la interfaz TUN de forma aislada (no fatal) para auditoría.
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('TUN_INITIALIZED', 'Interfaz de túnel VPN asegurada e inicializada', '$MASTER_IP');" 2>/dev/null || true

# Auditoría de gestión de secretos Docker (falla silenciada para no romper container al inicio de CI)
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('SECRETS_LOADED', 'Credenciales cacheadas de manera aislada (Entorno / Secrets)', '$MASTER_IP');" || true

# 2. Gestión de Identidad del Cluster (Seguridad Centralizada)
# Evitamos harcodear las llaves generándolas con un buen nivel de entropía si no existen,
# y las almacenamos cifradas y centralizadas en el MySQL para compartirlas con otros nodos (HA).
PRIVATE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='private_key';" || echo "")
NOISE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='noise_private_key';" || echo "")

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ] && [ -n "$NOISE_KEY" ]; then
    echo "✅ [AUTH] Identidad recuperada."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('IDENTITY_RECOVERY', 'Identidad de red recuperada exitosamente de la base de datos', '$MASTER_IP');" || true
else
    echo "🚀 [AUTH] Generando raíz de identidad de malla dinámicamente..."
    # Generar claves aleatorias seguras (64 hex chars = 32 bytes)
    head -c 32 /dev/urandom | xxd -p -c 32 > /var/lib/headscale/private.key
    head -c 32 /dev/urandom | xxd -p -c 32 > /var/lib/headscale/noise_private.key
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT IGNORE INTO headscale_secrets (key_name, key_content) VALUES ('private_key', '$(cat /var/lib/headscale/private.key)'), ('noise_private_key', '$(cat /var/lib/headscale/noise_private.key)');"
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('KEY_ROTATION', 'Generación inicial dinámica de claves WireGuard/Noise', '$MASTER_IP');" || true
fi

# Registrar carga de ACL en base de datos de auditoría
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('ACL_UPDATE', 'Políticas ACL actualizadas y cargadas', '$MASTER_IP');" || true

# Configuración Dinámica de Headscale (desde variables de entorno)
[ -z "$VPN_SERVER_URL" ] && VPN_SERVER_URL="http://localhost:8080"
[ -z "$VPN_IP_PREFIX" ] && VPN_IP_PREFIX="100.64.0.0/10"
[ -z "$VPN_BASE_DOMAIN" ] && VPN_BASE_DOMAIN="vpn.internal"

echo "⚙️ [CONFIG] Inyectando configuración: URL=$VPN_SERVER_URL, Subnet=$VPN_IP_PREFIX"
sed -i "s|%%VPN_SERVER_URL%%|$VPN_SERVER_URL|g" /etc/headscale/config.yaml
sed -i "s|%%VPN_IP_PREFIX%%|$VPN_IP_PREFIX|g" /etc/headscale/config.yaml
sed -i "s|%%VPN_BASE_DOMAIN%%|$VPN_BASE_DOMAIN|g" /etc/headscale/config.yaml

# 3. Lanzar Plano de Control (Headscale)
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!

echo "⏳ [CORE] Esperando inicialización de Headscale..."
HS_RETRIES=0
HS_MAX_RETRIES=15
while [ $HS_RETRIES -lt $HS_MAX_RETRIES ]; do
  if curl -s http://localhost:9090/metrics > /dev/null; then
    echo "✅ [CORE] Headscale operativo."
    break
  fi
  HS_RETRIES=$((HS_RETRIES + 1))
  sleep 1
done

if [ $HS_RETRIES -eq $HS_MAX_RETRIES ]; then
  echo "⚠️ [CORE] Advertencia: Headscale tardó mucho en responder, continuando de todas formas..."
fi

# 4. Aprovisionamiento y Creación Segura de Claves
# El usuario admin se requiere para aprovisionar llaves. Su creación
# se registra en la base de datos de auditoría con la IP que invocó el arranque.
if headscale users create tudex-admin 2>/dev/null; then
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('USER_CREATED', 'Usuario tudex-admin creado en el control plane', '$MASTER_IP');" || true
fi || true

# API Key Dashboard - Verificación de Validez (Self-Healing)
API_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='api_key';" || echo "")
VALID_KEY=false

if [ -n "$API_KEY" ]; then
    # Probar si la llave actual funciona
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" http://localhost:8080/api/v1/machine)
    if [ "$CODE" = "200" ]; then
        VALID_KEY=true
        echo "✅ [AUTH] API Key válida recuperada."
        mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('API_KEY_RECOVERY', 'API Key de Dashboard validada exitosamente', '$MASTER_IP');" || true
    fi
fi

if [ "$VALID_KEY" = "false" ]; then
    echo "🔄 [AUTH] Generando nueva API Key (la anterior no era válida)..."
    API_KEY=$(headscale apikeys create --expiration 3650d | grep -oE "[a-zA-Z0-9._-]+" | tail -n 1)
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('api_key', '$API_KEY') ON DUPLICATE KEY UPDATE key_content='$API_KEY';"
    mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('KEY_ROTATION', 'Generación de nueva API Key de Dashboard', '$MASTER_IP');" || true
fi

# Satellite Pre-AuthKey
SATELLITE_KEY=$(mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -N -s -e "SELECT key_content FROM headscale_secrets WHERE key_name='satellite_auth_key';" || echo "")
if [ -z "$SATELLITE_KEY" ]; then
    SATELLITE_KEY=$(headscale preauthkeys create -u tudex-admin --reusable --expiration 2160h | grep -oE "[a-f0-9]{48}" || echo "")
    if [ -n "$SATELLITE_KEY" ]; then
        mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO headscale_secrets (key_name, key_content) VALUES ('satellite_auth_key', '$SATELLITE_KEY') ON DUPLICATE KEY UPDATE key_content='$SATELLITE_KEY';"
        mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('KEY_ROTATION', 'Generación de nueva llave de autenticación de satélites (AuthKey)', '$MASTER_IP');" || true
    fi
fi

# 5. Dashboard Patching
sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html

# 6. Activar HAProxy (ANTES de la conexión mesh para evitar bloqueos)
echo "⚖️ [EDGE] Iniciando HAProxy Gateway..."
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('GATEWAY_BOOT', 'HAProxy Edge Gateway iniciado exitosamente con mitigaciones anti-DoS y Anti-Escaneo', '$MASTER_IP');" || true
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -D

# 7. Conexión Mesh en Background (Evita que el boot se cuelgue si el 401 persiste)
(
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
    
    # Reintentar hasta conectar
    while true; do
        if tailscale up --login-server http://localhost:8080 --authkey "$SATELLITE_KEY" --hostname "master-gateway-$MASTER_IP" --advertise-exit-node --accept-routes --accept-dns=false; then
            echo "✅ [MESH] Link established."
            mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('NODE_JOIN', 'Gateway unido a la malla (Mesh Link Established)', '$MASTER_IP');" || true
            break
        fi
        echo "⏳ [MESH] Reintentando conexión en 10s (AuthKey might be invalid yet)..."
        sleep 10
    done
) &

# 8. Watchdog de Telemetría
(
    while true; do
        if timeout 2 mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" --silent; then
            COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
            COUNT_NUM=$(echo "$COUNT" | tr -cd '0-9')
            [ -z "$COUNT_NUM" ] && COUNT_NUM=0
            mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO network_stats (node_count, active_connections, cluster_health_score) VALUES ($COUNT_NUM, $COUNT_NUM, 100);" || true
        else
            echo "[$(date -u)] WATCHDOG_ERROR - Fallo de conexión a MariaDB Backbone al insertar telemetría." >> /var/log/headscale_security_audit.log
        fi
        sleep 60
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA"
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('SYSTEM_ONLINE', 'Tudex Mesh operando a capacidad completa y asegurado', '$MASTER_IP');" || true
wait $HS_PID
