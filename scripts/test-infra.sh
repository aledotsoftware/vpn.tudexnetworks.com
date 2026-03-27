#!/bin/bash
set -e

echo "🚀 [TEST] Iniciando validación de infraestructura Tudex Mesh..."

# 1. Shellcheck
echo "🔧 [TEST] Validando entrypoint con Shellcheck..."
if command -v shellcheck &> /dev/null; then
    shellcheck config/entrypoint.sh
    echo "✅ [TEST] Entrypoint validado (nativo)."
else
    echo "⚠️ [TEST] shellcheck nativo no encontrado. Usando fallback de Docker..."
    if docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable /mnt/config/entrypoint.sh; then
        echo "✅ [TEST] Entrypoint validado (Docker fallback)."
    else
        echo "❌ [TEST] Error en validación de shellcheck."
        exit 1
    fi
fi

# 2. HAProxy config check
echo "⚖️ [TEST] Validando sintaxis de HAProxy..."

mkdir -p /tmp/etc/headscale/errors
cp config/errors/* /tmp/etc/headscale/errors/ 2>/dev/null || true
touch /tmp/etc/headscale/dashboard.html

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
    echo "⚠️ [TEST] haproxy nativo no encontrado. Usando fallback de Docker..."
    # Map /tmp directory into container to allow validation against the mock paths
    if docker run --rm -v /tmp:/tmp haproxy:latest haproxy -c -f /tmp/haproxy_test.cfg &> /dev/null; then
        echo "✅ [TEST] HAProxy config correcta (Docker fallback)."
    else
        echo "❌ [TEST] Error en HAProxy config."
        docker run --rm -v /tmp:/tmp haproxy:latest haproxy -c -f /tmp/haproxy_test.cfg
        exit 1
    fi
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
    echo "⚠️ [TEST] yamllint nativo no encontrado. Usando fallback de Docker..."
    if docker run --rm -v "$PWD:/data" cytopia/yamllint .; then
        echo "✅ [TEST] Todos los archivos YAML pasaron la validación (Docker fallback)."
    else
        echo "❌ [TEST] Se encontraron errores de linting en los archivos YAML."
        exit 1
    fi
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
