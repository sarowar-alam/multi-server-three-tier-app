#!/usr/bin/env bash
# Builds and runs the backend, database and frontend via docker compose.
set -euo pipefail

# Skip BuildKit's git-based provenance attestation (avoids a benign "git rev-parse" warning)
export BUILDX_NO_DEFAULT_ATTESTATIONS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
USE_SUDO=0

compose_cmd() {
  if [ "$USE_SUDO" = "1" ]; then sudo docker compose "$@"; else docker compose "$@"; fi
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

if ! compose_cmd version >/dev/null 2>&1; then
  echo "docker compose plugin missing — installing..."
  sudo apt-get update
  sudo apt-get install -y docker-compose-plugin
fi

if [ ! -f "$ENV_FILE" ]; then
  cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
  echo "Created $ENV_FILE from .env.example — edit it with a real POSTGRES_PASSWORD, then rerun this script." >&2
  exit 1
fi

cd "$SCRIPT_DIR"
compose_cmd up -d --build
compose_cmd ps

# Prefer the cloud public IP (AWS IMDSv2) if reachable, else fall back to the primary local IP
SERVER_IP="$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $(curl -s --max-time 1 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null)" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
[ -n "$SERVER_IP" ] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "Done. App available at http://${SERVER_IP:-<this-server-ip>}/"
