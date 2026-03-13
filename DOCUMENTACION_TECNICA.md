# 🛠️ ESPECIFICACIONES TÉCNICAS - TUDEX MESH

Este documento profundiza en la lógica interna y la configuración avanzada del sistema Tudex Mesh.

---

## 🛡️ 1. Lógica del Entrypoint (V21 - Total Resilience)

El script `/config/entrypoint.sh` es el orquestador del contenedor. Sus fases críticas son:

1.  **TUN Intervención:** Verifica y crea el dispositivo `/dev/net/tun` si es necesario, permitiendo que la VPN levante en entornos restringidos.
2.  **Sincronización de Identidad:** 
    - Se conecta a la DB externa de Hostinger antes de arrancar.
    - Si encuentra llaves en la DB, las inyecta en el sistema local. Esto permite que **múltiples Gateways actúen como la misma entidad**, permitiendo Alta Disponibilidad (HA).
3.  **Self-Healing API Keys:** 
    - Valida si la clave de API guardada en la nube sigue siendo funcional contra el motor local.
    - Si detecta un error `401 Unauthorized`, regenera la clave automáticamente y actualiza el Dashboard para evitar interrupciones en la monitorización.
4.  **Auto-Mesh Enlace:** Tailscale se levanta en segundo plano con reintentos infinitos hasta que el Gateway se registra a sí mismo como "Master Gateway" y se marca como **Exit Node**.

---

## 🗄️ 2. Estructura de Persistencia (MySQL)

El sistema centraliza el estado global en `u487445196_tudex_db`:

-   **`headscale_secrets`**: Guarda la identidad WireGuard y los tokens de acceso. Es el corazón de la soberanía del cluster.
-   **`security_audit`**: Registro inmutable de eventos (Gateways arriba, nodos unidos, fallos de auth).
-   **`network_stats`**: Alimenta las gráficas del Dashboard con datos de nodos online y rendimiento.

---

## ⚖️ 3. Ruteo y Balanceo Dinámico

### HAProxy (Gateway Edge)
Configurado en `/config/haproxy.cfg`. 
- Utiliza **variables de transacción** (`txn.subdomain`) para capturar el host de entrada.
- Rutea peticiones de `{app}.tudexnetworks.com` hacia `{app}.vpn.internal` de forma totalmente transparente.
- Mantiene viva la telemetría en el puerto `8404` para el NOC.

### Traefik (Dokploy Integration)
En el `docker-compose.yml` de producción, se utilizan etiquetas específicas:
- `traefik.docker.network=dokploy-network`: Fuerza al tráfico a fluir por la red de gestión de Dokploy.
- `PathPrefix`: Separa inteligentemente el tráfico del Dashboard, la API de control y los sitios de los clientes.

---

## 🛰️ 4. Configuración de Nodos Satélites (now.tudexnetworks.com)

Los satélites son agnósticos a la infraestructura:
- **DNS:** No necesitan DNS público. Se comunican por la VPN.
- **Salida:** Al conectar con `USE_EXIT_NODE=true`, el Gateway Maestro redirige su tráfico hacia el internet público bajo una IP corporativa controlada.
- **Rendimiento:** Al exponer el puerto **UDP 41641**, los satélites establecen túneles P2P directos, eliminando el lag de servidores intermediarios.

---

## 📋 5. Troubleshooting (Resolución de Problemas)

| Síntoma | Causa Probable | Solución |
| :--- | :--- | :--- |
| **Error 401 en Dashboard** | Desfase de API Key | Reiniciar el Gateway (El V21 lo arreglará solo). |
| **Nodos no se ven (Offline)** | Puerto 41641 bloqueado | Abrir UDP 41641 en el firewall del servidor. |
| **502 Bad Gateway** | HAProxy no ha iniciado | Verificar logs con `docker logs gateway_alfa`. |
| **Access Denied (DB)** | IP local no permitida | Asegurar que Hostinger permita conexiones remotas desde la IP del servidor. |

---
*Tudex Networks - Infrastructure as Code.*
