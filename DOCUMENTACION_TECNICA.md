# 🛠️ ESPECIFICACIONES TÉCNICAS - TUDEX MESH

Este documento profundiza en la lógica interna y la configuración avanzada del sistema Tudex Mesh.

---

## 🛡️ 1. Lógica del Entrypoint (V22 - Firebase)

El script `/config/entrypoint.sh` es el orquestador del contenedor. Sus fases críticas son:

### Fase 0: Preparación de Red
- Verifica y crea el dispositivo `/dev/net/tun` si es necesario, permitiendo que la VPN levante en entornos restringidos.

### Fase 1: Capa de Datos (Firebase)
- Verifica conectividad con Firebase Realtime Database usando la REST API (`curl`).
- Implementa **Exponential Backoff** (hasta 15 reintentos) para tolerancia a fallos de red.
- Si no conecta después de los reintentos, el contenedor sale con error para que Docker lo reinicie.

### Fase 2: Gestión de Identidad del Cluster
- Se conecta a **Firebase Realtime Database** mediante funciones helper de la REST API.
- Si encuentra llaves en Firebase (`headscale_secrets/private_key` y `noise_private_key`), las inyecta en el sistema local.
- Si no existen, genera nuevas claves con `/dev/urandom` y las almacena en Firebase.
- Esto permite que **múltiples Gateways actúen como la misma entidad** → Alta Disponibilidad (HA).

### Fase 3: Control Plane (Headscale)
- Lanza Headscale con la configuración inyectada dinámicamente.
- Espera hasta 15 segundos a que el servicio responda en el puerto de métricas (9090).

### Fase 4: Self-Healing API Keys
- Valida si la clave de API guardada en Firebase sigue siendo funcional contra el motor local (`HTTP 200`).
- Si detecta un error `401 Unauthorized`, regenera la clave automáticamente y la guarda en Firebase.
- Actualiza el Dashboard para evitar interrupciones en la monitorización.

### Fase 5: Dashboard Patching
- Reemplaza variables dinámicas (`%%DASHBOARD_API_KEY%%`, `%%MASTER_IP%%`, `%%MASTER_DOMAIN%%`) en el HTML del dashboard.

### Fase 6: HAProxy Edge Gateway
- Inicia HAProxy como balanceador de carga en modo daemon.
- Se ejecuta **antes** de la conexión mesh para evitar bloqueos.

### Fase 7: Auto-Mesh Enlace
- Tailscale se levanta en segundo plano con reintentos infinitos.
- El Gateway se registra como "Master Gateway" y se marca como **Exit Node**.

### Fase 8: Watchdog de Telemetría
- Loop cada 60 segundos que:
  - Cuenta nodos online via `headscale nodes list`.
  - Escribe estadísticas en Firebase (`network_stats/`).
  - Registra errores de conectividad en log local si Firebase no responde.

---

## 🔥 2. Firebase Realtime Database

### Estructura de Datos

```
firebase-root/
├── headscale_secrets/
│   ├── private_key/
│   │   ├── key_content: "abc123..."
│   │   ├── updated_at: "2026-03-25T04:40:00Z"
│   │   └── description: "WireGuard private key"
│   ├── noise_private_key/
│   │   ├── key_content: "def456..."
│   │   ├── updated_at: "2026-03-25T04:40:00Z"
│   │   └── description: "Noise protocol private key"
│   ├── api_key/
│   │   ├── key_content: "ghi789..."
│   │   ├── updated_at: "2026-03-25T04:40:05Z"
│   │   └── description: "Dashboard API key"
│   └── satellite_auth_key/
│       ├── key_content: "jkl012..."
│       ├── updated_at: "2026-03-25T04:40:05Z"
│       └── description: "Satellite pre-auth key"
├── security_audit/
│   └── {auto-generated-id}/
│       ├── event_type: "SYSTEM_ONLINE"
│       ├── description: "Tudex Mesh operando..."
│       ├── ip_source: "172.18.0.2"
│       └── created_at: "2026-03-25T04:40:10Z"
├── network_stats/
│   └── {auto-generated-id}/
│       ├── node_count: 3
│       ├── active_connections: 3
│       ├── cluster_health_score: 100
│       └── snapshot_time: "2026-03-25T04:41:10Z"
└── cluster_config/
    └── cluster_name/
        ├── config_value: "Tudex Global Mesh"
        └── is_critical: true
```

