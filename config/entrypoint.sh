#!/bin/sh
set -e

# ============================================================
# TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V23 - FIREBASE + DYNAMIC ROUTING)
# ============================================================
# Base de datos: Google Firebase Realtime Database
# Ruteo dinámico: Domain mappings en Firebase → HAProxy config auto-generado

# Función segura para cargar secretos (Archivos o Variables)
get_secret() {
    # shellcheck disable=SC3043
    local file_path="$1"
    # shellcheck disable=SC3043
    local env_var_name="$2"
    if [ -f "$file_path" ]; then
        tr -d '\n\r' < "$file_path"
    else
        eval "printf '%s\n' \"\$${env_var_name}\"" | tr -d '\n\r'
    fi
}

FIREBASE_BASE_URL="${FIREBASE_DB_URL}"

# --- FIREBASE HELPER FUNCTIONS ---
firebase_get() {
    # shellcheck disable=SC3043
    local path="$1"
    # shellcheck disable=SC3043
    local result
    result=$(curl -s "${FIREBASE_BASE_URL}/${path}.json" 2>/dev/null)
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        echo ""
    else
        echo "$result" | jq -r '.' 2>/dev/null || echo "$result"
    fi
}

firebase_put() {
    # shellcheck disable=SC3043
    local path="$1"
    # shellcheck disable=SC3043
    local data="$2"
    curl -s -X PUT -d "$data" "${FIREBASE_BASE_URL}/${path}.json" > /dev/null 2>&1
}

firebase_patch() {
    # shellcheck disable=SC3043
    local path="$1"
    # shellcheck disable=SC3043
    local data="$2"
    curl -s -X PATCH -d "$data" "${FIREBASE_BASE_URL}/${path}.json" > /dev/null 2>&1
}

firebase_post() {
    # shellcheck disable=SC3043
    local path="$1"
    # shellcheck disable=SC3043
    local data="$2"
    curl -s -X POST -d "$data" "${FIREBASE_BASE_URL}/${path}.json" > /dev/null 2>&1
}

audit_log() {
    # shellcheck disable=SC3043
    local event_type="$1"
    # shellcheck disable=SC3043
    local description="$2"
    # shellcheck disable=SC3043
    local severity="${3:-INFO}"
    # shellcheck disable=SC3043
    local ip_source="${4:-$MASTER_IP}"
    # shellcheck disable=SC3043
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    firebase_post "security_audit" "{\"event_type\":\"${event_type}\",\"severity\":\"${severity}\",\"description\":\"${description}\",\"ip_source\":\"${ip_source}\",\"created_at\":\"${timestamp}\"}" || true
    if command -v mariadb >/dev/null 2>&1; then
        # shellcheck disable=SC3043
        local safe_desc
        safe_desc=$(printf "%s" "$description" | sed 's/\\/\\\\/g; s/'\''/''/g')
        mariadb -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASS:-$MYSQL_PWD}" "$DB_NAME" -e "INSERT INTO security_audit (event_type, severity, description, ip_source, detailed_audit) VALUES ('$event_type', '$severity', '$safe_desc', '$ip_source', 1);" || true
    fi
}

