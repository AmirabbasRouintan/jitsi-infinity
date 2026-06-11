#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  Jitsi Meet Services Setup"
echo "=========================================="
echo ""

if ! command -v docker &>/dev/null; then
  echo -e "${YELLOW}Docker not found.${NC}"
  echo "Select your distro to install Docker:"
  echo "  1) Debian / Ubuntu (apt)"
  echo "  2) Arch Linux (pacman)"
  echo "  3) Skip — I'll install Docker myself"
  read -rp "Choice [1/2/3]: " INSTALL_CHOICE

  case "$INSTALL_CHOICE" in
  1)
    echo -e "${GREEN}Installing Docker via apt...${NC}"
    sudo apt update
    sudo apt install -y docker.io docker-compose-v2 openssl
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    echo -e "${YELLOW}Please log out and back in, then re-run this script.${NC}"
    exit 0
    ;;
  2)
    echo -e "${GREEN}Installing Docker via pacman...${NC}"
    sudo pacman -S --noconfirm docker docker-compose openssl
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    echo -e "${YELLOW}Please log out and back in, then re-run this script.${NC}"
    exit 0
    ;;
  *)
    echo -e "${RED}Docker is required. Install it manually first.${NC}"
    exit 1
    ;;
  esac
fi

if ! docker compose version &>/dev/null; then
  echo -e "${RED}Docker Compose plugin not found. Install docker-compose-plugin.${NC}"
  exit 1
fi

CONFIG_DIR="${CONFIG:-/home/ubuntu/.jitsi-meet-cfg}"
mkdir -p "$CONFIG_DIR"/{web/prosody/config,jicofo,jvb,jibri,transcripts}

echo "Select mode:"
echo "  1) localhost  - Test on your local machine"
echo "  2) server     - Deploy on a public server"
read -rp "Choice [1/2]: " MODE

mkdir -p "$SCRIPT_DIR/recordings"

if [ "$MODE" = "1" ] || [ "$MODE" = "localhost" ]; then
  echo -e "\n${GREEN}=== Setting up for LOCALHOST ===${NC}"

  SERVER_IP="localhost"
  HTTP_PORT=8000
  HTTPS_PORT=8443
  PUBLIC_URL="https://localhost:${HTTPS_PORT}"
  JVB_ADVERTISE_IPS=""
  ENABLE_LETSENCRYPT=0
  LETSENCRYPT_DOMAIN=""
  LETSENCRYPT_EMAIL=""
  ENABLE_XMPP_WEBSOCKET=0
  BOSH_RELATIVE=1
  ENABLE_HTTP_REDIRECT=0

elif [ "$MODE" = "2" ] || [ "$MODE" = "server" ]; then
  echo -e "\n${GREEN}=== Setting up for SERVER ===${NC}"

  DETECTED_IP=$(ip route get 1 | awk '{print $7; exit}' 2>/dev/null || echo "")
  if [ -n "$DETECTED_IP" ]; then
    echo -e "Detected server IP: ${YELLOW}$DETECTED_IP${NC}"
    read -rp "Use this IP? [Y/n]: " USE_IP
    if [[ "$USE_IP" =~ ^[Nn] ]]; then
      read -rp "Enter your server IP or domain: " SERVER_IP
    else
      SERVER_IP="$DETECTED_IP"
    fi
  else
    read -rp "Enter your server IP or domain: " SERVER_IP
  fi

  if [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}Using IP address (self-signed cert will be generated)${NC}"
    HTTP_PORT=8000
    HTTPS_PORT=8443
    PUBLIC_URL="https://${SERVER_IP}:${HTTPS_PORT}"
    JVB_ADVERTISE_IPS="$SERVER_IP"
    ENABLE_LETSENCRYPT=0
    LETSENCRYPT_DOMAIN=""
    LETSENCRYPT_EMAIL=""
    ENABLE_HTTP_REDIRECT=0
  else
    echo -e "${YELLOW}Using domain: $SERVER_IP${NC}"
    read -rp "Enter your email for Let's Encrypt: " LETSENCRYPT_EMAIL
    HTTP_PORT=80
    HTTPS_PORT=443
    PUBLIC_URL="https://${SERVER_IP}"
    JVB_ADVERTISE_IPS=""
    ENABLE_LETSENCRYPT=1
    LETSENCRYPT_DOMAIN="$SERVER_IP"
    ENABLE_HTTP_REDIRECT=1
  fi

  ENABLE_XMPP_WEBSOCKET=1
  BOSH_RELATIVE=1
else
  echo -e "${RED}Invalid choice.${NC}"
  exit 1
fi

