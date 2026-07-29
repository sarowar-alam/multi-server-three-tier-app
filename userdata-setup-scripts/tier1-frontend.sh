#!/bin/bash
# =============================================================================
#  AWS EC2 User Data — Tier 1: Web Server (Nginx + React Frontend)
#  Application : BMI Health Tracker
#  OS          : Ubuntu 22.04 / 24.04 LTS
#
#  Handles all 4 deployment scenarios via -Mode and -BackendHost:
#
#    -Mode=alb    Nginx serves HTTP:80 only. ALB terminates SSL upstream.
#                 ALB + ACM certificate setup is manual (AWS Console/CLI).
#
#    -Mode=public Nginx handles SSL on :443, redirects HTTP:80 -> HTTPS.
#                 -CertMode=selfsigned  openssl cert (works with IP, browser warns)
#                 -CertMode=letsencrypt certbot cert (needs a real domain)
#
#  Single-server (frontend + backend + DB on one EC2):
#    Pass -BackendHost=localhost  — script reuses Node.js if already installed.
#
#  Parameters:
#    -Mode=alb|public              REQUIRED
#    -BackendHost=IP|localhost     default: localhost
#    -BackendPort=3000             default: 3000
#    -Domain=yourdomain.com        required for -CertMode=letsencrypt
#    -CertMode=letsencrypt|selfsigned
#                                  auto-detected: letsencrypt if -Domain set,
#                                  selfsigned otherwise (public mode only)
#    -CertEmail=admin@example.com  Let's Encrypt registration email
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
CERT_MODE=""
CERT_EMAIL="admin@example.com"

for arg in "$@"; do
  case $arg in
    -Mode=*|--Mode=*)               MODE="${arg#*=}"         ;;
    -BackendHost=*|--BackendHost=*) BACKEND_HOST="${arg#*=}" ;;
    -BackendPort=*|--BackendPort=*) BACKEND_PORT="${arg#*=}" ;;
    -Domain=*|--Domain=*)           DOMAIN="${arg#*=}"       ;;
    -CertMode=*|--CertMode=*)       CERT_MODE="${arg#*=}"    ;;
    -CertEmail=*|--CertEmail=*)     CERT_EMAIL="${arg#*=}"   ;;
  esac
done

# Validate mode
if [ -z "${MODE}" ]; then
  echo "ERROR: -Mode is required.  Usage: -Mode=alb  OR  -Mode=public" >&2; exit 1
fi
if [[ "${MODE}" != "alb" && "${MODE}" != "public" ]]; then
  echo "ERROR: -Mode must be 'alb' or 'public', got '${MODE}'" >&2; exit 1
fi

# Auto-detect CertMode for public mode
if [ "${MODE}" = "public" ] && [ -z "${CERT_MODE}" ]; then
  CERT_MODE="$( [ -n "${DOMAIN}" ] && echo letsencrypt || echo selfsigned )"
fi

if [ "${MODE}" = "public" ] && [ "${CERT_MODE}" = "letsencrypt" ] && [ -z "${DOMAIN}" ]; then
  echo "ERROR: -Domain is required when -CertMode=letsencrypt" >&2; exit 1
fi

APP_DIR="/opt/bmi-app"
DIST_DIR="/var/www/bmi-app/dist"
REPO_URL="https://github.com/sarowar-alam/multi-server-three-tier-app.git"
NGINX_CONF="/etc/nginx/sites-available/bmi-app"
SSL_DIR="/etc/ssl/bmi-app"

echo "  Mode         : ${MODE}"
echo "  Backend      : ${BACKEND_HOST}:${BACKEND_PORT}"
echo "  Domain       : ${DOMAIN:-none}"
echo "  Cert mode    : ${CERT_MODE:-n/a (alb mode)}"

# ---- 0. Detect region + instance IP via IMDSv2 ------------------------------
echo "[0/7] Detecting region via IMDSv2..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
INSTANCE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)
echo "  Region: ${AWS_REGION}  |  Private IP: ${INSTANCE_IP}"

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

if [ "${MODE}" = "public" ] && [ "${CERT_MODE}" = "letsencrypt" ]; then
  echo "  Installing certbot..."
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

# ---- ALB mode: HTTP:80 only, no SSL logic in Nginx --------------------------
if [ "${MODE}" = "alb" ]; then
  cat > "${NGINX_CONF}" <<NGINXEOF
# BMI Health Tracker -- ALB mode
# Nginx: HTTP:80 only.  ALB handles HTTPS + ACM certificate.
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
  echo "  Nginx ALB config written."
fi

# ---- Public mode: self-signed certificate -----------------------------------
if [ "${MODE}" = "public" ] && [ "${CERT_MODE}" = "selfsigned" ]; then
  echo "  Generating self-signed certificate..."
  mkdir -p "${SSL_DIR}"
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${SSL_DIR}/key.pem" \
    -out    "${SSL_DIR}/cert.pem" \
    -subj   "/C=BD/ST=Dhaka/L=Dhaka/O=BMIApp/CN=${DOMAIN:-${INSTANCE_IP}}" \
    2>/dev/null
  echo "  Self-signed certificate created (valid 10 years)."

  cat > "${NGINX_CONF}" <<NGINXEOF
# BMI Health Tracker -- Public mode, self-signed SSL
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl default_server;
    server_name ${DOMAIN:-_};

    ssl_certificate     ${SSL_DIR}/cert.pem;
    ssl_certificate_key ${SSL_DIR}/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options           "SAMEORIGIN"       always;
    add_header X-Content-Type-Options    "nosniff"          always;

    root  ${DIST_DIR};
    index index.html;

    include /etc/nginx/snippets/bmi-proxy.conf;
}
NGINXEOF
  echo "  Nginx self-signed SSL config written."
fi

# ---- Public mode: Let's Encrypt certificate ---------------------------------
if [ "${MODE}" = "public" ] && [ "${CERT_MODE}" = "letsencrypt" ]; then
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

if [ "${MODE}" = "alb" ]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
  [ "${CODE}" = "200" ] && echo "  PASSED -- HTTP:80 returned 200." \
    || echo "  WARNING: HTTP:80 returned ${CODE}"
fi

if [ "${MODE}" = "public" ] && [ "${CERT_MODE}" = "selfsigned" ]; then
  R=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
  S=$(curl -sk -o /dev/null -w "%{http_code}" https://localhost/)
  echo "  HTTP:80 -> ${R} (expect 301)"
  echo "  HTTPS:443 -> ${S} (expect 200)"
fi

if [ "${MODE}" = "public" ] && [ "${CERT_MODE}" = "letsencrypt" ]; then
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
cert_mode=${CERT_MODE:-n/a}
region=${AWS_REGION}
dist_dir=${DIST_DIR}
MARKER

echo ""
echo "================================================================"
echo " Web Tier setup COMPLETE $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Mode         : ${MODE}"
echo "  Backend      : ${BACKEND_HOST}:${BACKEND_PORT}"
if [ "${MODE}" = "public" ]; then
echo "  SSL          : ${CERT_MODE}"
echo "  Domain/IP    : ${DOMAIN:-${INSTANCE_IP}}"
fi
echo "  Dist         : ${DIST_DIR}"
echo "  Log          : /var/log/bmi-frontend-setup.log"
echo "================================================================"