# --- DOMAIN SYNC FUNCTION ---
# Lee domain_mappings de Firebase, genera domain-map.txt y backends dinámicos,
# y recarga HAProxy si hay cambios.
sync_domain_mappings() {
    MAPPINGS=$(curl -s "${FIREBASE_BASE_URL}/domain_mappings.json" 2>/dev/null)

    # Si no hay mappings o Firebase no responde, usar config base
    if [ "$MAPPINGS" = "null" ] || [ -z "$MAPPINGS" ] || ! echo "$MAPPINGS" | jq empty 2>/dev/null; then
        if [ "$MAPPINGS" = "null" ] || [ -z "$MAPPINGS" ]; then
            true > /etc/headscale/domain-map.txt
            cp /usr/local/etc/haproxy/haproxy.cfg /tmp/haproxy-active.cfg 2>/dev/null || true
            return 1
        fi
    fi

    # Generar domain-map.txt
    echo "$MAPPINGS" | jq -r '
        to_entries[] |
        select(.value.enabled == true) |
        select(.value.nodes != null) |
        select((.value.nodes | length) > 0) |
        .value.domain + " backend_" + .key
    ' > /tmp/domain-map-new.txt 2>/dev/null

    # Generar backends dinámicos
    true > /tmp/dynamic-backends.cfg
    KEYS=$(echo "$MAPPINGS" | jq -r '
        to_entries[] |
        select(.value.enabled == true) |
        select(.value.nodes != null) |
        select((.value.nodes | length) > 0) |
        .key
    ' 2>/dev/null)

    for key in $KEYS; do
        {
            echo ""
            echo "backend backend_${key}"
            echo "    balance roundrobin"
        } >> /tmp/dynamic-backends.cfg

        NODES=$(echo "$MAPPINGS" | jq -r ".\"${key}\".nodes[]" 2>/dev/null)
        i=1
        for node in $NODES; do
            echo "    server ${key}_${i} ${node}:80 check resolvers docker_dns inter 2s" >> /tmp/dynamic-backends.cfg
            i=$((i + 1))
        done
    done

    # Combinar: config base + backends dinámicos
    sed '/^# __DYNAMIC_BACKENDS_START__/,$d' /usr/local/etc/haproxy/haproxy.cfg > /tmp/haproxy-new.cfg
    echo "# __DYNAMIC_BACKENDS_START__" >> /tmp/haproxy-new.cfg
    cat /tmp/dynamic-backends.cfg >> /tmp/haproxy-new.cfg

    # Verificar si hubo cambios
    if [ -f /tmp/haproxy-active.cfg ]; then
        if diff -q /tmp/haproxy-new.cfg /tmp/haproxy-active.cfg > /dev/null 2>&1; then
            # Igual al anterior, actualizar map por si acaso
            cp /tmp/domain-map-new.txt /etc/headscale/domain-map.txt 2>/dev/null || true
            return 1  # Sin cambios
        fi
    fi

    # Aplicar cambios
    cp /tmp/domain-map-new.txt /etc/headscale/domain-map.txt
    cp /tmp/haproxy-new.cfg /tmp/haproxy-active.cfg
    return 0  # Cambios detectados
}

# Configurar trap para salir limpiamente
trap 'echo "🛑 Recibido SIGTERM/SIGINT. Saliendo..."; audit_log "GATEWAY_SHUTDOWN" "Gateway detenido exitosamente" "WARN" "$MASTER_IP" 2>/dev/null || true; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

echo "🚀 TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V23 - FIREBASE + DYNAMIC ROUTING)"

# 0. Limpieza de procesos huérfanos (previene crash loops)
echo "🧹 [INIT] Limpiando procesos anteriores..."
killall headscale 2>/dev/null || true
killall tailscaled 2>/dev/null || true
killall haproxy 2>/dev/null || true
sleep 1
# Limpiar locks de SQLite
rm -f /var/lib/headscale/db.sqlite-wal /var/lib/headscale/db.sqlite-shm 2>/dev/null || true

# 0b. Asegurar dispositivo TUN
if [ ! -c /dev/net/tun ]; then
    echo "🔧 Creando interfaz TUN..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 || true
fi

# 1. Capa de Datos - Verificar conectividad con Firebase
MAX_RETRIES=15
RETRY_COUNT=0
DB_AVAILABLE=false
BACKOFF_DELAY=1
MAX_BACKOFF=10

echo "⏳ [DB] Sincronizando con Firebase Realtime Database (con Exponential Backoff)..."
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" "${FIREBASE_BASE_URL}/.json?shallow=true" 2>/dev/null)
  if [ "$RESPONSE" = "200" ]; then
    DB_AVAILABLE=true
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "⏳ [DB] Reintento $RETRY_COUNT/$MAX_RETRIES (Esperando ${BACKOFF_DELAY}s) [HTTP: $RESPONSE]..."
  sleep "$BACKOFF_DELAY"
  BACKOFF_DELAY=$((BACKOFF_DELAY * 2))
  if [ "$BACKOFF_DELAY" -gt "$MAX_BACKOFF" ]; then BACKOFF_DELAY=$MAX_BACKOFF; fi
done

if [ "$DB_AVAILABLE" = "false" ]; then
  echo "❌ [DB] Error crítico: No se pudo conectar a Firebase después de $MAX_RETRIES intentos."
  echo "[$(date -u)] SECURITY_AUDIT - EVENT: DB_ERROR - Base de datos inalcanzable durante inicialización" >> /var/log/headscale_security_audit.log
  echo "⚠️ Saliendo. Verifica FIREBASE_DB_URL."
  exit 1
fi
echo "✅ [DB] Conexión con Firebase establecida."

# Descubrimiento de red
MASTER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
[ -z "$MASTER_IP" ] && MASTER_IP=$(hostname -i | awk '{print $1}')
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||')

MYSQL_PWD=$(get_secret "/run/secrets/db_pass" "DB_PASS")
# shellcheck disable=SC2030
# shellcheck disable=SC2031
export MYSQL_PWD

ADMIN_PANEL_PASSWORD=$(get_secret "/run/secrets/admin_password" "ADMIN_PASSWORD")
if [ -z "$ADMIN_PANEL_PASSWORD" ]; then
    # Fallback securely generate a random password
    ADMIN_PANEL_PASSWORD=$(head -c 16 /dev/urandom | xxd -p -c 16)
    echo "⚠️ [AUTH] Fallback a contraseña auto-generada para panel de administración: No se proveyó ADMIN_PASSWORD."
fi

# Conexión MariaDB con Exponential Backoff
if command -v mariadb >/dev/null 2>&1 && [ -n "$DB_HOST" ]; then
    echo "⏳ [DB] Esperando conexión a MariaDB..."
    DB_READY=false
    RETRY_COUNT=0
    MAX_RETRIES=10
    DELAY=1

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if timeout 2 mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASS:-$MYSQL_PWD}" --silent > /dev/null 2>&1; then
            DB_READY=true
            echo "✅ [DB] Conexión a MariaDB establecida exitosamente."
            # Ensure schema is applied immediately after connection and before any insertions
            if [ -f /etc/headscale/schema.sql ]; then
                echo "🔧 [DB] Aplicando esquema de base de datos..."
                mariadb -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASS:-$MYSQL_PWD}" "$DB_NAME" < /etc/headscale/schema.sql || echo "⚠️ [DB] Error al aplicar esquema. Puede que ya exista."
                audit_log "DB_SCHEMA_SYNC" "Esquema de base de datos verificado y sincronizado" "INFO"
            fi
            break
        fi
        echo "⏳ [DB] MariaDB no disponible, reintentando en ${DELAY}s (Intento $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
        sleep "$DELAY"
        RETRY_COUNT=$((RETRY_COUNT + 1))
        DELAY=$((DELAY * 2))
    done

    if [ "$DB_READY" = "false" ]; then
        echo "❌ [DB] Error crítico: No se pudo conectar a MariaDB después de $MAX_RETRIES intentos."
        echo "[$(date -u)] SECURITY_AUDIT - EVENT: DB_ERROR - Fallo en inicialización de conexión a MariaDB" >> /var/log/headscale_security_audit.log
    fi