PASSWORDS_SOURCE=""
if [ -f .env ] && grep -q "JICOFO_AUTH_PASSWORD" .env 2>/dev/null; then
  PASSWORDS_SOURCE=".env"
else
  echo -e "\n${GREEN}=== Generating passwords ===${NC}"
  PASSWORDS_SOURCE="/tmp/jitsi-passwords.tmp"
  cat >"$PASSWORDS_SOURCE" <<EOF
JICOFO_AUTH_PASSWORD=$(openssl rand -hex 16)
JVB_AUTH_PASSWORD=$(openssl rand -hex 16)
JIGASI_XMPP_PASSWORD=$(openssl rand -hex 16)
JIGASI_TRANSCRIBER_PASSWORD=$(openssl rand -hex 16)
JIBRI_RECORDER_PASSWORD=$(openssl rand -hex 16)
JIBRI_XMPP_PASSWORD=$(openssl rand -hex 16)
EOF
fi

echo -e "\n${GREEN}=== Writing .env configuration ===${NC}"

# Capture passwords before .env is truncated by the heredoc
EXISTING_PASSWORDS=""
if [ -f "$PASSWORDS_SOURCE" ]; then
  EXISTING_PASSWORDS=$(grep -E "^(JICOFO_AUTH_PASSWORD|JVB_AUTH_PASSWORD|JIGASI_XMPP_PASSWORD|JIGASI_TRANSCRIBER_PASSWORD|JIBRI_RECORDER_PASSWORD|JIBRI_XMPP_PASSWORD)=" "$PASSWORDS_SOURCE" 2>/dev/null || true)
fi

cat >.env <<ENVEOF
CONFIG=${CONFIG_DIR}
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=${HTTPS_PORT}
TZ=UTC
PUBLIC_URL=${PUBLIC_URL}
JVB_ADVERTISE_IPS=${JVB_ADVERTISE_IPS}
ENABLE_RECORDING=1
BOSH_RELATIVE=${BOSH_RELATIVE}
ENABLE_HTTP_REDIRECT=${ENABLE_HTTP_REDIRECT}
ENABLE_XMPP_WEBSOCKET=${ENABLE_XMPP_WEBSOCKET}
ENABLE_LETSENCRYPT=${ENABLE_LETSENCRYPT}
LETSENCRYPT_DOMAIN=${LETSENCRYPT_DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
${EXISTING_PASSWORDS}
JIBRI_COUNT=3  # Increase if VPS has enough RAM (each jibri ~2GB). After editing, run: ./generate-jibri-pool.sh
ENVEOF

[ "$PASSWORDS_SOURCE" = "/tmp/jitsi-passwords.tmp" ] && rm -f "$PASSWORDS_SOURCE"

echo -e "\n${GREEN}=== Generating jibri pool ===${NC}"
bash "${SCRIPT_DIR}/generate-jibri-pool.sh"

echo -e "\n${GREEN}=== Ensuring Jibri uses Docker internal URL ===${NC}"

if ! grep -q "PUBLIC_URL=https://jitsi-web:443" docker-compose.yml; then
  sed -i '/^        depends_on:/i\            - PUBLIC_URL=https://jitsi-web:443' docker-compose.yml
fi

echo -e "\n${GREEN}=== Starting services ===${NC}"
docker compose -f docker-compose.yml -f jibri-pool.yml up -d

echo -e "\n${GREEN}=== Waiting for services to be ready ===${NC}"
sleep 15

if [ "$ENABLE_LETSENCRYPT" = "0" ]; then
  echo -e "${GREEN}Regenerating nginx SSL cert with correct CN...${NC}"
  docker compose exec -u root web sh -c "
        rm -f /config/keys/cert.crt /config/keys/cert.key
        /usr/local/bin/self-signed-cert.sh
    " 2>/dev/null || true

  docker compose exec -u root web nginx -s reload 2>/dev/null || true
  docker compose exec -u root web sh -c 'kill -HUP 1' 2>/dev/null || true
fi

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$MODE" = "1" ] || [ "$MODE" = "localhost" ]; then
  echo "  Access: https://localhost:${HTTPS_PORT}"
else
  if [ "$HTTPS_PORT" = "443" ]; then
    echo "  Access: https://${SERVER_IP}"
  else
    echo "  Access: https://${SERVER_IP}:${HTTPS_PORT}"
  fi
fi

echo ""
echo "Running containers:"
docker compose -f docker-compose.yml -f jibri-pool.yml ps --format "table {{.Names}}\t{{.Status}}"

echo ""
echo -e "${YELLOW}Recordings are saved to:${NC} $SCRIPT_DIR/recordings/"
echo ""
