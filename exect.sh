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

# --- 1.5. Detección Automática de IP ---
log_info "Detectando la dirección IP principal del servidor..."
INTERFACE=$(ip route | grep default | awk '{print $5}')
SERVER_IP=$(ip -4 addr show "$INTERFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$SERVER_IP" ] || [ -z "$INTERFACE" ]; then
    log_error "No se pudo detectar automáticamente la dirección IP principal."
    exit 1
fi

log_info "IP detectada automáticamente: ${YELLOW}$SERVER_IP${NC} (Interfaz: ${YELLOW}$INTERFACE${NC})"
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
    log_warn "No se pudo detectar el usuario que ejecutó sudo."
fi

# --- 4. Crear el entorno y los archivos de configuración ---

log_info "Creando el directorio 'enviroment' y los archivos de configuración..."
mkdir -p enviroment
cd enviroment

# Generar una clave secreta aleatoria para Taiga
TAIGA_SECRET_KEY=$(openssl rand -hex 64)

# Crear el archivo docker-compose.yml con Gitea, Nextcloud y Taiga
cat << EOF > docker-compose.yml
version: '3.8'

services:
  # --- GITEA Y NEXTCLOUD (con SQLite) ---
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__server__ROOT_URL=http://${SERVER_IP}/gitea
    restart: always
    networks:
      - proxy-net
    volumes:
      - ./gitea-data:/data

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud
    restart: always
    environment:
      - NEXTCLOUD_TRUSTED_DOMAINS=${SERVER_IP}
      - OVERWRITEPROTOCOL=http
      - OVERWRITEHOST=${SERVER_IP}
      - OVERWRITEWEBROOT=/nextcloud
    volumes:
      - ./nextcloud-data:/var/www/html
    networks:
      - proxy-net

  # --- PILA DE TAIGA ---
  taiga-db:
    image: postgres:15-alpine
    container_name: taiga_db
    environment:
      - POSTGRES_DB=taiga
      - POSTGRES_USER=taiga
      - POSTGRES_PASSWORD=taiga
    volumes:
      - ./postgres-taiga-data:/var/lib/postgresql/data
    networks:
      - proxy-net
    restart: always

  taiga-back:
    image: taigaio/taiga-back:latest
    container_name: taiga_back
    environment:
      - TAIGA_DB_HOST=taiga-db
      - TAIGA_DB_PASSWORD=taiga
      - TAIGA_DB_USER=taiga
      - TAIGA_DB_NAME=taiga
      - TAIGA_SECRET_KEY=${TAIGA_SECRET_KEY}
      - TAIGA_SITES_SCHEME=http
      - TAIGA_SITES_DOMAIN=${SERVER_IP}
      - TAIGA_SUBPATH=/taiga
      - TAIGA_ATTACHMENTS_DIR=/taiga-data/attachments
      - TAIGA_MEDIA_DIR=/taiga-data/media
      - RABBITMQ_USER=taiga
      - RABBITMQ_PASS=taiga
      - RABBITMQ_VHOST=taiga
    volumes:
      - ./taiga-data:/taiga-data
    networks:
      - proxy-net
    depends_on:
      - taiga-db
      - taiga-rabbit
    restart: always

  taiga-front:
    image: taigaio/taiga-front:latest
    container_name: taiga_front
    environment:
      - TAIGA_URL=http://${SERVER_IP}/taiga
      - TAIGA_WEBSOCKETS_URL=ws://${SERVER_IP}/taiga
      - TAIGA_API_URL=http://${SERVER_IP}/taiga/api/v1/
    networks:
      - proxy-net
    depends_on:
      - taiga-back
    restart: always

  taiga-rabbit:
    image: rabbitmq:3-management-alpine
    container_name: taiga_rabbit
    hostname: taiga-rabbit
    environment:
      - RABBITMQ_DEFAULT_USER=taiga
      - RABBITMQ_DEFAULT_PASS=taiga
      - RABBITMQ_DEFAULT_VHOST=taiga
    networks:
      - proxy-net
    restart: always

  # --- PROXY PRINCIPAL ---
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
      - nextcloud
      - taiga-front
    restart: always

networks:
  proxy-net:
    driver: bridge
EOF

# Crear el archivo de configuración de Nginx
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
        server_name ${SERVER_IP};
        client_max_body_size 100M;

        location /gitea/ {
            proxy_pass http://gitea:3000/;
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
        
        location /taiga/ {
            proxy_pass http://taiga-front:80/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;

            # Soporte para WebSockets
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
EOF

log_info "Archivos docker-compose.yml y nginx.conf creados en el directorio 'enviroment'."

# --- 5. Ejecutar Docker Compose y finalizar ---

log_info "Levantando los contenedores con Docker Compose..."
log_warn "Taiga es una aplicación grande, el primer arranque puede tardar varios minutos en segundo plano."
docker compose up -d

echo ""
log_info "========================= ¡PROCESO COMPLETADO! ========================="
log_info "El entorno ha sido desplegado correctamente."
log_info "Los servicios están disponibles en las siguientes URLs:"
log_info "  - Gitea:     http://${SERVER_IP}/gitea"
log_info "  - Nextcloud: http://${SERVER_IP}/nextcloud"
log_info "  - Taiga:     http://${SERVER_IP}/taiga"
log_info ""
log_warn "Recuerda que Taiga puede tardar unos minutos en estar completamente operativo la primera vez."
log_info "Los datos persistentes se guardarán en el directorio 'enviroment'."
if [ -n "$SUDO_USER" ]; then
    log_warn "RECUERDA: Debes cerrar tu sesión y volver a iniciarla para poder usar 'docker' sin 'sudo'."
fi
log_info "======================================================================="
echo ""
