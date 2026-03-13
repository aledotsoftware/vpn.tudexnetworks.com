#!/bin/bash
set -e

echo "🚀 [TEST] Iniciando validación de infraestructura Tudex Mesh..."

# 1. Shellcheck
echo "🔧 [TEST] Validando entrypoint con Shellcheck..."
if command -v shellcheck &> /dev/null; then
    shellcheck config/entrypoint.sh
    echo "✅ [TEST] Entrypoint validado."
else
    echo "⚠️ [TEST] shellcheck no encontrado, saltando."
fi

# 2. HAProxy config check
echo "⚖️ [TEST] Validando sintaxis de HAProxy..."
mkdir -p /tmp/etc/headscale
touch /tmp/etc/headscale/dashboard.html
if docker run --rm \
    -v "$(pwd)/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
    -v "/tmp/etc/headscale/dashboard.html:/etc/headscale/dashboard.html:ro" \
    -v "$(pwd)/config/errors:/etc/headscale/errors:ro" \
    haproxy:alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg &> /dev/null; then
    echo "✅ [TEST] HAProxy config correcta."
else
    echo "❌ [TEST] Error en HAProxy config."
    docker run --rm \
        -v "$(pwd)/config/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
        -v "/tmp/etc/headscale/dashboard.html:/etc/headscale/dashboard.html:ro" \
        -v "$(pwd)/config/errors:/etc/headscale/errors:ro" \
        haproxy:alpine haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
    exit 1
fi

# 3. Docker Compose config
echo "🐳 [TEST] Validando Docker Compose..."
if docker compose config -q; then
    echo "✅ [TEST] Docker Compose válido."
else
    echo "❌ [TEST] Docker Compose config inválido."
    exit 1
fi

echo "🎉 [TEST] Todos los tests pasaron exitosamente."
