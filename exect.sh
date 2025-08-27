#!/bin/bash

# --- Configuración de Colores y Mensajes ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detener el script si un comando falla
set -e

# --- 1. Verificaciones Previas ---

# Verificar si el script se ejecuta como root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Este script debe ser ejecutado como superusuario (root). Por favor, utiliza 'sudo'."
    exit 1
fi

# Verificar la versión de Debian
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "debian" ] && { [ "$VERSION_ID" = "11" ] || [ "$VERSION_ID" = "12" ] || [ "$VERSION_ID" = "13" ]; }; then
        log_info "Sistema operativo compatible: Debian $VERSION_ID ($VERSION_CODENAME) detectado."
    else
        log_error "Este script está diseñado para Debian 11, 12 o 13. Versión detectada: $PRETTY_NAME."
        exit 1
    fi
else
    log_error "No se pudo determinar la distribución del sistema operativo."
    exit 1
fi

# --- 1.5. Solicitar IP Estática ---
log_info "Por favor, introduce la dirección IP estática de este servidor."
read -p "IP estática: " STATIC_IP

if [ -z "$STATIC_IP" ]; then
    log_error "La dirección IP no puede estar vacía."
    exit 1
fi

log_info "Se configurarán los servicios para que sean accesibles en la IP: ${YELLOW}$STATIC_IP${NC}"
echo ""

# --- 2. Instalación de Docker ---

log_info "Actualizando lista de paquetes..."
apt-get update

log_info "Instalando dependencias necesarias..."
apt-get install ca-certificates curl git -y

log_info "Creando directorio para llaves de APT..."
install -m 0755 -d /etc/apt/keyrings

log_info "Descargando la llave GPG de Docker..."
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

log_info "Añadiendo el repositorio de Docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

log_info "Actualizando la lista de paquetes con el nuevo repositorio..."
apt-get update

log_info "Instalando Docker Engine y sus componentes..."
apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

log_info "Docker ha sido instalado correctamente."

# --- 3. Asignar permisos de Docker al usuario actual ---

if [ -n "$SUDO_USER" ]; then
    log_info "Añadiendo el usuario '$SUDO_USER' al grupo 'docker'..."
    usermod -aG docker "$SUDO_USER"
    log_warn "El usuario '$SUDO_USER' debe cerrar sesión y volver a iniciarla para usar Docker sin sudo."
else
    log_warn "No se pudo detectar el usuario que ejecutó sudo. Omita este paso si está ejecutando como root directamente."
fi

# --- 4. Crear el entorno y los archivos de configuración ---

log_info "Creando el directorio 'enviroment' y los archivos de configuración..."
mkdir -p enviroment
cd enviroment

# Crear el archivo docker-compose.yml con SQLite para todos los servicios
cat << EOF > docker-compose.yml
version: '3.8'

services:
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__server__ROOT_URL=http://${STATIC_IP}/gitea
    restart: always
    networks:
      - proxy-net
    volumes:
      - ./gitea-data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro

  kanboard:
    image: kanboard/kanboard:latest
    container_name: kanboard
    restart: always
    environment:
      - KANBOARD_URL=http://${STATIC_IP}/kb
    volumes:
      - ./kanboard-data:/var/www/app/data
      - ./kanboard-plugins:/var/www/app/plugins
    networks:
      - proxy-net

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: always
    environment:
      - NEXTCLOUD_TRUSTED_DOMAINS=${STATIC_IP}
      - OVERWRITEPROTOCOL=http
      - OVERWRITEHOST=${STATIC_IP}
      - OVERWRITEWEBROOT=/nextcloud
    volumes:
      - ./nextcloud-data:/var/www/html
    networks:
      - proxy-net

  nginx:
    image: nginx:latest
    container_name: nginx_proxy
    ports:
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    networks:
      - proxy-net
    depends_on:
      - gitea
      - kanboard
      - nextcloud
    restart: always

networks:
  proxy-net:
    driver: bridge
EOF

# Crear el archivo de configuración de Nginx (sin cambios)
cat << EOF > nginx.conf
worker_processes 1;

events {
    worker_connections 1024;
}

http {
    sendfile on;
    tcp_nopush on;
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen 80;
        server_name ${STATIC_IP};

        location /gitea/ {
            proxy_pass http://gitea:3000/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /kb/ {
            proxy_pass http://kanboard:80/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /nextcloud/ {
            proxy_pass http://nextcloud:80/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            client_max_body_size 512M;
            proxy_request_buffering off;
        }
    }
}
EOF

log_info "Archivos docker-compose.yml y nginx.conf creados en el directorio 'enviroment'."

# --- 5. Ejecutar Docker Compose y finalizar ---

log_info "Levantando los contenedores con Docker Compose... (esto puede tardar unos minutos)"
docker compose up -d

echo ""
log_info "========================= ¡PROCESO COMPLETADO! ========================="
log_info "El entorno ha sido desplegado correctamente con SQLite3 para todos los servicios."
log_info "Los servicios están disponibles en las siguientes URLs:"
log_info "  - Gitea:     http://${STATIC_IP}/gitea"
log_info "  - Kanboard:  http://${STATIC_IP}/kb"
log_info "  - Nextcloud: http://${STATIC_IP}/nextcloud"
log_info ""
log_info "Los datos persistentes (incluidas las bases de datos SQLite) se guardarán en el directorio 'enviroment'."
if [ -n "$SUDO_USER" ]; then
    log_warn "RECUERDA: Debes cerrar tu sesión y volver a iniciarla para poder usar 'docker' sin 'sudo'."
fi
log_info "======================================================================="
echo ""