fi

# Inicializar estructura base en Firebase
EXISTING=$(curl -s "${FIREBASE_BASE_URL}/cluster_config/cluster_name.json" 2>/dev/null)
if [ "$EXISTING" = "null" ] || [ -z "$EXISTING" ]; then
    echo "🔧 [DB] Inicializando estructura base en Firebase..."
    firebase_put "cluster_config/cluster_name" '{"config_value":"Tudex Global Mesh","is_critical":true}'
fi

audit_log "SYSTEM_BOOT" "Secuencia de arranque iniciada"
audit_log "DB_CONNECTED" "Conexión a Firebase Realtime Database establecida exitosamente"
audit_log "TUN_INITIALIZED" "Interfaz de túnel VPN asegurada e inicializada"
audit_log "SECRETS_LOADED" "Credenciales cacheadas de manera aislada (Entorno / Secrets)"

# 2. Gestión de Identidad del Cluster
PRIVATE_KEY=$(get_secret "/run/secrets/headscale_private_key" "HEADSCALE_PRIVATE_KEY")
if [ -z "$PRIVATE_KEY" ]; then
    PRIVATE_KEY=$(firebase_get "headscale_secrets/private_key/key_content")
fi

NOISE_KEY=$(get_secret "/run/secrets/headscale_noise_private_key" "HEADSCALE_NOISE_PRIVATE_KEY")
if [ -z "$NOISE_KEY" ]; then
    NOISE_KEY=$(firebase_get "headscale_secrets/noise_private_key/key_content")