### Funciones Helper del Entrypoint

El entrypoint define funciones shell que abstraen la REST API de Firebase:

| Función | Método HTTP | Uso |
| :--- | :--- | :--- |
| `firebase_get "path/to/value"` | `GET` | Leer un valor (secretos, configuración) |
| `firebase_put "path" '{"key":"val"}'` | `PUT` | Escribir/reemplazar un nodo completo |
| `firebase_patch "path" '{"key":"val"}'` | `PATCH` | Actualización parcial (merge) |
| `firebase_post "path" '{"key":"val"}'` | `POST` | Insertar con ID auto-generado (audit logs, stats) |
| `audit_log "EVENT" "descripción"` | `POST` | Helper para insertar eventos de auditoría |

### Tipos de Eventos de Auditoría

| `event_type` | Cuándo se genera |
| :--- | :--- |
| `DB_CONNECTED` | Conexión exitosa a Firebase |
| `TUN_INITIALIZED` | Interfaz de túnel VPN creada |
| `SECRETS_LOADED` | Credenciales cargadas del entorno |
| `IDENTITY_RECOVERY` | Claves WireGuard recuperadas de Firebase |
| `KEY_ROTATION` | Generación de nuevas claves (WireGuard, API, Satellite) |
| `ACL_UPDATE` | Políticas ACL cargadas |
| `USER_CREATED` | Usuario `tudex-admin` creado en Headscale |
| `API_KEY_RECOVERY` | API Key validada exitosamente |
| `GATEWAY_BOOT` | HAProxy iniciado |
| `NODE_JOIN` | Gateway unido a la malla mesh |
| `SYSTEM_ONLINE` | Infraestructura completamente operativa |
| `GATEWAY_SHUTDOWN` | Gateway detenido (SIGTERM/SIGINT) |

---

## 🐳 3. Arquitectura de Contenedores

### Producción (`docker-compose.yml`)
```
┌─────────────────────────────────────────────────┐
│                tudex_mesh_net                     │
│                                                   │
│  ┌──────────────────┐  ┌────────┐  ┌────────┐   │
│  │ tudex_headscale   │  │node_01 │  │node_02 │   │
│  │  ├─ Headscale     │  │  PHP   │  │  PHP   │   │
│  │  ├─ HAProxy       │  │  App   │  │  App   │   │
│  │  ├─ Tailscale     │  └────────┘  └────────┘   │
│  │  └─ Watchdog      │                            │
│  └────────┬──────────┘                            │
│           │                                       │
└───────────┼───────────────────────────────────────┘
            │ HTTPS (REST API)
            ▼
   ┌──────────────────┐
   │  Google Firebase  │
   │  Realtime Database│
   └──────────────────┘
```

### Puertos expuestos (`tudex_headscale`)
| Puerto Host | Puerto Container | Servicio |
| :--- | :--- | :--- |
| 8081 | 80 | HAProxy Edge → Dashboard / Apps |
| 8080 | 8080 | Headscale Control Plane API |
| 8404 | 8404 | HAProxy Stats (`/stats`) |
| 41641/udp | 41641/udp | WireGuard Tunnel |

### Imagen Docker
- **Base:** `alpine:3.19` (multi-stage build)
- **Dependencias:** `haproxy`, `jq`, `curl`, `tailscale`, `iptables`, `ca-certificates`
- **Binarios:** `headscale v0.22.3` (descargado en fase builder)
- **Sin MariaDB:** Toda la comunicación con la BD es via REST API + `jq` para parsing JSON

---

## ⚖️ 4. Ruteo y Balanceo Dinámico

