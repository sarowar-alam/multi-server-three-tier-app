#!/bin/bash
# =============================================================================
#  AWS EC2 User Data — Tier 3: Database Server
#  Application : BMI Health Tracker
#  OS          : Ubuntu 22.04 / 24.04 LTS
#  PostgreSQL  : 15
#
#  Entry point : fetched from GitHub raw and piped to bash
#    curl -fsSL <raw_url> | bash
#
#  Prerequisites (created before launching this instance):
#    - AWS SSM SecureString parameter  /bmi/db-password
#    - IAM instance profile with SSM Session Manager + ssm:GetParameter
#
#  Logs → /var/log/bmi-db-setup.log
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/bmi-db-setup.log) 2>&1

echo "================================================================"
echo " BMI DB Tier — setup started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"

# ── Static config ─────────────────────────────────────────────────────────────
DB_NAME="bmi_health"
DB_USER="bmi_user"
PG_VERSION="15"

# ── 0. Detect region + fetch DB password from SSM Parameter Store ─────────────
echo "[0/6] Detecting region via IMDSv2..."
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)
echo "  Region: ${AWS_REGION}"

# Fetch the VPC CIDR to lock pg_hba.conf to the VPC range (defense-in-depth)
MAC=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | head -1)
VPC_CIDR=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}vpc-ipv4-cidr-blocks" \
  | head -1)
echo "  VPC CIDR: ${VPC_CIDR}"

echo "[0/6] Fetching DB password from SSM Parameter Store (/bmi/db-password)..."
DB_PASSWORD=$(aws ssm get-parameter \
  --name "/bmi/db-password" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region "${AWS_REGION}")

if [ -z "${DB_PASSWORD}" ]; then
  echo "ERROR: Could not fetch /bmi/db-password from SSM. Aborting." >&2
  exit 1
fi
echo "  DB password fetched successfully."

# ── 1. System update ──────────────────────────────────────────────────────────
echo "[1/6] Updating system packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ── 2. Install PostgreSQL 15 from the official PostgreSQL APT repo ────────────
echo "[2/6] Installing PostgreSQL ${PG_VERSION}..."
apt-get install -y -qq gnupg curl lsb-release

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list

apt-get update -qq
apt-get install -y -qq postgresql-${PG_VERSION} postgresql-contrib-${PG_VERSION}
echo "  PostgreSQL ${PG_VERSION} installed."

# ── 3. Enable and start service ───────────────────────────────────────────────
echo "[3/6] Starting PostgreSQL service..."
systemctl enable postgresql
systemctl start  postgresql

# ── 4. Create DB role, database, and run schema migration ────────────────────
echo "[4/6] Creating role '${DB_USER}', database '${DB_NAME}', running migration..."

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE ROLE "${DB_USER}" WITH LOGIN PASSWORD '${DB_PASSWORD}';
    RAISE NOTICE 'Role ${DB_USER} created.';
  ELSE
    ALTER ROLE "${DB_USER}" WITH PASSWORD '${DB_PASSWORD}';
    RAISE NOTICE 'Role ${DB_USER} already exists — password refreshed.';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE "${DB_NAME}" OWNER "${DB_USER}"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '${DB_NAME}'
)\gexec

GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME}" TO "${DB_USER}";
SQL