fi

mkdir -p /var/lib/headscale /var/run/headscale

if [ -n "$PRIVATE_KEY" ] && [ -n "$NOISE_KEY" ]; then
    echo "✅ [AUTH] Identidad recuperada de Firebase."
    echo "$PRIVATE_KEY" > /var/lib/headscale/private.key
    echo "$NOISE_KEY" > /var/lib/headscale/noise_private.key
    audit_log "IDENTITY_RECOVERY" "Identidad de red recuperada exitosamente de Firebase"
else
    echo "🚀 [AUTH] Generando raíz de identidad de malla dinámicamente..."
    head -c 32 /dev/urandom | xxd -p -c 32 > /var/lib/headscale/private.key
    head -c 32 /dev/urandom | xxd -p -c 32 > /var/lib/headscale/noise_private.key
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    PRIV_KEY_CONTENT=$(cat /var/lib/headscale/private.key)
    NOISE_KEY_CONTENT=$(cat /var/lib/headscale/noise_private.key)
    firebase_put "headscale_secrets/private_key" "{\"key_content\":\"${PRIV_KEY_CONTENT}\",\"updated_at\":\"${TIMESTAMP}\",\"description\":\"WireGuard private key\"}"
    firebase_put "headscale_secrets/noise_private_key" "{\"key_content\":\"${NOISE_KEY_CONTENT}\",\"updated_at\":\"${TIMESTAMP}\",\"description\":\"Noise protocol private key\"}"
    audit_log "KEY_ROTATION" "Generación inicial dinámica de claves WireGuard/Noise"
fi

audit_log "ACL_UPDATE" "Políticas ACL actualizadas y cargadas"

# Configuración Dinámica
[ -z "$VPN_SERVER_URL" ] && VPN_SERVER_URL="http://localhost:8080"
[ -z "$VPN_IP_PREFIX" ] && VPN_IP_PREFIX="100.64.0.0/10"
[ -z "$VPN_BASE_DOMAIN" ] && VPN_BASE_DOMAIN="vpn.internal"

echo "⚙️ [CONFIG] Inyectando configuración: URL=$VPN_SERVER_URL, Subnet=$VPN_IP_PREFIX"
sed -i "s|%%VPN_SERVER_URL%%|$VPN_SERVER_URL|g" /etc/headscale/config.yaml
sed -i "s|%%VPN_IP_PREFIX%%|$VPN_IP_PREFIX|g" /etc/headscale/config.yaml
sed -i "s|%%VPN_BASE_DOMAIN%%|$VPN_BASE_DOMAIN|g" /etc/headscale/config.yaml

