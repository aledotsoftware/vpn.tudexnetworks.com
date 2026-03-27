# 🌐 TUDEX MESH CONTROL SYSTEM

Solución de infraestructura de red definida por software (SDN) de nivel industrial para **Tudex Networks**. Este ecosistema orquesta una red mesh segura, resiliente y de alta disponibilidad, integrando control de tráfico inteligente y monitorización avanzada.

---

## 🏗️ Arquitectura del Ecosistema

El sistema Tudex Mesh se basa en tres pilares fundamentales:
1.  **Control Plane (Headscale):** El cerebro de la red que gestiona identidades, llaves WireGuard y MagicDNS.
2.  **Edge Routing (HAProxy + Traefik):** La puerta de entrada inteligente que rutea tráfico público hacia servicios privados de la mesh basados en subdominios.
3.  **Data Persistence (Google Firebase Realtime Database):** Sincronización global de secretos, auditoría y métricas en la nube de Google, sin necesidad de gestionar servidores de bases de datos propios.

---

## 🔥 Configuración de Firebase (Requisito Previo)

### Paso 1: Crear el proyecto
1. Ve a [Firebase Console](https://console.firebase.google.com/).
2. Crea un nuevo proyecto (ej: `vpn-tudexnetworks`).

### Paso 2: Registrar una App Web
1. En la página principal del proyecto, haz clic en el ícono **`</>`** (Web).
2. Ponle cualquier nombre (ej: "Gateway").
3. Firebase te entregará un bloque de configuración con `apiKey`, `databaseURL`, `projectId`, etc.
4. Copia esos valores — los usarás en el `.env`.

### Paso 3: Crear la Realtime Database
1. Ve a **Build → Realtime Database** en el menú lateral.
2. Haz clic en **"Crear base de datos"**.
3. Selecciona la región más cercana a tu servidor.
4. Selecciona **"Modo de prueba"** para empezar.

### Paso 4: Importar estructura inicial
1. En la vista de datos de tu Realtime Database, haz clic en los **tres puntos (⋮)**.
2. Selecciona **"Importar JSON"**.
3. Sube el archivo `database/firebase-structure.json`.

### Paso 5: Configurar reglas de acceso
Ve a la pestaña **"Reglas"** en Realtime Database y configura:
```json
{
  "rules": {
    ".read": true,
    ".write": true
  }
}
```
> ⚠️ **Nota de seguridad:** Estas reglas son para desarrollo/pruebas. Para producción, configura reglas más restrictivas basadas en autenticación.

### Paso 6: Configurar `.env`
Copia los valores de Firebase a tu archivo `.env`:
```env
DB_TYPE=firebase
FIREBASE_PROJECT_ID=vpn-tudexnetworks
FIREBASE_DB_URL=https://vpn-tudexnetworks-default-rtdb.firebaseio.com
FIREBASE_API_KEY=AIzaSy...tu_api_key...
```

---

## 🚦 Guía de Despliegue Rápido

### A. Despliegue Principal (Producción Local / Dokploy)
```bash
docker-compose up --build -d
```

#### Contenedores que se crean:
| Contenedor | Descripción |
| :--- | :--- |
| `tudex_headscale` | Gateway maestro: Headscale + HAProxy + Tailscale |
| `node_01` | Nodo satélite PHP (app) |
| `node_02` | Nodo satélite PHP (app) |

#### Puertos y URLs disponibles:
| Puerto | URL | Descripción |
| :--- | :--- | :--- |
| **8081** | [http://localhost:8081](http://localhost:8081) | 🖥️ Dashboard NOC — Panel de monitorización con gráficas y logs |
| **8080** | `http://localhost:8080/api/v1/*` | 🔌 Headscale API — Control plane (requiere Bearer token) |
| **8404** | [http://localhost:8404/stats](http://localhost:8404/stats) | 📊 HAProxy Stats — Telemetría en tiempo real del balanceador |
| **41641/udp** | — | 🔒 Túnel WireGuard nativo (P2P entre nodos) |

> **Nota:** El puerto 8080 en la raíz (`/`) devuelve 404 — es normal. La API vive en `/api/v1/*` y requiere autenticación con la API Key que el sistema genera automáticamente.

### B. Laboratorio de Alta Disponibilidad
Para testear el cluster balanceado con 2 Gateways y 2 Nodos Satélites:
```bash
docker-compose -f docker-compose.lab.yml up --build -d
```
- **Panel Alfa:** [http://localhost:8081](http://localhost:8081)
- **Panel Beta:** [http://localhost:8181](http://localhost:8181)

### C. Producción (Internet / Dokploy)
1. Sube el código a tu repo de Dokploy.
2. Configura las variables de entorno (`FIREBASE_DB_URL`, `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`) en el panel de Dokploy.
3. Asegura la apertura de puertos en tu Firewall físico/Cloud.

---

## 🔌 Puertos Requeridos (Firewall)

| Puerto | Protocolo | Descripción |
| :--- | :--- | :--- |
| **80 / 443** | TCP | Tráfico Web (HTTP/HTTPS) y Dashboard |
| **8080** | TCP | API de Control (Headscale) |
| **8404** | TCP | Estadísticas de HAProxy (Real-time Telemetry) |
| **41641** | **UDP** | **Túnel Wireguard Nativo (Crítico para rendimiento)** |
| **3478** | UDP | Soporte STUN para atravesar NAT |

---

## 🛠️ Gestión de Nodos Satélites

Los nodos (como `now.tudexnetworks.com`) están diseñados para autoconectarse:
1.  **Clave de Malla:** Al iniciar el Gateway, se genera una `SATELLITE_AUTH_KEY` que se guarda en Firebase automáticamente.
2.  **Inyección:** Los satélites leen esta clave (vía variable de entorno `VPN_AUTH_KEY`) y se unen a la red sin intervención manual.
3.  **Exit Node:** El Gateway actúa como salida segura a internet para los nodos que tengan `USE_EXIT_NODE=true`.

---

## 🔥 Variables de Entorno

| Variable | Obligatoria | Descripción |
| :--- | :--- | :--- |
| `FIREBASE_DB_URL` | ✅ | URL de tu Firebase Realtime Database |
| `FIREBASE_PROJECT_ID` | ✅ | ID de tu proyecto en Firebase Console |
| `FIREBASE_API_KEY` | ✅ | API Key web de tu proyecto Firebase |
| `TS_AUTHKEY` | ✅ | Clave de autenticación para nodos satélites |
| `TS_LOGIN_SERVER` | ✅ | URL del servidor de login (ej: `https://vpn.tudexnetworks.com`) |
| `VPN_IP_PREFIX` | ❌ | Subred VPN (default: `100.64.0.0/10`) |
| `VPN_BASE_DOMAIN` | ❌ | Dominio base DNS (default: `vpn.internal`) |

---

## ✅ Verificación Post-Despliegue

Después de hacer `docker-compose up --build -d`, verifica:

1. **Logs del gateway:**
   ```bash
   docker logs tudex_headscale
   ```
   Deberías ver:
   ```
   ✅ [DB] Conexión con Firebase establecida.
   ✅ [AUTH] Identidad recuperada de Firebase.
   ✅ [CORE] Headscale operativo.
   ✅ [AUTH] API Key válida recuperada de Firebase.
   🌐 TUDEX MESH: INFRAESTRUCTURA OPERATIVA (Firebase Backend)
   ```

2. **Firebase Console:** Ve a Realtime Database y verifica que aparecen datos en:
   - `headscale_secrets/` — Claves WireGuard y API
   - `security_audit/` — Eventos de arranque registrados
   - `network_stats/` — Telemetría (se actualiza cada 60s)

3. **Dashboard:** Abre [http://localhost:8081](http://localhost:8081) en tu navegador.

---

## 📄 Documentación Adicional
- [Documentación Técnica Detallada](./DOCUMENTACION_TECNICA.md)
- [Estructura de Firebase](./database/firebase-structure.json)
- [Políticas de Seguridad (ACLs)](./config/acl.hujson)

---
*Tudex Networks - Engineered for Performance and Absolute Privacy.*
