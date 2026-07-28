#!/bin/bash
# =============================================================================
#  AWS EC2 User Data — Tier 2: App Server (Node.js Backend)
#  Application : BMI Health Tracker
#  OS          : Ubuntu 22.04 / 24.04 LTS
#  Runtime     : Node.js 22 LTS + PM2
#
#  Entry point : fetched from GitHub raw and piped to bash
#    curl -fsSL <raw_url> | bash  (or via userdata-backend-bootstrap.sh)
#
#  Required parameters:
#    -DbPassword="..."   PostgreSQL bmi_user password
#    -DbHost="..."       Private IP (or hostname) of the Tier 3 DB server
#
#  Optional parameters:
#    -FrontendUrl="..."  Public IP/domain of Tier 1 Web server (default: *)
#    -Port="..."         API port (default: 3000)
#
#  Logs → /var/log/bmi-backend-setup.log
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/bmi-backend-setup.log) 2>&1

echo "================================================================"
echo " BMI App Tier — setup started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"

# ── Parse arguments ───────────────────────────────────────────────────────────
# Usage: bash tier2-backend.sh -DbPassword="secret" -DbHost="10.0.10.34"
DB_PASSWORD=""
DB_HOST=""
FRONTEND_URL="*"
APP_PORT="3000"

for arg in "$@"; do
  case $arg in
    -DbPassword=*|--DbPassword=*) DB_PASSWORD="${arg#*=}" ;;
    -DbHost=*|--DbHost=*)         DB_HOST="${arg#*=}"     ;;
    -FrontendUrl=*|--FrontendUrl=*) FRONTEND_URL="${arg#*=}" ;;
    -Port=*|--Port=*)             APP_PORT="${arg#*=}"    ;;
  esac
done

# Validate required parameters
if [ -z "${DB_PASSWORD}" ]; then
  echo "ERROR: -DbPassword is required. Aborting." >&2
  echo "  Usage: bash tier2-backend.sh -DbPassword=\"secret\" -DbHost=\"10.x.x.x\"" >&2
  exit 1
fi
if [ -z "${DB_HOST}" ]; then
  echo "ERROR: -DbHost is required. Aborting." >&2
  echo "  Usage: bash tier2-backend.sh -DbPassword=\"secret\" -DbHost=\"10.x.x.x\"" >&2
  exit 1
fi

DATABASE_URL="postgresql://bmi_user:${DB_PASSWORD}@${DB_HOST}:5432/bmi_health"
APP_DIR="/opt/bmi-app"
REPO_URL="https://github.com/sarowar-alam/multi-server-three-tier-app.git"
# User data runs as root — pin PM2_HOME to root's home so startup
# service and process list always use the same location.
export PM2_HOME=/root/.pm2

echo "  DB Host      : ${DB_HOST}"
echo "  Frontend URL : ${FRONTEND_URL}"
echo "  App Port     : ${APP_PORT}"
echo "  App Dir      : ${APP_DIR}"

# ── 0. Detect region via IMDSv2 ───────────────────────────────────────────────
echo "[0/6] Detecting region via IMDSv2..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
echo "  Region: ${AWS_REGION}"

# ── 1. System update ──────────────────────────────────────────────────────────
echo "[1/6] Updating system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ── 2. Install Node.js 22 LTS via NodeSource ──────────────────────────────────
echo "[2/6] Installing Node.js 22 LTS..."
apt-get install -y -qq curl gnupg
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "  Node.js $(node --version) installed."
echo "  npm    $(npm --version) installed."

# Install PM2 process manager globally
npm install -g pm2 --silent
echo "  PM2 $(pm2 --version) installed."

# ── 3. Clone repository ───────────────────────────────────────────────────────
echo "[3/6] Cloning repository..."
if [ -d "${APP_DIR}/.git" ]; then
  echo "  Repo already exists — pulling latest..."
  git -C "${APP_DIR}" pull --ff-only
else
  git clone "${REPO_URL}" "${APP_DIR}"
fi
echo "  Repository ready at ${APP_DIR}"

# ── 4. Install backend dependencies ───────────────────────────────────────────
echo "[4/6] Installing backend dependencies..."
cd "${APP_DIR}/backend"
# npm ci requires package-lock.json (committed to repo).
# --omit=dev skips devDependencies. Drop --silent so errors are visible.
npm ci --omit=dev
echo "  Dependencies installed."

# ── 5. Write .env file ────────────────────────────────────────────────────────
echo "[5/6] Writing .env..."
cat > "${APP_DIR}/backend/.env" <<ENV
PORT=${APP_PORT}
NODE_ENV=production
DATABASE_URL=${DATABASE_URL}
FRONTEND_URL=${FRONTEND_URL}
DB_POOL_SIZE=20
ENV
echo "  .env written."

# Verify DB connectivity before starting the app
echo "  Testing DB connection..."
if node -e "
const { Pool } = require('pg');
const pool = new Pool({ connectionString: '${DATABASE_URL}', connectionTimeoutMillis: 5000 });
pool.query('SELECT 1').then(() => { console.log('DB OK'); pool.end(); process.exit(0); })
  .catch(e => { console.error('DB FAIL:', e.message); pool.end(); process.exit(1); });
" 2>&1; then
  echo "  DB connection PASSED."
else
  echo "  WARNING: DB connection failed — check DB_HOST and DB_PASSWORD."
  echo "  Continuing setup — the app will retry connections at runtime."
fi

# ── 6. Start app with PM2 ─────────────────────────────────────────────────────
echo "[6/6] Starting app with PM2..."
cd "${APP_DIR}/backend"

if pm2 describe bmi-backend > /dev/null 2>&1; then
  pm2 reload bmi-backend --update-env
  echo "  PM2 process reloaded."
else
  pm2 start src/server.js \
    --name bmi-backend \
    --env production \
    --log /var/log/bmi-backend-pm2.log \
    --time
  echo "  PM2 process started."
fi

# Persist PM2 process list so it survives reboots
pm2 save
# Generate and enable systemd startup unit (running as root, so no sudo needed).
# Explicitly set PM2_HOME so the generated service uses /root/.pm2.
env PATH="$PATH:/usr/bin" PM2_HOME=/root/.pm2 pm2 startup systemd -u root --hp /root
systemctl enable pm2-root 2>/dev/null || true
echo "  PM2 startup enabled."

# ── Smoke test ────────────────────────────────────────────────────────────────
echo "  Running smoke test (GET /health)..."
sleep 3   # give Node.js a moment to bind the port
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:${APP_PORT}/health)
if [ "${HTTP_STATUS}" = "200" ]; then
  echo "  Smoke test PASSED — /health returned 200."
else
  echo "  WARNING: /health returned ${HTTP_STATUS} (app may still be starting)."
fi

# ── Completion marker ─────────────────────────────────────────────────────────
cat > /etc/bmi-backend-setup.done <<MARKER
setup_completed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
node_version=$(node --version)
pm2_version=$(pm2 --version)
app_port=${APP_PORT}
db_host=${DB_HOST}
frontend_url=${FRONTEND_URL}
region=${AWS_REGION}
MARKER

echo ""
echo "================================================================"
echo " App Tier setup COMPLETE $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Node.js     : $(node --version)"
echo "  PM2         : $(pm2 --version)"
echo "  App Port    : ${APP_PORT}"
echo "  DB Host     : ${DB_HOST}"
echo "  Frontend    : ${FRONTEND_URL}"
echo "  Log         : /var/log/bmi-backend-setup.log"
echo "  PM2 log     : /var/log/bmi-backend-pm2.log"
echo "================================================================"