# Schema migration — embedded from database/migrations/001_create_measurements.sql
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" <<'MIGRATION'
CREATE TABLE IF NOT EXISTS measurements (
  id               SERIAL PRIMARY KEY,
  weight_kg        NUMERIC(5,2)  NOT NULL CHECK (weight_kg > 20 AND weight_kg < 500),
  height_cm        NUMERIC(5,2)  NOT NULL CHECK (height_cm > 0  AND height_cm < 300),
  age              INTEGER       NOT NULL CHECK (age > 0         AND age < 150),
  sex              VARCHAR(10)   NOT NULL CHECK (sex IN ('male', 'female')),
  activity_level   VARCHAR(30)            CHECK (activity_level IN
                     ('sedentary','light','moderate','active','very_active')),
  bmi              NUMERIC(4,1)  NOT NULL,
  bmi_category     VARCHAR(30),
  bmr              INTEGER,
  daily_calories   INTEGER,
  measurement_date DATE          NOT NULL DEFAULT CURRENT_DATE,
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_measurements_measurement_date
  ON measurements(measurement_date DESC);
CREATE INDEX IF NOT EXISTS idx_measurements_created_at
  ON measurements(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_measurements_bmi
  ON measurements(bmi);

COMMENT ON TABLE  measurements                  IS 'Stores user health measurements';
COMMENT ON COLUMN measurements.weight_kg        IS 'Weight in kilograms';
COMMENT ON COLUMN measurements.height_cm        IS 'Height in centimeters';
COMMENT ON COLUMN measurements.age              IS 'Age in years';
COMMENT ON COLUMN measurements.sex              IS 'Biological sex (male/female)';
COMMENT ON COLUMN measurements.activity_level   IS 'Physical activity level';
COMMENT ON COLUMN measurements.bmi              IS 'Body Mass Index';
COMMENT ON COLUMN measurements.bmi_category     IS 'BMI category';
COMMENT ON COLUMN measurements.bmr              IS 'Basal Metabolic Rate in calories';
COMMENT ON COLUMN measurements.daily_calories   IS 'Daily calorie needs based on activity';
COMMENT ON COLUMN measurements.measurement_date IS 'Date of measurement';

GRANT SELECT, INSERT, UPDATE, DELETE ON measurements        TO bmi_user;
GRANT USAGE, SELECT ON SEQUENCE measurements_id_seq         TO bmi_user;

SELECT 'Migration 001 completed successfully' AS status;
MIGRATION

echo "  Schema migration complete."

# ── 5. Harden PostgreSQL network configuration ────────────────────────────────
echo "[5/6] Hardening PostgreSQL network config..."
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"

# Backup originals on first run only (idempotent)
[ -f "${PG_CONF_DIR}/pg_hba.conf.orig" ]     || cp "${PG_CONF_DIR}/pg_hba.conf"     "${PG_CONF_DIR}/pg_hba.conf.orig"
[ -f "${PG_CONF_DIR}/postgresql.conf.orig" ]  || cp "${PG_CONF_DIR}/postgresql.conf" "${PG_CONF_DIR}/postgresql.conf.orig"

# pg_hba.conf — allow connections only from within this VPC CIDR
# AWS Security Group on this instance is the primary firewall (port 5432 from App SG only)
# pg_hba.conf is defense-in-depth: restricts at the PostgreSQL layer too
cat > "${PG_CONF_DIR}/pg_hba.conf" <<HBAEOF
# TYPE  DATABASE    USER        ADDRESS         METHOD
# Local superuser (maintenance on the DB host)
local   all         postgres                    peer
local   all         all                         peer
# Allow App Tier connections within the VPC — AWS SG is the primary guard
host    ${DB_NAME}  ${DB_USER}  ${VPC_CIDR}     scram-sha-256
HBAEOF

# Listen on all interfaces — AWS Security Group controls who can reach port 5432
sed -i "s/^#*listen_addresses\s*=.*/listen_addresses = '*'/"   "${PG_CONF_DIR}/postgresql.conf"
sed -i "s/^#*max_connections\s*=.*/max_connections = 100/"     "${PG_CONF_DIR}/postgresql.conf"

systemctl restart postgresql
echo "  PostgreSQL restarted with hardened config."

# ── 6. Smoke test + completion marker ─────────────────────────────────────────
echo "[6/6] Running smoke test..."
if sudo -u postgres psql -d "${DB_NAME}" -c "SELECT COUNT(*) FROM measurements;" > /dev/null 2>&1; then
  echo "  Smoke test PASSED — measurements table is accessible."
else
  echo "ERROR: smoke test failed. Check /var/log/bmi-db-setup.log" >&2
  exit 1
fi

cat > /etc/bmi-db-setup.done <<MARKER
setup_completed=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
db_name=${DB_NAME}
db_user=${DB_USER}
pg_version=${PG_VERSION}
vpc_cidr=${VPC_CIDR}
region=${AWS_REGION}
MARKER

echo ""
echo "================================================================"
echo " Database Tier setup COMPLETE $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  PostgreSQL : ${PG_VERSION}"
echo "  Database   : ${DB_NAME}"
echo "  Role       : ${DB_USER}"
echo "  VPC CIDR   : ${VPC_CIDR} (allowed in pg_hba.conf)"
echo "  Listening  : 0.0.0.0:5432 (SG-guarded)"
echo "  Password   : fetched from SSM /bmi/db-password"
echo "  Log        : /var/log/bmi-db-setup.log"
echo "================================================================"