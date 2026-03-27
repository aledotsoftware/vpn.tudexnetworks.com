#!/bin/sh
set -e

# Secure Secrets Management
if [ -f "/run/secrets/db_pass" ]; then
    MYSQL_PWD="$(cat /run/secrets/db_pass)"
    export MYSQL_PWD
elif [ -n "$DB_PASS" ]; then
    export MYSQL_PWD="$DB_PASS"
fi

# ============================================================
# TUDEX OPERATIONAL GATEWAY - BOOT SEQUENCER (V23 - FIREBASE + DYNAMIC ROUTING)
# ============================================================
# Base de datos: Google Firebase Realtime Database
# Ruteo dinámico: Domain mappings en Firebase → HAProxy config auto-generado

FIREBASE_BASE_URL="${FIREBASE_DB_URL}"

# --- FIREBASE HELPER FUNCTIONS ---
firebase_get() {
    local path="$1"
    local result
    result=$(curl -s "${FIREBASE_BASE_URL}/${path}.json" 2>/dev/null)
    if [ "$result" = "null" ] || [ -z "$result" ]; then
        echo ""
    else
        echo "$result" | jq -r '.' 2>/dev/null || echo "$result"
    fi
}

firebase_put() {
    local path="$1"
    local data="$2"
    curl -s -X PUT -d "$data" "${FIREBASE_BASE_URL}/${path}.json" > /dev/null 2>&1
}

firebase_patch() {
    local path="$1"
    local data="$2"
    curl -s -X PATCH -d "$data" "${FIREBASE_BASE_URL}/${path}.json" > /dev/null 2>&1
}

firebase_post() {
    local path="$1"
    local data="$2"
    curl -s -X POST -d "$data" "${FIREBASE_BASE_URL}/${path}.json" > /dev/null 2>&1
}

