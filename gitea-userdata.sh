#!/bin/bash
# ==========================================================
# User-data EC2 - Gitea (Docker) + RDS PostgreSQL + Nginx
# Arquitectura: EC2 en subred publica, RDS en subred privada
# Log de instalacion: /var/log/app-setup.log
# ==========================================================
set -euxo pipefail
touch /var/log/app-setup.log && chmod 600 /var/log/app-setup.log
exec > >(tee -a /var/log/app-setup.log) 2>&1

# ---------- Variables (EDITAR) ----------
DB_HOST="REEMPLAZAR_CON_ENDPOINT_RDS_POSTGRES"  # ej: gitea-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
DB_PORT="5432"
DB_NAME="gitea"
DB_USER="postgres"              # usuario con permisos sobre la base DB_NAME
DB_PASSWORD="CambiarEstaClave123"

APP_IMAGE="gitea/gitea:latest"  # se puede fijar una version, ej: gitea/gitea:1.24
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

# ---------- IP publica de la instancia (IMDSv2) para la URL de Gitea ----------
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  http://169.254.169.254/latest/meta-data/public-ipv4 || true)
PUBLIC_IP="${PUBLIC_IP:-localhost}"

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

# ---------- Carpetas ----------
mkdir -p /opt/gitea/data
chown -R 1000:1000 /opt/gitea/data

# ---------- Descargar imagen (con reintentos) ----------
for i in $(seq 1 5); do docker pull "${APP_IMAGE}" && break; sleep 10; done

# ---------- Arrancar Gitea (solo en localhost; Nginx lo publica) ----------
# SSH de Git desactivado para no chocar con el SSH de la EC2 (clonar por HTTP)
docker rm -f gitea 2>/dev/null || true
docker run -d \
  --name gitea \
  --restart unless-stopped \
  -p 127.0.0.1:${APP_PORT}:3000 \
  -e USER_UID=1000 \
  -e USER_GID=1000 \
  -e GITEA__database__DB_TYPE=postgres \
  -e GITEA__database__HOST="${DB_HOST}:${DB_PORT}" \
  -e GITEA__database__NAME="${DB_NAME}" \
  -e GITEA__database__USER="${DB_USER}" \
  -e GITEA__database__PASSWD="${DB_PASSWORD}" \
  -e GITEA__database__SSL_MODE=require \
  -e GITEA__server__DOMAIN="${PUBLIC_IP}" \
  -e GITEA__server__ROOT_URL="http://${PUBLIC_IP}/" \
  -e GITEA__server__DISABLE_SSH=true \
  -v /opt/gitea/data:/data \
  "${APP_IMAGE}"

# ---------- Nginx como proxy inverso ----------
cat > /etc/nginx/sites-available/app <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 512M;

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

echo "Gitea instalado. Abrir http://${PUBLIC_IP} y completar el asistente (el primer usuario registrado es administrador)."
