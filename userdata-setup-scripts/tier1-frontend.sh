#!/bin/bash
# =============================================================================
#  AWS EC2 User Data — Tier 1: Web Server (Nginx + React Frontend)
#  Application : BMI Health Tracker
#  OS          : Ubuntu 22.04 / 24.04 LTS
#
#  Handles all 4 deployment scenarios:
#
#  1. Multi-server + private subnet + ALB
#       -Mode=alb  -BackendHost=10.0.x.x
#       Nginx: HTTP:80 only. ALB terminates HTTPS + ACM cert (manual in AWS).
#
#  2. Multi-server + public IP (direct access)
#       -Mode=public  -BackendHost=10.0.x.x
#       No domain  -> Nginx: HTTP:80 only (no certificate).
#       With domain -> Nginx: HTTPS:443 via Let's Encrypt (certbot).
#                      Route53 A record pointing to this EC2's public IP
#                      must be created manually before running the script.
#
#  3. Single-server + private subnet + ALB
#       -Mode=alb  -BackendHost=localhost  -DbPassword=secret
#       tier3-database.sh + tier2-backend.sh are run automatically first.
#       Node.js reused by frontend build (already installed by tier2).
#
#  4. Single-server + public IP (direct access)
#       -Mode=public  -BackendHost=localhost  -DbPassword=secret
#       No domain  -> HTTP:80 only.
#       With domain -> HTTPS:443 via Let's Encrypt.
#
#  Parameters:
#    -Mode=alb|public              REQUIRED
#    -BackendHost=IP|localhost     default: localhost
#    -BackendPort=3000             default: 3000
#    -Domain=yourdomain.com        optional; triggers Let's Encrypt when set
#    -CertEmail=admin@example.com  Let's Encrypt registration email
#    -DbPassword=secret            single-server only: set this to trigger
#                                  automatic DB + Backend install on this EC2
#                                  (ignored when BACKEND_HOST != localhost)
#
#  Logs -> /var/log/bmi-frontend-setup.log
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/bmi-frontend-setup.log) 2>&1

echo "================================================================"
echo " BMI Web Tier -- setup started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"

# ---- Parse arguments --------------------------------------------------------
MODE=""
BACKEND_HOST="localhost"
BACKEND_PORT="3000"
DOMAIN=""
CERT_EMAIL="admin@example.com"
DB_PASSWORD=""   # set for single-server: triggers DB+Backend install

for arg in "$@"; do
  case $arg in
    -Mode=*|--Mode=*)               MODE="${arg#*=}"         ;;
    -BackendHost=*|--BackendHost=*) BACKEND_HOST="${arg#*=}" ;;
    -BackendPort=*|--BackendPort=*) BACKEND_PORT="${arg#*=}" ;;
    -Domain=*|--Domain=*)           DOMAIN="${arg#*=}"       ;;
    -CertEmail=*|--CertEmail=*)     CERT_EMAIL="${arg#*=}"   ;;
    -DbPassword=*|--DbPassword=*)   DB_PASSWORD="${arg#*=}"  ;;
  esac
done

# Validate mode
if [ -z "${MODE}" ]; then
  echo "ERROR: -Mode is required.  Usage: -Mode=alb  OR  -Mode=public" >&2; exit 1
fi
if [[ "${MODE}" != "alb" && "${MODE}" != "public" ]]; then
  echo "ERROR: -Mode must be 'alb' or 'public', got '${MODE}'" >&2; exit 1
fi

APP_DIR="/opt/bmi-app"
DIST_DIR="/var/www/bmi-app/dist"
REPO_URL="https://github.com/sarowar-alam/three-tier-aws-deployment.git"
NGINX_CONF="/etc/nginx/sites-available/bmi-app"

echo "  Mode         : ${MODE}"
echo "  Backend      : ${BACKEND_HOST}:${BACKEND_PORT}"
echo "  Domain       : ${DOMAIN:-none (plain HTTP)}"
if [ "${MODE}" = "public" ]; then
  [ -n "${DOMAIN}" ] \
    && echo "  SSL          : Let's Encrypt (certbot)" \
    || echo "  SSL          : none (plain HTTP, no domain provided)"
fi

