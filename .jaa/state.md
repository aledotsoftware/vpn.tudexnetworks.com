# JAA Global System State - Security Updates

## 🛡️ Security Gateway Specialist Agent - Updates
- **Auditoría de ACLs**: Se aplicó el principio de *Least Privilege* en `config/acl.hujson`. Acceso total restringido a `group:admin` y `core-mesh`. Tráfico `group:cdn` restringido al destino `cdn-mesh:*`.
- **Hardening de HAProxy**:
  - Se añadió limitación de peticiones (Rate Limiting) con `stick-table` para prevenir ataques DoS en `config/haproxy.cfg`.
  - Se implementaron cabeceras de seguridad HTTP (`Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `X-XSS-Protection`).
  - Se oculta la versión del servidor mediante `del-header Server`.
- **Gestión de Secretos**:
  - Se refactorizó la generación de las claves (`private.key` y `noise_private.key`) en `config/entrypoint.sh` utilizando `hexdump` desde `/dev/urandom` para evitar hardcoding accidental.
  - El password de la base de datos se exporta globalmente como `MYSQL_PWD` previniendo fugas en los comandos del sistema.
- **Logs y Auditoría**:
  - Se añadieron registros automáticos a la tabla `security_audit` de MySQL para eventos críticos de `GATEWAY_BOOT` y `KEY_GENERATION` en `config/entrypoint.sh`.

Estos cambios aseguran una postura de seguridad robusta para Tudex Operational Gateway, fortaleciendo el balanceador de carga, la red mesh Zero-Trust, y la persistencia segura de estado.
