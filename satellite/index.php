<?php
header('Content-Type: text/html; charset=utf-8');
$node_name = getenv('NODE_NAME') ?: 'Unknown Node';
$container_ip = $_SERVER['SERVER_ADDR'] ?: 'Unknown IP';
$server_name = gethostname();
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Tudex Mesh - Nodo Satélite</title>
    <style>
        body {
            font-family: 'Inter', system-ui, -apple-system, sans-serif;
            background: #0f172a;
            color: #f8fafc;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            overflow: hidden;
        }
        .card {
            background: rgba(30, 41, 59, 0.7);
            backdrop-filter: blur(12px);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 24px;
            padding: 3rem;
            text-align: center;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
            max-width: 400px;
            width: 90%;
            transition: transform 0.3s ease;
        }
        .card:hover {
            transform: translateY(-5px);
        }
        .badge {
            background: linear-gradient(135deg, #3b82f6, #2563eb);
            color: white;
            padding: 0.5rem 1rem;
            border-radius: 9999px;
            font-size: 0.875rem;
            font-weight: 600;
            display: inline-block;
            margin-bottom: 1.5rem;
            box-shadow: 0 4px 6px -1px rgba(59, 130, 246, 0.5);
        }
        h1 {
            font-size: 2.25rem;
            margin-bottom: 1rem;
            background: linear-gradient(to right, #60a5fa, #a78bfa);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .stats {
            text-align: left;
            background: rgba(15, 23, 42, 0.5);
            padding: 1.5rem;
            border-radius: 16px;
            margin-top: 2rem;
        }
        .stat-item {
            margin-bottom: 1rem;
        }
        .stat-label {
            display: block;
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: #94a3b8;
            margin-bottom: 0.25rem;
        }
        .stat-value {
            font-family: 'JetBrains Mono', monospace;
            font-size: 1.125rem;
            color: #e2e8f0;
        }
        .status-dot {
            height: 8px;
            width: 8px;
            background-color: #22c55e;
            border-radius: 50%;
            display: inline-block;
            margin-right: 8px;
            box-shadow: 0 0 8px #22c55e;
        }
    </style>
</head>
<body>
    <div class="card">
        <span class="badge">NODO SATÉLITE</span>
        <h1>Tudex Mesh</h1>
        <p><span class="status-dot"></span> Malla Activa y Segura</p>
        
        <div class="stats">
            <div class="stat-item">
                <span class="stat-label">Identificador del Nodo:</span>
                <span class="stat-value"><?php echo htmlspecialchars($node_name); ?></span>
            </div>
            <div class="stat-item">
                <span class="stat-label">Dirección IP Malla:</span>
                <span class="stat-value"><?php echo htmlspecialchars($container_ip); ?></span>
            </div>
            <div class="stat-item">
                <span class="stat-label">Hostname del Contenedor:</span>
                <span class="stat-value"><?php echo htmlspecialchars($server_name); ?></span>
            </div>
        </div>
    </div>
</body>
</html>
