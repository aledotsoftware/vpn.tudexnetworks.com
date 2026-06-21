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
    description VARCHAR(255),
    updated_by VARCHAR(64) DEFAULT 'system',
    CONSTRAINT check_key_name_not_empty CHECK (key_name <> ''),
    CONSTRAINT check_key_content_not_empty CHECK (key_content <> '')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;

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
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;

-- 3. Configuración Dinámica de la Malla
-- Parámetros que los Gateways leen al arrancar.
CREATE TABLE IF NOT EXISTS cluster_config (
    config_key VARCHAR(64) PRIMARY KEY,
    config_value TEXT,
    is_critical BOOLEAN DEFAULT FALSE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;

-- 4. Audit Log de Seguridad
-- Registro de altas/bajas de nodos y generaciones de claves.
CREATE TABLE IF NOT EXISTS security_audit (
    id INT AUTO_INCREMENT PRIMARY KEY,
    event_type VARCHAR(64), -- 'NODE_JOIN', 'KEY_ROTATION', 'ACL_UPDATE'
    severity VARCHAR(16) DEFAULT 'INFO', -- 'INFO', 'WARN', 'CRITICAL'
    description TEXT,
    ip_source VARCHAR(45),
    detailed_audit BOOLEAN DEFAULT FALSE,
    is_alert BOOLEAN DEFAULT FALSE,
    resolved BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci ROW_FORMAT=DYNAMIC;

-- Índices para optimizar la monitorización y búsqueda de eventos de seguridad por tipo o fecha
CREATE INDEX idx_security_audit_event_type ON security_audit(event_type);
CREATE INDEX idx_security_audit_event_resolved ON security_audit(event_type, resolved);
CREATE INDEX idx_security_audit_event_severity ON security_audit(event_type, severity);
CREATE INDEX idx_security_audit_severity_event ON security_audit(severity, event_type);
CREATE INDEX idx_security_audit_created_at ON security_audit(created_at);
CREATE INDEX idx_security_audit_ip_source ON security_audit(ip_source);
CREATE INDEX idx_security_audit_detailed ON security_audit(detailed_audit);
CREATE INDEX idx_security_audit_severity ON security_audit(severity);
CREATE INDEX idx_security_audit_resolved ON security_audit(resolved);
CREATE INDEX idx_security_audit_is_alert ON security_audit(is_alert);
CREATE INDEX idx_security_audit_range ON security_audit(created_at, severity);
CREATE INDEX idx_security_audit_resolved_alert ON security_audit(resolved, is_alert);
CREATE INDEX idx_security_audit_alert_severity ON security_audit(is_alert, severity);
CREATE INDEX idx_security_audit_detailed_severity ON security_audit(detailed_audit, severity);
CREATE INDEX idx_security_audit_event_ip ON security_audit(event_type, ip_source);
CREATE INDEX idx_network_stats_snapshot_time ON network_stats(snapshot_time);
CREATE INDEX idx_network_stats_cluster_health_score ON network_stats(cluster_health_score);
CREATE INDEX idx_cluster_config_is_critical ON cluster_config(is_critical);
CREATE INDEX idx_network_stats_node_count ON network_stats(node_count);
CREATE INDEX idx_headscale_secrets_updated_at ON headscale_secrets(updated_at);
CREATE INDEX idx_headscale_secrets_updated_by ON headscale_secrets(updated_by);

CREATE INDEX idx_network_stats_active_connections ON network_stats(active_connections);
CREATE INDEX idx_network_stats_traffic_in_gb ON network_stats(traffic_in_gb);
CREATE INDEX idx_network_stats_traffic_out_gb ON network_stats(traffic_out_gb);
CREATE INDEX idx_network_stats_time_health ON network_stats(snapshot_time, cluster_health_score);
CREATE INDEX idx_network_stats_node_connections ON network_stats(node_count, active_connections);
CREATE INDEX idx_security_audit_ip_severity ON security_audit(ip_source, severity);
CREATE INDEX idx_security_audit_resolved_created_at ON security_audit(resolved, created_at);
CREATE INDEX idx_security_audit_ip_resolved ON security_audit(ip_source, resolved);
CREATE INDEX idx_security_audit_resolved_severity ON security_audit(resolved, severity);
CREATE INDEX idx_security_audit_description_resolved ON security_audit(resolved);
CREATE INDEX idx_security_audit_resolved_ip ON security_audit(resolved, ip_source);
CREATE INDEX idx_security_audit_resolved_ip_severity ON security_audit(resolved, ip_source, severity);
CREATE INDEX idx_security_audit_event_created_at ON security_audit(event_type, created_at);
CREATE INDEX idx_security_audit_severity_resolved ON security_audit(severity, resolved);
CREATE INDEX idx_security_audit_event_ip_severity ON security_audit(event_type, ip_source, severity);

-- DATOS INICIALES DE EJEMPLO PARA EL DASHBOARD
INSERT IGNORE INTO cluster_config (config_key, config_value, is_critical)
VALUES ('cluster_name', 'Tudex Global Mesh', TRUE);
