#!/bin/bash
# =============================================================================
#  EC2 User Data Bootstrap — Tier 2: App Server (Node.js Backend)
#
#  Paste this entire file into the EC2 "User data" field.
#  Set DB_PASSWORD and DB_HOST before launching the instance.
#
#  Parameters:
#    DB_PASSWORD   — PostgreSQL bmi_user password (same as used for Tier 3)
#    DB_HOST       — Private IP of the Tier 3 DB server  e.g. 10.0.10.34
#    FRONTEND_URL  — Public IP/domain of the Tier 1 Web server (optional)
# =============================================================================

# ── Set these before launching ────────────────────────────────────────────────
DB_PASSWORD="0stad2025"
DB_HOST="10.0.149.61"        # Private IP of the DB server (Tier 3)
FRONTEND_URL="*"             # Or set to http://WEB_SERVER_IP when known
# ─────────────────────────────────────────────────────────────────────────────

curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-three-tier-app/main/userdata-setup-scripts/tier2-backend.sh -o /tmp/setup-backend.sh
bash /tmp/setup-backend.sh \
  -DbPassword="${DB_PASSWORD}" \
  -DbHost="${DB_HOST}" \
  -FrontendUrl="${FRONTEND_URL}"

# =============================================================================
#  VERIFY INSTALLATION — run these after SSM login:
#
#  $ aws ssm start-session --target <instance-id> --profile sarowar-ostad --region ap-south-1
#
#  Check setup completed:
#    cat /etc/bmi-backend-setup.done
#
#  Check full install log:
#    cat /var/log/bmi-backend-setup.log
#
#  Check PM2 process is running:
#    pm2 status
#
#  Check health endpoint:
#    curl http://localhost:3000/health
#
#  Check PM2 app log:
#    pm2 logs bmi-backend --lines 50
# =============================================================================