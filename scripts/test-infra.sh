#!/bin/bash
set -euo pipefail

echo "🚀 [TEST] Iniciando validación de infraestructura Tudex Mesh..."

# 1. Shellcheck
echo "🔧 [TEST] Validando entrypoint con Shellcheck..."
if command -v shellcheck &> /dev/null; then
    shellcheck config/entrypoint.sh
    echo "✅ [TEST] Entrypoint validado (nativo)."
else
    echo "❌ [TEST] shellcheck nativo no encontrado. Por favor instálalo para continuar (sudo apt-get install shellcheck)."
    exit 1
fi

# 2. HAProxy config check
echo "⚖️ [TEST] Validando sintaxis de HAProxy..."

mkdir -p /tmp/etc/headscale/errors
cp config/errors/* /tmp/etc/headscale/errors/ 2>/dev/null || true
echo "<html><body>dashboard</body></html>" > /tmp/etc/headscale/dashboard.html
echo "<html><body>admin</body></html>" > /tmp/etc/headscale/admin-panel.html
touch /tmp/etc/headscale/domain-map.txt

# Create a temporary config that points to /tmp instead of /etc for the local syntax check
sed 's|/etc/headscale|/tmp/etc/headscale|g' config/haproxy.cfg > /tmp/haproxy_test.cfg

if command -v haproxy &> /dev/null; then
    if haproxy -c -f /tmp/haproxy_test.cfg &> /dev/null; then
        echo "✅ [TEST] HAProxy config correcta (nativo)."
    else
        echo "❌ [TEST] Error en HAProxy config."
        haproxy -c -f /tmp/haproxy_test.cfg
        exit 1
    fi
else
    echo "❌ [TEST] haproxy nativo no encontrado. Por favor instálalo para continuar (sudo apt-get install haproxy)."
    exit 1
fi

# 3. Validar YAML linting
echo "📝 [TEST] Validando sintaxis de archivos YAML..."
if command -v yamllint &> /dev/null; then
    if yamllint .; then
        echo "✅ [TEST] Todos los archivos YAML pasaron la validación (nativo)."
    else
        echo "❌ [TEST] Se encontraron errores de linting en los archivos YAML."
        exit 1
    fi
else
    echo "❌ [TEST] yamllint nativo no encontrado. Por favor instálalo para continuar (sudo apt-get install yamllint)."
    exit 1
fi

# 4. Dockerfile linting (Hadolint)
echo "🐳 [TEST] Validando Dockerfiles con Hadolint..."
if command -v hadolint &> /dev/null; then
    hadolint Dockerfile || echo "⚠️ [TEST] Hadolint encontró advertencias en Dockerfile principal."
    if [ -f satellite/Dockerfile ]; then
        hadolint satellite/Dockerfile || echo "⚠️ [TEST] Hadolint encontró advertencias en satellite/Dockerfile."
    fi
    echo "✅ [TEST] Dockerfile linting completado (nativo)."
else
    echo "⚠️ [TEST] hadolint no encontrado. Descargándolo temporalmente para CI..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then HL_ARCH="x86_64";
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then HL_ARCH="arm64";
    else HL_ARCH="x86_64"; fi
    curl -sL -o /tmp/hadolint "https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-${HL_ARCH}"
    chmod +x /tmp/hadolint
    /tmp/hadolint Dockerfile || echo "⚠️ [TEST] Hadolint encontró advertencias en Dockerfile principal."
    if [ -f satellite/Dockerfile ]; then
        /tmp/hadolint satellite/Dockerfile || echo "⚠️ [TEST] Hadolint encontró advertencias en satellite/Dockerfile."
    fi
    echo "✅ [TEST] Dockerfile linting completado."
fi

# 5. Docker Compose config
echo "🐳 [TEST] Validando Docker Compose..."
export DB_TYPE="dummy" FIREBASE_DB_URL="dummy" FIREBASE_PROJECT_ID="dummy" FIREBASE_API_KEY="dummy" DB_HOST="dummy" DB_USER="dummy" DB_NAME="dummy" TS_AUTHKEY="dummy" VPN_IP_PREFIX_ALFA="dummy" VPN_IP_PREFIX_BETA="dummy" VPN_BASE_DOMAIN="dummy" VPN_SERVER_URL="dummy" VPN_IP_PREFIX="dummy" NODE_NAME="dummy" TS_LOGIN_SERVER="dummy"
if docker compose config -q; then
    echo "✅ [TEST] Docker Compose válido."
else
    echo "❌ [TEST] Docker Compose config inválido."
    exit 1
fi

echo "🎉 [TEST] Todos los tests pasaron exitosamente."