# ---- 0. Detect region + instance IP via IMDSv2 ------------------------------
echo "[0/7] Detecting region via IMDSv2..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
echo "  Region: ${AWS_REGION}  |  Private IP: ${INSTANCE_IP}"

# ---- Single-server: install DB + Backend before frontend -------------------
# Triggered when: BACKEND_HOST=localhost AND DB_PASSWORD is non-empty.
# Downloads and runs tier3-database.sh then tier2-backend.sh in sequence,
# so the user never needs to run the sed command or extra steps manually.
if [ "${BACKEND_HOST}" = "localhost" ] && [ -n "${DB_PASSWORD}" ]; then
  echo ""
  echo "================================================================"
  echo " Single-server mode: installing DB + Backend first"
  echo "================================================================"

  # Resolve the public IP so the backend .env gets the correct FRONTEND_URL
  PUBLIC_IP=$(curl -s --max-time 3 -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
  if [ -n "${DOMAIN}" ]; then
    FRONTEND_URL_BE="https://${DOMAIN}"
  elif [ -n "${PUBLIC_IP}" ]; then
    FRONTEND_URL_BE="http://${PUBLIC_IP}"
  else
    FRONTEND_URL_BE="*"
  fi
  echo "  CORS Frontend URL : ${FRONTEND_URL_BE}"

  RAW_BASE="https://raw.githubusercontent.com/sarowar-alam/three-tier-aws-deployment/main/userdata-setup-scripts"

  echo "[S1/3] Downloading and running tier3-database.sh..."
  curl -fsSL "${RAW_BASE}/tier3-database.sh" -o /tmp/tier3-database.sh
  chmod +x /tmp/tier3-database.sh
  bash /tmp/tier3-database.sh -Password="${DB_PASSWORD}"
  echo "[S1/3] Database setup complete."

  echo "[S2/3] Downloading and running tier2-backend.sh..."
  curl -fsSL "${RAW_BASE}/tier2-backend.sh" -o /tmp/tier2-backend.sh
  chmod +x /tmp/tier2-backend.sh
  bash /tmp/tier2-backend.sh \
    -DbPassword="${DB_PASSWORD}" \
    -DbHost="localhost" \
    -FrontendUrl="${FRONTEND_URL_BE}"
  echo "[S2/3] Backend setup complete."

  echo "[S3/3] DB+Backend done. Continuing with Nginx + React build..."
  echo "================================================================"
fi

# ---- 1. System update -------------------------------------------------------
echo "[1/7] Updating system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ---- 2. Node.js 22 (skip if already present -- single-server reuse) ---------
echo "[2/7] Checking Node.js..."
if ! command -v node &>/dev/null; then
  echo "  Node.js not found -- installing from NodeSource..."
  apt-get install -y -qq curl gnupg
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
  echo "  Node.js $(node --version) installed."
else
  echo "  Node.js $(node --version) already present -- skipping install."
fi

# ---- 3. Nginx + certbot (if needed) -----------------------------------------
echo "[3/7] Installing Nginx..."
apt-get install -y -qq nginx

if [ "${MODE}" = "public" ] && [ -n "${DOMAIN}" ]; then
  echo "  Installing certbot (domain set: ${DOMAIN})..."
  apt-get install -y -qq certbot python3-certbot-nginx
fi

systemctl enable nginx

# ---- 4. Clone / update repo and build React frontend -----------------------
echo "[4/7] Building React frontend..."

if [ -d "${APP_DIR}/.git" ]; then
  echo "  Repo exists -- pulling latest..."
  git -C "${APP_DIR}" pull --ff-only
else
  git clone "${REPO_URL}" "${APP_DIR}"
fi

cd "${APP_DIR}/frontend"
npm ci
npm run build
echo "  Build complete -> ${APP_DIR}/frontend/dist"

mkdir -p "${DIST_DIR}"
cp -r "${APP_DIR}/frontend/dist/." "${DIST_DIR}/"
echo "  Deployed to ${DIST_DIR}"

# ---- 5. Nginx configuration -------------------------------------------------
echo "[5/7] Writing Nginx config (mode: ${MODE})..."

rm -f /etc/nginx/sites-enabled/default
mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

# Shared proxy block written to a snippet for reuse in both server blocks
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/bmi-proxy.conf <<PROXY
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    location /api/ {
        proxy_pass         http://${BACKEND_HOST}:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Connection        "";
        proxy_connect_timeout 10s;
        proxy_read_timeout    30s;
    }
    location /health {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT}/health;
        proxy_set_header Host \$host;
    }
    location ~ /\. { deny all; }
