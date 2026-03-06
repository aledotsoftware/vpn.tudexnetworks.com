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

2. Configuración Inicial (Automática)
Headscale requiere un archivo config.yaml básico en la carpeta ./config antes de arrancar. El parámetro principal a modificar en ese archivo es:
server_url: https://vpn.tudexnetworks.com

3. Generación de Claves (Auth Keys)
Para que los nodos remotos (Posadas, Córdoba, Ezeiza) se unan a la red sin intervención manual, debés generar una clave de autorización (Auth Key).

Ejecutá este comando en la terminal del contenedor de Headscale (desde la interfaz de Dokploy):


headscale preauthkeys create -e 365d --reusable


-e 365d: La clave expira en 1 año (seguridad estándar).

--reusable: Permite usar la misma clave para autorizar todos tus nodos actuales y futuros.

El comando devolverá un hash largo. Ese hash es el valor exacto que va en la variable TS_AUTHKEY del .env de todos tus nodos de almacenamiento.



