#!/usr/bin/env bash
# Builds and runs the backend, database and frontend as plain `docker run` containers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
NETWORK="bmi-network"
USE_SUDO=0

docker_cmd() {
  if [ "$USE_SUDO" = "1" ]; then sudo docker "$@"; else docker "$@"; fi
}

install_docker() {
  echo "Docker not found — installing Docker Engine (official apt repo)..."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
}

if [ -f /etc/os-release ]; then . /etc/os-release; fi
if [ "${ID:-}" != "ubuntu" ]; then
  echo "Warning: this script targets Ubuntu (detected ID=${ID:-unknown}); apt-based install may not work." >&2
fi

if ! command -v docker >/dev/null 2>&1; then
  install_docker
else
  echo "Docker already installed: $(docker --version)"
fi

if ! groups "$USER" | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER" || true
  echo "Added $USER to the docker group — log out/in for passwordless docker access (using sudo for this run)."
  USE_SUDO=1
fi
docker info >/dev/null 2>&1 || USE_SUDO=1

if [ ! -f "$ENV_FILE" ]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example — edit it with a real POSTGRES_PASSWORD, then rerun this script." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

docker_cmd network inspect "$NETWORK" >/dev/null 2>&1 || docker_cmd network create "$NETWORK"

# --- Database (preserve existing container/data across reruns) ---
if ! docker_cmd ps -aq -f "name=^db$" | grep -q .; then
  docker_cmd run -d --name db --network "$NETWORK" --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -v bmi-db-data:/var/lib/postgresql/data \
    -v "$ROOT_DIR/database/migrations":/docker-entrypoint-initdb.d:ro \
    --health-cmd="pg_isready -U $POSTGRES_USER -d $POSTGRES_DB" \
    --health-interval=5s --health-timeout=5s --health-retries=10 \
    postgres:16-alpine
else
  docker_cmd start db >/dev/null
fi

echo "Waiting for database to become healthy..."
until [ "$(docker_cmd inspect -f '{{.State.Health.Status}}' db)" = "healthy" ]; do
  sleep 2
done

# --- Backend (rebuild + recreate each run to pick up code changes) ---
docker_cmd build -f "$SCRIPT_DIR/backend/Dockerfile" -t bmi-backend "$ROOT_DIR"
docker_cmd rm -f backend >/dev/null 2>&1 || true
# -e overrides DATABASE_URL from --env-file with the bash-expanded value (docker's own env-file parsing doesn't interpolate)
docker_cmd run -d --name backend --network "$NETWORK" --restart unless-stopped --env-file "$ENV_FILE" -e "DATABASE_URL=$DATABASE_URL" bmi-backend

# --- Frontend (rebuild + recreate each run; only container publishing a host port) ---
docker_cmd build -f "$SCRIPT_DIR/frontend/Dockerfile" -t bmi-frontend "$ROOT_DIR"
docker_cmd rm -f frontend >/dev/null 2>&1 || true
docker_cmd run -d --name frontend --network "$NETWORK" --restart unless-stopped -p 80:80 bmi-frontend

echo "Done. App available at http://<this-server-ip>/"