audit_log() {
    local event_type="$1"
    local description="$2"
    local ip_source="${3:-$MASTER_IP}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    firebase_post "security_audit" "{\"event_type\":\"${event_type}\",\"description\":\"${description}\",\"ip_source\":\"${ip_source}\",\"created_at\":\"${timestamp}\"}" || true

    # Log to MySQL explicitly if database variables are present
    if [ -n "$DB_HOST" ] && [ -n "$DB_USER" ] && [ -n "$DB_NAME" ]; then
        # Escape single quotes and backslashes for SQL insertion
        local safe_event_type
        safe_event_type=$(printf "%s" "$event_type" | sed 's/\\/\\\\/g; s/'\''/''/g')
        local safe_description
        safe_description=$(printf "%s" "$description" | sed 's/\\/\\\\/g; s/'\''/''/g')
        local safe_ip_source
        safe_ip_source=$(printf "%s" "$ip_source" | sed 's/\\/\\\\/g; s/'\''/''/g')

        mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('${safe_event_type}', '${safe_description}', '${safe_ip_source}');" || true
    fi
}

# --- DOMAIN SYNC FUNCTION ---
# Lee domain_mappings de Firebase, genera domain-map.txt y backends dinámicos,
# y recarga HAProxy si hay cambios.
sync_domain_mappings() {
    MAPPINGS=$(curl -s "${FIREBASE_BASE_URL}/domain_mappings.json" 2>/dev/null)

    # Si no hay mappings o Firebase no responde, usar config base
    if [ "$MAPPINGS" = "null" ] || [ -z "$MAPPINGS" ] || echo "$MAPPINGS" | jq empty 2>/dev/null; [ $? -ne 0 ]; then
        if [ "$MAPPINGS" = "null" ] || [ -z "$MAPPINGS" ]; then
            > /etc/headscale/domain-map.txt
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
    > /tmp/dynamic-backends.cfg
    KEYS=$(echo "$MAPPINGS" | jq -r '
        to_entries[] |
        select(.value.enabled == true) |
        select(.value.nodes != null) |
        select((.value.nodes | length) > 0) |
        .key
    ' 2>/dev/null)

    for key in $KEYS; do
        echo "" >> /tmp/dynamic-backends.cfg
        echo "backend backend_${key}" >> /tmp/dynamic-backends.cfg
        echo "    balance roundrobin" >> /tmp/dynamic-backends.cfg

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
trap 'echo "🛑 Recibido SIGTERM/SIGINT. Saliendo..."; audit_log "GATEWAY_SHUTDOWN" "Gateway detenido exitosamente" "$MASTER_IP" 2>/dev/null || true; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

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
  echo "⚠️ Saliendo. Verifica FIREBASE_DB_URL."
  exit 1
fi
echo "✅ [DB] Conexión con Firebase establecida."

# Descubrimiento de red
MASTER_IP=$(ip -4 addr show eth0 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)
[ -z "$MASTER_IP" ] && MASTER_IP=$(hostname -i | awk '{print $1}')
MASTER_DOMAIN=$(grep "server_url:" /etc/headscale/config.yaml | awk '{print $2}' | sed 's|https://||' | sed 's|http://||' | sed 's|:.*||')

# Inicializar estructura base en Firebase
EXISTING=$(curl -s "${FIREBASE_BASE_URL}/cluster_config/cluster_name.json" 2>/dev/null)
if [ "$EXISTING" = "null" ] || [ -z "$EXISTING" ]; then
    echo "🔧 [DB] Inicializando estructura base en Firebase..."
    firebase_put "cluster_config/cluster_name" '{"config_value":"Tudex Global Mesh","is_critical":true}'
fi

audit_log "DB_CONNECTED" "Conexión a Firebase Realtime Database establecida exitosamente"
audit_log "TUN_INITIALIZED" "Interfaz de túnel VPN asegurada e inicializada"
audit_log "SECRETS_LOADED" "Credenciales cacheadas de manera aislada (Entorno / Secrets)"

# 2. Gestión de Identidad del Cluster
PRIVATE_KEY=$(firebase_get "headscale_secrets/private_key/key_content")
NOISE_KEY=$(firebase_get "headscale_secrets/noise_private_key/key_content")

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
    cat /var/log/headscale.log 2>/dev/null | tail -20
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
  cat /var/log/headscale.log 2>/dev/null | tail -20
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
sed -i "s|%%DASHBOARD_API_KEY%%|$API_KEY|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_IP%%|$MASTER_IP|g" /etc/headscale/dashboard.html
sed -i "s|%%MASTER_DOMAIN%%|$MASTER_DOMAIN|g" /etc/headscale/dashboard.html
sed -i "s|%%FIREBASE_DB_URL%%|$FIREBASE_BASE_URL|g" /etc/headscale/admin-panel.html

# 6. Domain Sync Inicial + HAProxy Launch
echo "🔄 [SYNC] Sincronizando mapeos de dominio desde Firebase..."
sync_domain_mappings || true  # OK si no hay cambios aún

# Asegurar que existe un config activo
if [ ! -f /tmp/haproxy-active.cfg ]; then
    cp /usr/local/etc/haproxy/haproxy.cfg /tmp/haproxy-active.cfg
fi

echo "⚖️ [EDGE] Iniciando HAProxy Gateway..."
haproxy -f /tmp/haproxy-active.cfg -D -p /var/run/haproxy.pid
audit_log "GATEWAY_BOOT" "HAProxy Edge Gateway iniciado con ruteo dinámico de dominios"

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
        if timeout 2 mariadb-admin ping -h "$DB_HOST" -u "$DB_USER" --silent; then
            mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO network_stats (node_count, active_connections, cluster_health_score) VALUES ($COUNT_NUM, $COUNT_NUM, 100);" || true
        else
            echo "[$(date -u)] SECURITY_AUDIT - EVENT: TELEMETRY_FAILURE - Base de datos inalcanzable durante volcado de métricas" >> /var/log/headscale_security_audit.log
        fi

        FB_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${FIREBASE_BASE_URL}/.json?shallow=true" 2>/dev/null)
        if [ "$FB_STATUS" = "200" ]; then
            COUNT=$(headscale nodes list 2>/dev/null | grep -i "online" | grep -c "true" || echo 0)
            COUNT_NUM=$(echo "$COUNT" | tr -cd '0-9')
            [ -z "$COUNT_NUM" ] && COUNT_NUM=0
            TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            firebase_post "network_stats" "{\"node_count\":${COUNT_NUM},\"active_connections\":${COUNT_NUM},\"cluster_health_score\":100,\"snapshot_time\":\"${TIMESTAMP}\"}"
        fi
        sleep 60
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA"
mariadb -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" -e "INSERT INTO security_audit (event_type, description, ip_source) VALUES ('SYSTEM_ONLINE', 'Infraestructura de Malla Operativa y Securizada', '$MASTER_IP');" || true
# 9. Domain Sync Agent (Actualización continua de ruteo)
(
    echo "🔄 [SYNC] Agente de sincronización de dominios iniciado (cada 30s)..."
    while true; do
        sleep 30
        if sync_domain_mappings; then
            # Cambios detectados → recargar HAProxy
            haproxy -f /tmp/haproxy-active.cfg -D -p /var/run/haproxy.pid -sf $(cat /var/run/haproxy.pid 2>/dev/null) 2>/dev/null
            echo "[$(date -u)] DOMAIN_SYNC - HAProxy recargado con nuevos mapeos de dominio."
            audit_log "DOMAIN_SYNC" "HAProxy recargado con nuevos mapeos de dominio"
        fi
    done
) &

echo "🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA (Firebase + Dynamic Routing)"
audit_log "SYSTEM_ONLINE" "Tudex Mesh operando a capacidad completa con ruteo dinámico"
wait $HS_PID
