Headscale, en cambio, se instala una sola vez en toda tu red, obligatoriamente en la máquina que tiene IP pública directa (por ejemplo, tu entrada mesh-sao-txn-01).

Aquí tienes el docker-compose.yml exclusivo para levantar el servidor Headscale.

El controlador VPN (Instalar solo en sao-01)
YAML
services:
  headscale:
    image: headscale/headscale:latest
    container_name: headscale_control
    restart: always
    command: serve
    ports:
      - "8080:8080"
    volumes:
      - ./headscale_config:/etc/headscale
      - ./headscale_data:/var/lib/headscale
¿Cómo integrarlo en tu infraestructura automatizada?
Nuevo Proyecto: En el Dokploy de São Paulo, creas un proyecto llamado tudex-vpn-controller y pegas este código.

Dominio: En la pestaña de dominios de Dokploy, enrutas vpn.tudexnetworks.com hacia el puerto 8080 de este contenedor.

Listo: Tu servidor central de la red Mesh ya está online esperando conexiones.


Este es el documento base para el repositorio del "cerebro" de tu red, utilizando exclusivamente software libre.

VPN Mesh Controller - Tudex Networks
Dominio: vpn.tudexnetworks.com
Nodo Host: mesh-sao-txn-01 (o el nodo principal con IP pública)
Descripción: Controlador central Headscale. Gestiona el enrutamiento y la autenticación de la red privada virtual (Tailscale) que conecta todos los nodos físicos de almacenamiento CDN de Tudex Networks.

1. Despliegue (docker-compose.yml)
Este contenedor debe correr en Dokploy solo en un equipo. Actúa como el servidor de login para el resto de la red.

3. Configuración Inicial (CRÍTICO)

Antes de conectar nodos, debes crear el usuario donde vivirán. Ejecutá este comando en la terminal del contenedor:

```bash
headscale users create tudex
```

4. Generación de Claves (Auth Keys)
Generamos la clave vinculada al usuario `tudex` para que los nodos se autoricen solos:

```bash
headscale preauthkeys create -u tudex -e 365d --reusable
```

- `-u tudex`: Clave vinculada al usuario tudex.
- `-e 365d`: Validez de un año.
- `--reusable`: Permite usar la misma clave en múltiples nodos.

5. Clave Maestra de Red (Copiar a la variable TS_AUTHKEY de los nodos)
`hskey-auth-Q7a_3IsJcjvv-bX63j27yv0reGzAz-LQNvZn1tKFs2GuPEyNvDkK4XP1ymu-s5yGWD4Xn4AGhRapn`