PROXY

# ---- ALB mode OR public-no-domain: HTTP:80 only ----------------------------
if [ "${MODE}" = "alb" ] || { [ "${MODE}" = "public" ] && [ -z "${DOMAIN}" ]; }; then
  LABEL="$( [ "${MODE}" = "alb" ] && echo 'ALB mode -- ALB handles HTTPS + ACM certificate' || echo 'Public mode, no domain -- plain HTTP' )"
  cat > "${NGINX_CONF}" <<NGINXEOF
# BMI Health Tracker -- ${LABEL}
server {
    listen 80 default_server;
    server_name _;

    root  ${DIST_DIR};
    index index.html;

    add_header X-Frame-Options        "SAMEORIGIN"    always;
    add_header X-Content-Type-Options "nosniff"       always;
    add_header X-XSS-Protection       "1; mode=block" always;

    include /etc/nginx/snippets/bmi-proxy.conf;
}
NGINXEOF
  echo "  Nginx HTTP:80 config written (${MODE})."
fi

# ---- Public mode + domain: Let's Encrypt certificate -----------------------
if [ "${MODE}" = "public" ] && [ -n "${DOMAIN}" ]; then
  # Write HTTP-only config first so certbot can complete ACME HTTP-01 challenge
  cat > "${NGINX_CONF}" <<NGINXEOF
# BMI Health Tracker -- Public mode, Let's Encrypt (pre-certbot)
server {
    listen 80 default_server;
    server_name ${DOMAIN};

    root  ${DIST_DIR};
    index index.html;

    include /etc/nginx/snippets/bmi-proxy.conf;
}
NGINXEOF
  ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/bmi-app
  nginx -t && systemctl start nginx

  echo "  Obtaining Let's Encrypt certificate for ${DOMAIN}..."
  certbot --nginx \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --email "${CERT_EMAIL}" \
    --redirect
  echo "  Let's Encrypt certificate obtained. Auto-renewal enabled by certbot."
fi

# ---- 6. Enable site and restart Nginx ---------------------------------------
echo "[6/7] Enabling Nginx site..."
ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/bmi-app
nginx -t
systemctl restart nginx
echo "  Nginx restarted."

# ---- 7. Smoke test ----------------------------------------------------------
echo "[7/7] Smoke test..."
sleep 2

if [ "${MODE}" = "alb" ] || { [ "${MODE}" = "public" ] && [ -z "${DOMAIN}" ]; }; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
  [ "${CODE}" = "200" ] && echo "  PASSED -- HTTP:80 returned 200." \
    || echo "  WARNING: HTTP:80 returned ${CODE}"
fi

if [ "${MODE}" = "public" ] && [ -n "${DOMAIN}" ]; then
  S=$(curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN}/")
  echo "  HTTPS://${DOMAIN}/ -> ${S} (expect 200)"
fi

# ---- Completion marker ------------------------------------------------------
cat > /etc/bmi-frontend-setup.done <<MARKER
setup_completed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
mode=${MODE}
backend_host=${BACKEND_HOST}
backend_port=${BACKEND_PORT}
domain=${DOMAIN:-none}
ssl=$( [ "${MODE}" = "public" ] && { [ -n "${DOMAIN}" ] && echo letsencrypt || echo none; } || echo n/a-alb )
region=${AWS_REGION}
dist_dir=${DIST_DIR}
MARKER

echo ""
echo "================================================================"
echo " Web Tier setup COMPLETE $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Mode         : ${MODE}"
echo "  Backend      : ${BACKEND_HOST}:${BACKEND_PORT}"
if [ "${MODE}" = "public" ]; then
  if [ -n "${DOMAIN}" ]; then
    echo "  SSL          : Let's Encrypt"
    echo "  Domain       : ${DOMAIN}"
  else
    echo "  SSL          : none (plain HTTP)"
    echo "  IP           : ${INSTANCE_IP}"
  fi
fi
echo "  Dist         : ${DIST_DIR}"
echo "  Log          : /var/log/bmi-frontend-setup.log"
echo "================================================================"