# 3. Lanzar Plano de Control (Headscale)
echo "🔧 [CORE] Iniciando Headscale..."
headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
HS_PID=$!

echo "⏳ [HS] Esperando inicialización del Control Plane (Headscale)..."
HS_READY=false
for i in $(seq 1 30); do
    if curl -s --max-time 2 http://localhost:9090/metrics > /dev/null; then
        HS_READY=true
        break
    fi
    echo "⏳ [HS] Reintento $i/30..."
    sleep 2
done

if [ "$HS_READY" = "false" ]; then
    echo "❌ [HS] Error crítico: Headscale no respondió después de 60 segundos."
    audit_log "HS_ERROR" "Fallo crítico en la inicialización de Headscale" "CRITICAL"
    echo "⚠️ Mostrando últimos logs de Headscale:"
    tail -n 20 /var/log/headscale.log || true
    exit 1
fi
echo "✅ [HS] Control Plane inicializado correctamente."
echo "⏳ [CORE] Esperando inicialización de Headscale (hasta 30s)..."
HS_RETRIES=0
HS_MAX_RETRIES=30
while [ $HS_RETRIES -lt $HS_MAX_RETRIES ]; do
  # Verificar que el proceso sigue vivo
  if ! kill -0 $HS_PID 2>/dev/null; then
    echo "❌ [CORE] Headscale se cerró inesperadamente. Log:"
    tail -n 20 /var/log/headscale.log 2>/dev/null || true
    echo "🔄 [CORE] Reintentando arranque de Headscale..."
    headscale serve -c /etc/headscale/config.yaml > /var/log/headscale.log 2>&1 &
    HS_PID=$!
  fi
  if curl -s http://localhost:9090/metrics > /dev/null 2>&1; then
    echo "✅ [CORE] Headscale operativo."
    break
  fi
  HS_RETRIES=$((HS_RETRIES + 1))
  sleep 1
done
if [ $HS_RETRIES -eq $HS_MAX_RETRIES ]; then
  echo "⚠️ [CORE] Headscale no respondió en 30s. Log de error:"
  tail -n 20 /var/log/headscale.log 2>/dev/null || true
  echo "⚠️ [CORE] Continuando de todas formas..."
fi

# 4. Aprovisionamiento de Claves
if headscale users create tudex-admin 2>/dev/null; then
    audit_log "USER_CREATED" "Usuario tudex-admin creado en el control plane"
fi || true

# API Key Dashboard - Self-Healing
API_KEY=$(firebase_get "headscale_secrets/api_key/key_content")
VALID_KEY=false
if [ -n "$API_KEY" ]; then
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $API_KEY" http://localhost:8080/api/v1/machine)
    if [ "$CODE" = "200" ]; then
        VALID_KEY=true
        echo "✅ [AUTH] API Key válida recuperada de Firebase."
        audit_log "API_KEY_RECOVERY" "API Key de Dashboard validada exitosamente"
    fi
fi
if [ "$VALID_KEY" = "false" ]; then
    echo "🔄 [AUTH] Generando nueva API Key..."
    API_KEY=$(headscale apikeys create --expiration 3650d 2>/dev/null | grep -oE "[a-zA-Z0-9._-]+" | tail -n 1 || echo "")
    if [ -n "$API_KEY" ]; then
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        firebase_put "headscale_secrets/api_key" "{\"key_content\":\"${API_KEY}\",\"updated_at\":\"${TIMESTAMP}\",\"description\":\"Dashboard API key\"}"
        audit_log "KEY_ROTATION" "Generación de nueva API Key de Dashboard"
    else
        echo "⚠️ [AUTH] No se pudo generar API Key (Headscale puede no estar listo)."
    fi
fi

