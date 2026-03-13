# 🌐 TUDEX MESH CONTROL SYSTEM

Solución de infraestructura de red definida por software (SDN) de nivel industrial para **Tudex Networks**. Este ecosistema orquesta una red mesh segura, resiliente y de alta disponibilidad, integrando control de tráfico inteligente y monitorización avanzada.

---

## 🏗️ Arquitectura del Ecosistema

El sistema Tudex Mesh se basa en tres pilares fundamentales:
1.  **Control Plane (Headscale):** El cerebro de la red que gestiona identidades, llaves WireGuard y MagicDNS.
2.  **Edge Routing (HAProxy + Traefik):** La puerta de entrada inteligente que rutea tráfico público hacia servicios privados de la mesh basados en subdominios.
3.  **Data Persistence (External MySQL):** Sincronización global de secretos, auditoría y métricas en servidores persistentes (Hostinger).

---

## 🚦 Guía de Despliegue Rápido

### A. Laboratorio de Alta Disponibilidad (Local)
Para testear el cluster balanceado con 2 Gateways y 2 Nodos Satélites en tu máquina:
```bash
docker-compose -f docker-compose.lab.yml up --build -d
```
- **Panel Alfa:** [http://localhost:8081/dashboard](http://localhost:8081/dashboard)
- **Panel Beta:** [http://localhost:8181/dashboard](http://localhost:8181/dashboard)
- **Base de Datos:** Conectada automáticamente a `srv1659.hstgr.io`.

### B. Producción (Internet / Dokploy)
El despliegue en la nube utiliza Traefik para la gestión de SSL y balanceo externo.
1. Sube el código a tu repo de Dokploy.
2. Configura las variables de entorno (`DB_HOST`, `DB_USER`, etc.) en el panel.
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
1.  **Clave de Malla:** Al iniciar el Gateway, se genera una `SATELLITE_AUTH_KEY` que se guarda en MySQL.
2.  **Inyección:** Los satélites leen esta clave (vía variable de entorno `VPN_AUTH_KEY`) y se unen a la red sin intervención manual.
3.  **Exit Node:** El Gateway actúa como salida segura a internet para los nodos que tengan `USE_EXIT_NODE=true`.

---

## 📄 Documentación Adicional
- [Documentación Técnica Detallada](./DOCUMENTACION_TECNICA.md)
- [Esquema de Base de Datos](./database/schema.sql)
- [Políticas de Seguridad (ACLs)](./config/acl.hujson)

---
*Tudex Networks - Engineered for Performance and Absolute Privacy.*
