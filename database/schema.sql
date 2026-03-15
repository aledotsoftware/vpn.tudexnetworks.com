-- ============================================================
-- TUDEX NETWORKS - MESH CONTROL DATABASE SCHEMA
-- ============================================================
-- Este archivo define el esquema central para la sincronización 
-- de secretos y el almacenamiento de métricas del cluster VPN.

-- 1. Almacén de Secretos (Identidad de Red)
-- Todos los Gateways del cluster se sincronizan aquí para 
-- compartir el mismo plano de control.
CREATE TABLE IF NOT EXISTS headscale_secrets (
    key_name VARCHAR(64) PRIMARY KEY, -- 'private_key', 'noise_private_key', 'api_key'
    key_content TEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL, -- Binary collation prevents case-folding corruption of secrets
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    description VARCHAR(255)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Mantenimiento de integridad: previene inserciones con nombres de clave vacíos
ALTER TABLE headscale_secrets ADD CONSTRAINT check_key_name_not_empty CHECK (key_name <> '');

-- 2. Histórico de Nodos y Salud
-- Para generar las gráficas del Dashboard de forma persistente.
CREATE TABLE IF NOT EXISTS network_stats (
    id INT AUTO_INCREMENT PRIMARY KEY,
    node_count INT DEFAULT 0,
    active_connections INT DEFAULT 0,
    traffic_in_gb BIGINT DEFAULT 0,
    traffic_out_gb BIGINT DEFAULT 0,
    cluster_health_score TINYINT DEFAULT 100,
    snapshot_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. Configuración Dinámica de la Malla
-- Parámetros que los Gateways leen al arrancar.
CREATE TABLE IF NOT EXISTS cluster_config (
    config_key VARCHAR(64) PRIMARY KEY,
    config_value TEXT,
    is_critical BOOLEAN DEFAULT FALSE
);

-- 4. Audit Log de Seguridad
-- Registro de altas/bajas de nodos y generaciones de claves.
CREATE TABLE IF NOT EXISTS security_audit (
    id INT AUTO_INCREMENT PRIMARY KEY,
    event_type VARCHAR(64), -- 'NODE_JOIN', 'KEY_ROTATION', 'ACL_UPDATE'
    description TEXT,
    ip_source VARCHAR(45),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- DATOS INICIALES DE EJEMPLO PARA EL DASHBOARD
INSERT IGNORE INTO cluster_config (config_key, config_value, is_critical) 
VALUES ('cluster_name', 'Tudex Global Mesh', TRUE);