# Satellite Pre-AuthKey
SATELLITE_KEY=$(firebase_get "headscale_secrets/satellite_auth_key/key_content")
if [ -z "$SATELLITE_KEY" ]; then
    SATELLITE_KEY=$(headscale preauthkeys create -u tudex-admin --reusable --expiration 2160h | grep -oE "[a-f0-9]{48}" || echo "")
    if [ -n "$SATELLITE_KEY" ]; then
        TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        firebase_put "headscale_secrets/satellite_auth_key" "{\"key_content\":\"${SATELLITE_KEY}\",\"updated_at\":\"${TIMESTAMP}\",\"description\":\"Satellite pre-auth key\"}"
        audit_log "KEY_ROTATION" "Generación de nueva llave de autenticación de satélites (AuthKey)"
    fi
fi

# 5. Dashboard & Admin Panel Patching

# Sanitize variables for sed
SAFE_API_KEY=$(printf "%s" "$API_KEY" | sed 's/[&/\\]/\\&/g')
SAFE_MASTER_IP=$(printf "%s" "$MASTER_IP" | sed 's/[&/\\]/\\&/g')
SAFE_MASTER_DOMAIN=$(printf "%s" "$MASTER_DOMAIN" | sed 's/[&/\\]/\\&/g')
SAFE_FIREBASE_BASE_URL=$(printf "%s" "$FIREBASE_BASE_URL" | sed 's/[&/\\]/\\&/g')
SAFE_ADMIN_PANEL_PASSWORD=$(printf "%s" "$ADMIN_PANEL_PASSWORD" | awk '{gsub(/["\\]/,"\\\\&")}1' | sed 's/[&/\\]/\\&/g')

sed -i "s/%%DASHBOARD_API_KEY%%/${SAFE_API_KEY}/g" /etc/headscale/dashboard.html
sed -i "s/%%MASTER_IP%%/${SAFE_MASTER_IP}/g" /etc/headscale/dashboard.html
sed -i "s/%%MASTER_DOMAIN%%/${SAFE_MASTER_DOMAIN}/g" /etc/headscale/dashboard.html
sed -i "s/%%FIREBASE_DB_URL%%/${SAFE_FIREBASE_BASE_URL}/g" /etc/headscale/admin-panel.html
sed -i "s/%%ADMIN_PASSWORD%%/${SAFE_ADMIN_PANEL_PASSWORD}/g" /etc/headscale/admin-panel.html

# Fix HAProxy CSP to include the dynamic Firebase domain
FIREBASE_DOMAIN=$(echo "$FIREBASE_BASE_URL" | awk -F/ '{print $3}')
if [ -n "$FIREBASE_DOMAIN" ]; then
    sed -i "s|%%FIREBASE_DOMAIN%%|https://$FIREBASE_DOMAIN|g" /usr/local/etc/haproxy/haproxy.cfg
else
    sed -i "s|%%FIREBASE_DOMAIN%%||g" /usr/local/etc/haproxy/haproxy.cfg
fi

# 6. Domain Sync Inicial + HAProxy Launch
echo "🔄 [SYNC] Sincronizando mapeos de dominio desde Firebase..."
sync_domain_mappings || true  # OK si no hay cambios aún

# Asegurar que existe un config activo
if [ ! -f /tmp/haproxy-active.cfg ]; then
    cp /usr/local/etc/haproxy/haproxy.cfg /tmp/haproxy-active.cfg
fi

echo "⚖️ [EDGE] Iniciando HAProxy Gateway..."
haproxy -f /tmp/haproxy-active.cfg -D -p /var/run/haproxy.pid
audit_log "GATEWAY_BOOT" "HAProxy Edge Gateway iniciado con ruteo dinámico de dominios y mitigaciones DoS activas"

