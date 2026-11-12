#!/bin/bash
# ==========================================================
# User-data EC2 - WordPress (Docker) + RDS MySQL + Nginx
# Arquitectura: EC2 en subred publica, RDS en subred privada
# Log de instalacion: /var/log/app-setup.log
# ==========================================================
set -euxo pipefail
touch /var/log/app-setup.log && chmod 600 /var/log/app-setup.log
exec > >(tee -a /var/log/app-setup.log) 2>&1

# ---------- Variables (EDITAR) ----------
DB_HOST="REEMPLAZAR_CON_ENDPOINT_RDS_MYSQL"   # ej: wp-db.xxxxxxxxxxxx.us-east-1.rds.amazonaws.com
DB_PORT="3306"
DB_NAME="wordpress"
DB_USER="admin"                 # usuario con permisos sobre la base DB_NAME
DB_PASSWORD="CambiarEstaClave123"

APP_IMAGE="wordpress:latest"    # se puede fijar una version, ej: wordpress:6.8-php8.3-apache
APP_PORT="8080"                 # puerto local donde escucha el contenedor

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
apt-get install -y docker.io nginx mysql-client curl
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
if ! mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASSWORD}" -e "USE \`${DB_NAME}\`;"; then
  echo "ERROR: no se pudo conectar a la base '${DB_NAME}'."
  echo "Verificar que la base exista en RDS (creada a mano) y que el usuario/clave sean correctos."
  exit 1
fi

# ---------- Carpetas y configuracion ----------
mkdir -p /opt/wordpress/html

# WP_HOME/WP_SITEURL dinamicos: el sitio sigue funcionando si cambia la IP publica
cat > /opt/wordpress/wordpress.env <<EOF
WORDPRESS_DB_HOST=${DB_HOST}:${DB_PORT}
WORDPRESS_DB_USER=${DB_USER}
WORDPRESS_DB_PASSWORD=${DB_PASSWORD}
WORDPRESS_DB_NAME=${DB_NAME}
WORDPRESS_CONFIG_EXTRA=define('WP_HOME','http://'.\$_SERVER['HTTP_HOST']);define('WP_SITEURL','http://'.\$_SERVER['HTTP_HOST']);
EOF
chmod 600 /opt/wordpress/wordpress.env

# ---------- Descargar imagen (con reintentos) ----------
for i in $(seq 1 5); do docker pull "${APP_IMAGE}" && break; sleep 10; done

# ---------- Arrancar WordPress (solo en localhost; Nginx lo publica) ----------
docker rm -f wordpress 2>/dev/null || true
docker run -d \
  --name wordpress \
  --restart unless-stopped \
  -p 127.0.0.1:${APP_PORT}:80 \
  --env-file /opt/wordpress/wordpress.env \
  -v /opt/wordpress/html:/var/www/html \
  "${APP_IMAGE}"

# ---------- Nginx como proxy inverso ----------
cat > /etc/nginx/sites-available/app <<EOF
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 64M;

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

echo "WordPress instalado. Abrir http://IP_PUBLICA_EC2 y completar el asistente de instalacion."
