#!/bin/bash
# ==========================================================
# User-data EC2 - Wiki.js (Docker) + RDS PostgreSQL + Nginx
# Arquitectura: EC2 en subred publica, RDS en subred privada
# Log de instalacion: /var/log/app-setup.log
# ==========================================================
set -euxo pipefail
touch /var/log/app-setup.log && chmod 600 /var/log/app-setup.log
exec > >(tee -a /var/log/app-setup.log) 2>&1

# ---------- Variables (EDITAR) ----------
DB_HOST="REEMPLAZAR_CON_ENDPOINT_RDS_POSTGRES"  # ej: wiki-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
DB_PORT="5432"
DB_NAME="wikijs"
DB_USER="postgres"              # usuario con permisos sobre la base DB_NAME
DB_PASSWORD="CambiarEstaClave123"

APP_IMAGE="ghcr.io/requarks/wiki:2"
APP_PORT="3000"                 # puerto local donde escucha el contenedor

# ---------- Swap de 2 GB ----------
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------- Paquetes ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io nginx postgresql-client curl
systemctl enable --now docker
usermod -aG docker ubuntu || true
for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

# ---------- Esperar a que RDS sea alcanzable (max. 10 min) ----------
RDS_OK=0
for i in $(seq 1 60); do
  if timeout 3 bash -c "</dev/tcp/${DB_HOST}/${DB_PORT}" 2>/dev/null; then RDS_OK=1; break; fi
  echo "Esperando RDS ${DB_HOST}:${DB_PORT} ($i/60)..."
  sleep 10
done
if [ "$RDS_OK" -ne 1 ]; then
  echo "ERROR: no hay conexion a RDS. Revisar endpoint y Security Group (puerto ${DB_PORT})."
  exit 1
fi

# ---------- Verificar que la base de datos exista (debe crearse A MANO) ----------
export PGPASSWORD="${DB_PASSWORD}"
if ! psql "host=${DB_HOST} port=${DB_PORT} user=${DB_USER} dbname=${DB_NAME} sslmode=require" -c "SELECT 1" >/dev/null; then
  echo "ERROR: no se pudo conectar a la base '${DB_NAME}'."
  echo "Verificar que la base exista en RDS (creada a mano) y que el usuario/clave sean correctos."
  exit 1
fi
unset PGPASSWORD

# ---------- Carpetas y configuracion ----------
mkdir -p /opt/wikijs/data
chown -R 1000:1000 /opt/wikijs/data

# RDS PostgreSQL exige SSL: se activa SSL sin verificar la CA de Amazon
cat > /opt/wikijs/config.yml <<EOF
port: 3000
bindIP: 0.0.0.0
db:
  type: postgres
  host: '${DB_HOST}'
  port: ${DB_PORT}
  user: '${DB_USER}'
  pass: '${DB_PASSWORD}'
  db: '${DB_NAME}'
  ssl: true
  sslOptions:
    auto: false
    rejectUnauthorized: false
logLevel: info
offline: false
ha: false
dataPath: ./data
EOF
chmod 644 /opt/wikijs/config.yml

# ---------- Descargar imagen (con reintentos) ----------
for i in $(seq 1 5); do docker pull "${APP_IMAGE}" && break; sleep 10; done

# ---------- Arrancar Wiki.js (solo en localhost; Nginx lo publica) ----------
docker rm -f wikijs 2>/dev/null || true
docker run -d \
  --name wikijs \
  --restart unless-stopped \
  -p 127.0.0.1:${APP_PORT}:3000 \
  -v /opt/wikijs/config.yml:/wiki/config.yml:ro \
  -v /opt/wikijs/data:/wiki/data \
  "${APP_IMAGE}"

# ---------- Nginx como proxy inverso ----------
cat > /etc/nginx/sites-available/app <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/app /etc/nginx/sites-enabled/app
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "Wiki.js instalado. Abrir http://IP_PUBLICA_EC2 y crear el administrador en el asistente."