### HAProxy (Gateway Edge)
Configurado en `/config/haproxy.cfg`.
- Utiliza **variables de transacción** (`txn.subdomain`) para capturar el host de entrada.
- Rutea peticiones de `{app}.tudexnetworks.com` hacia `{app}.vpn.internal` de forma totalmente transparente.
- **Estadísticas:** Accesibles en `http://localhost:8404/stats` (HTML interactivo, refresh cada 5s).
- Mantiene mitigaciones anti-DoS y anti-escaneo activas.

### Traefik (Dokploy Integration)
En el `docker-compose.yml` de producción, se utilizan etiquetas específicas:
- `traefik.docker.network=dokploy-network`: Fuerza al tráfico a fluir por la red de gestión de Dokploy.
- `PathPrefix`: Separa inteligentemente el tráfico del Dashboard, la API de control y los sitios de los clientes.

---

## 🛰️ 5. Configuración de Nodos Satélites (now.tudexnetworks.com)

Los satélites son agnósticos a la infraestructura:
- **DNS:** No necesitan DNS público. Se comunican por la VPN.
- **Salida:** Al conectar con `USE_EXIT_NODE=true`, el Gateway Maestro redirige su tráfico hacia el internet público bajo una IP corporativa controlada.
- **Rendimiento:** Al exponer el puerto **UDP 41641**, los satélites establecen túneles P2P directos, eliminando el lag de servidores intermediarios.

---

## 📋 6. Troubleshooting (Resolución de Problemas)

| Síntoma | Causa Probable | Solución |
| :--- | :--- | :--- |
| **`HTTP 401` al conectar a Firebase** | Reglas de seguridad restrictivas | Firebase Console → Realtime Database → Reglas → Poner `.read: true, .write: true` → Publicar |
| **Error 401 en Dashboard** | Desfase de API Key | Reiniciar el Gateway (`docker restart tudex_headscale`). El V22 lo arreglará solo (Self-Healing). |
| **Nodos no se ven (Offline)** | Puerto 41641 bloqueado | Abrir UDP 41641 en el firewall del servidor. |
| **502 Bad Gateway** | HAProxy no ha iniciado | Verificar logs con `docker logs tudex_headscale`. |
| **Puerto 8080 devuelve 404** | Normal — la API no sirve nada en `/` | Usar la ruta completa: `http://localhost:8080/api/v1/*` con Bearer token. |
| **Puerto 8404 devuelve 503** | Ruta incorrecta | Usar `http://localhost:8404/stats` en lugar de solo `/`. |
| **Contenedor `tudex_db` huérfano** | Migración desde MySQL | `docker stop tudex_db && docker rm tudex_db` |
| **"No hay apps en tu proyecto" (Firebase)** | Normal — no se necesita app registrada para REST API | Registrar una app web solo para obtener la `apiKey`, no se necesita instalar SDK. |
| **Datos no se sincronizan** | API Key de Firebase inválida | Regenerar la API Key en Firebase Console y actualizar `.env`. |

---

## 🔄 7. Comandos Útiles

```bash
# Ver logs del gateway en tiempo real
docker logs -f tudex_headscale

# Ver estado de todos los contenedores
docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Reiniciar solo el gateway
docker restart tudex_headscale

# Reconstruir todo desde cero
docker-compose up --build -d

# Limpiar contenedores huérfanos
docker-compose up --build -d --remove-orphans

# Verificar conectividad con Firebase desde tu máquina
curl -s "https://vpn-tudexnetworks-default-rtdb.firebaseio.com/.json?shallow=true"

# Ver secretos almacenados en Firebase
curl -s "https://vpn-tudexnetworks-default-rtdb.firebaseio.com/headscale_secrets.json" | jq .

# Ver últimos eventos de auditoría
curl -s "https://vpn-tudexnetworks-default-rtdb.firebaseio.com/security_audit.json" | jq .
```

---
*Tudex Networks - Infrastructure as Code. V22 Firebase Edition.*
