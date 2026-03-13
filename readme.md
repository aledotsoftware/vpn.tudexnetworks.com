# TUDEX MESH GATEWAY 🚀

Solución de conectividad Zero-Trust de alto rendimiento para **Tudex Networks**. Este gateway orquestra una red mesh autogestionada mediante **Headscale** y proporciona balanceo de carga inteligente con **HAProxy**, integrando un panel de control premium para monitorización en tiempo real.

## 🌟 Características Principales
- **Zero-Config HA:** Sincronización automática de identidad del cluster (claves maestras) mediante MySQL.
- **Mesh Load Balancing:** HAProxy resuelve nodos dinámicamente mediante el MagicDNS interno.
- **Premium Dashboard:** Monitorización visual de nodos, tráfico y salud del cluster con estética glassmorphism.
- **Soberanía de Datos:** Control total de las claves WireGuard y la infraestructura de red.

---

## 🚦 1. Despliegue Local (Pruebas)

Para correr el entorno de desarrollo y ver el dashboard en tu Windows:

```bash
docker-compose -f docker-compose.local.yml up --build -d
```

### URLs Locales:
- **Dashboard:** [http://localhost:8081/dashboard](http://localhost:8081/dashboard)
- **HAProxy Stats:** [http://localhost:8404/stats](http://localhost:8404/stats)

---

## 📊 2. Tudex Mesh Dashboard

El panel de control es 100% dinámico y permite visualizar el estado real de la red global:

### Secciones:
1. **Nodos de la Red:** Lista dinámica de servidores unidos, mostrando sus IPs internas (`100.64.x.x`), estado (Online/Offline) y última actividad.
2. **Tráfico por Sitio:** Monitorización del volumen de peticiones que HAProxy está distribuyendo a través de la malla.
3. **Cluster Health:** Estado de salud de los gateways públicos y sincronización de secretos.

---

## 🛠️ 3. Unirse a la Red (Nodos Spokes)

Para que un servidor aparezca en el dashboard, debe unirse a la malla:

1. **Obtener clave:** Ejecuta en el gateway: `headscale users create tudex && headscale preauthkeys create -u tudex`.
2. **Configurar Nodo:** Usa las variables `TS_AUTHKEY` y `TS_LOGIN_SERVER` en el nodo cliente.

---

## 💾 4. Capa de Datos y Persistencia

El sistema utiliza un enfoque híbrido para máxima velocidad y confiabilidad:
- **Estados de Sesión (SQLite):** Headscale maneja la base de datos de nodos localmente para latencia cero.
- **Sincronización de Cluster (MySQL):** Los secretos vitales, auditoría y métricas se guardan en el "Cerebro Central" SQL.

Consulta el esquema formal en: [database/schema.sql](file:///p:/vpn.tudexnetworks.com/database/schema.sql)

---

## 🛡️ 5. Seguridad y Mantenimiento...

- **Secretos:** Las claves `private.key` y `noise_private.key` se guardan en la tabla `headscale_secrets` de MySQL. Todos los gateways con la misma DB compartirán la misma identidad de red.
- **ACLs:** Configura políticas de seguridad estrictas en `/config/acl.hujson`.


los puertos del servidor físico que deben estar abiertos:
- **TCP 80, 443:** Tráfico Web y SSL.
- **TCP 8080:** API de Control Plane.
- **TCP 8404:** Monitorización de HAProxy.
- **UDP 41641:** Túnel Wireguard de la Mesh (Crítico).
- **UDP 3478:** Servidor STUN (Opcional, ayuda a NAT).

*Tudex Networks - Engineered for Performance.*