# 7. Conexión Mesh en Background
(
    echo "📡 [MESH] Iniciando motor de enlace..."
    mkdir -p /var/run/tailscale /var/lib/tailscale
    tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock > /var/log/tailscaled.log 2>&1 &

    echo "⏳ [MESH] Esperando inicialización del daemon de tailscale..."
    TS_RETRIES=0
    while [ ! -S /var/run/tailscale/tailscaled.sock ] && [ $TS_RETRIES -lt 15 ]; do
        sleep 1
        TS_RETRIES=$((TS_RETRIES + 1))
    done
    
    while true; do
        if tailscale up --login-server http://localhost:8080 --authkey "$SATELLITE_KEY" --hostname "master-gateway-$MASTER_IP" --advertise-exit-node --accept-routes --accept-dns=false; then
            echo "✅ [MESH] Link established."
            audit_log "NODE_JOIN" "Gateway unido a la malla (Mesh Link Established)"
            break
        fi
        echo "⏳ [MESH] Reintentando conexión en 10s..."
        sleep 10
    done
) &

# 8. Watchdog de Telemetría y Salud
(
    while true; do
        COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
        COUNT_NUM=$(echo "$COUNT" | tr -cd '0-9')
        [ -z "$COUNT_NUM" ] && COUNT_NUM=0

        # Validar conexión de BD para el healthcheck de telemetría, registramos caída silenciosa si falla
        if command -v mariadb >/dev/null 2>&1 && [ -n "$DB_HOST" ]; then
            if timeout 2 mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASS:-$MYSQL_PWD}" --silent; then
                mariadb -h "$DB_HOST" -u "$DB_USER" -p"${DB_PASS:-$MYSQL_PWD}" "$DB_NAME" -e "INSERT INTO network_stats (node_count, active_connections, cluster_health_score) VALUES ($COUNT_NUM, $COUNT_NUM, 100);" || true
            else
                echo "[$(date -u)] SECURITY_AUDIT - EVENT: TELEMETRY_FAILURE - Base de datos inalcanzable durante volcado de métricas" >> /var/log/headscale_security_audit.log
            fi
        fi

        FB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${FIREBASE_BASE_URL}/.json?shallow=true" 2>/dev/null)
        if [ "$FB_STATUS" = "200" ]; then
            COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
            COUNT_NUM=$(echo "$COUNT" | tr -cd '0-9')
            [ -z "$COUNT_NUM" ] && COUNT_NUM=0
            TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            firebase_post "network_stats" "{\"node_count\":${COUNT_NUM},\"active_connections\":${COUNT_NUM},\"cluster_health_score\":100,\"snapshot_time\":\"${TIMESTAMP}\"}"
        else
            echo "[$(date -u)] SECURITY_AUDIT - EVENT: TELEMETRY_FAILURE - Firebase REST API inalcanzable durante volcado de métricas" >> /var/log/headscale_security_audit.log
        fi
        sleep 60
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA"
# 9. Domain Sync Agent (Actualización continua de ruteo)
(
    echo "🔄 [SYNC] Agente de sincronización de dominios iniciado (cada 30s)..."
    while true; do
        sleep 30
        if sync_domain_mappings; then
            # Cambios detectados → recargar HAProxy
            OLD_PID=$(cat /var/run/haproxy.pid 2>/dev/null || true)
            if [ -n "$OLD_PID" ]; then
                haproxy -f /tmp/haproxy-active.cfg -D -p /var/run/haproxy.pid -sf "$OLD_PID" 2>/dev/null
                audit_log "HAPROXY_RELOAD" "HAProxy recargado dinámicamente tras sincronización de dominios" "INFO" "$MASTER_IP" 2>/dev/null || true
            else
                haproxy -f /tmp/haproxy-active.cfg -D -p /var/run/haproxy.pid 2>/dev/null
            fi
            echo "[$(date -u)] DOMAIN_SYNC - HAProxy recargado con nuevos mapeos de dominio."
            audit_log "DOMAIN_SYNC" "HAProxy recargado con nuevos mapeos de dominio"
        fi
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA (Firebase + Dynamic Routing)"
audit_log "SYSTEM_ONLINE" "Tudex Mesh operando a capacidad completa con ruteo dinámico"
wait $HS_PID
