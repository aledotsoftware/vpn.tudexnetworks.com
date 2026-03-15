#!/bin/bash
set -e

echo "🚀 [TEST] Iniciando validación de infraestructura Tudex Mesh..."

# 1. Shellcheck
echo "🔧 [TEST] Validando entrypoint con Shellcheck..."
if command -v shellcheck &> /dev/null; then
    shellcheck config/entrypoint.sh
    echo "✅ [TEST] Entrypoint validado."
else
    echo "❌ [TEST] shellcheck no encontrado. Instálalo nativamente (ej. sudo apt-get install -y shellcheck)."
    exit 1
fi

# 2. HAProxy config check
echo "⚖️ [TEST] Validando sintaxis de HAProxy..."

mkdir -p /tmp/etc/headscale/errors
cp config/errors/* /tmp/etc/headscale/errors/ 2>/dev/null || true
touch /tmp/etc/headscale/dashboard.html

if command -v haproxy &> /dev/null; then
    # Create a temporary config that points to /tmp instead of /etc for the local syntax check
    sed 's|/etc/headscale|/tmp/etc/headscale|g' config/haproxy.cfg > /tmp/haproxy_test.cfg

    if haproxy -c -f /tmp/haproxy_test.cfg &> /dev/null; then
        echo "✅ [TEST] HAProxy config correcta."
    else
        echo "❌ [TEST] Error en HAProxy config."
        haproxy -c -f /tmp/haproxy_test.cfg
        exit 1
    fi
else
    echo "❌ [TEST] haproxy no encontrado. Instálalo nativamente (ej. sudo apt-get install -y haproxy) para evitar límites de descarga de Docker Hub en pruebas."
    exit 1
fi

# 3. Validar YAML linting
echo "📝 [TEST] Validando sintaxis de archivos YAML..."
if command -v yamllint &> /dev/null; then
    if yamllint .; then
        echo "✅ [TEST] Todos los archivos YAML pasaron la validación."
    else
        echo "❌ [TEST] Se encontraron errores de linting en los archivos YAML."
        exit 1
    fi
else
    echo "❌ [TEST] yamllint no encontrado. Instálalo nativamente (ej. sudo apt-get install -y yamllint)."
    exit 1
fi

# 4. Docker Compose config
echo "🐳 [TEST] Validando Docker Compose..."
if docker compose config -q; then
    echo "✅ [TEST] Docker Compose válido."
else
    echo "❌ [TEST] Docker Compose config inválido."
    exit 1
fi

echo "🎉 [TEST] Todos los tests pasaron exitosamente."
