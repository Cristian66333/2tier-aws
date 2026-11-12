#!/bin/bash
# ==========================================================
# User-data EC2 - Redmine (Docker) + RDS PostgreSQL + Nginx
# Arquitectura: EC2 en subred publica, RDS en subred privada
# Log de instalacion: /var/log/app-setup.log
# ==========================================================
set -euxo pipefail
touch /var/log/app-setup.log && chmod 600 /var/log/app-setup.log
exec > >(tee -a /var/log/app-setup.log) 2>&1

# ---------- Variables (EDITAR) ----------
DB_HOST="REEMPLAZAR_CON_ENDPOINT_RDS_POSTGRES"  # ej: redmine-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
DB_PORT="5432"
DB_NAME="redmine"
DB_USER="postgres"              # usuario con permisos sobre la base DB_NAME
DB_PASSWORD="CambiarEstaClave123"

APP_IMAGE="redmine:6"
APP_PORT="3000"                 # puerto local donde escucha el contenedor
REDMINE_LANG="es"               # idioma de los datos por defecto (roles, estados, trackers)

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
apt-get install -y docker.io nginx postgresql-client curl openssl
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

# ---------- Carpetas y clave secreta (se conserva entre ejecuciones) ----------
mkdir -p /opt/redmine/files
chown -R 999:999 /opt/redmine/files
if [ ! -f /opt/redmine/secret_key_base ]; then
  openssl rand -hex 64 > /opt/redmine/secret_key_base
  chmod 600 /opt/redmine/secret_key_base
fi
SECRET_KEY_BASE=$(cat /opt/redmine/secret_key_base)

# ---------- Descargar imagen (con reintentos) ----------
for i in $(seq 1 5); do docker pull "${APP_IMAGE}" && break; sleep 10; done

# ---------- Arrancar Redmine (solo en localhost; Nginx lo publica) ----------
# Al arrancar, el contenedor crea/migra las tablas automaticamente
docker rm -f redmine 2>/dev/null || true
docker run -d \
  --name redmine \
  --restart unless-stopped \
  -p 127.0.0.1:${APP_PORT}:3000 \
  -e REDMINE_DB_POSTGRES="${DB_HOST}" \
  -e REDMINE_DB_PORT="${DB_PORT}" \
  -e REDMINE_DB_DATABASE="${DB_NAME}" \
  -e REDMINE_DB_USERNAME="${DB_USER}" \
  -e REDMINE_DB_PASSWORD="${DB_PASSWORD}" \
  -e REDMINE_SECRET_KEY_BASE="${SECRET_KEY_BASE}" \
  -v /opt/redmine/files:/usr/src/redmine/files \
  "${APP_IMAGE}"

# ---------- Esperar a que Redmine responda (max. 10 min) ----------
for i in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:${APP_PORT} && break
  echo "Esperando a que Redmine termine de crear las tablas ($i/60)..."
  sleep 10
done

# ---------- Cargar datos por defecto en espanol (solo la primera vez) ----------
if [ ! -f /opt/redmine/.default_data_loaded ]; then
  docker exec -e RAILS_ENV=production -e REDMINE_LANG="${REDMINE_LANG}" redmine \
    bundle exec rake redmine:load_default_data \
    && touch /opt/redmine/.default_data_loaded \
    || echo "AVISO: no se cargaron los datos por defecto (se pueden cargar desde Administracion)."
fi

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

echo "Redmine instalado. Abrir http://IP_PUBLICA_EC2 - usuario: admin / clave: admin (pide cambiarla al entrar)."
