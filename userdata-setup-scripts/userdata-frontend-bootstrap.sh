#!/bin/bash
# =============================================================================
#  AWS EC2 User Data — Tier 1 Bootstrap
#  Application : BMI Health Tracker
#
#  PURPOSE: This is the file you paste into EC2 "User Data" when launching
#           a new frontend/web-server instance.  It downloads the full setup
#           script (tier1-frontend.sh) from GitHub and runs it.
#
#  USAGE:
#    1. Change the variables in the "CONFIGURE HERE" block below.
#    2. Paste the entire file into EC2 -> Advanced Details -> User Data.
#    3. Launch the instance.
#
#  +----------------------------------+--------+------------------+----------------------+-------------+
#  | Scenario                         | MODE   | BACKEND_HOST     | DOMAIN               | DB_PASSWORD |
#  +----------------------------------+--------+------------------+----------------------+-------------+
#  | Multi-server + private + ALB     | alb    | 10.0.x.x (BE IP) | (empty)              | (empty)     |
#  +----------------------------------+--------+------------------+----------------------+-------------+
#  | Multi-server + public IP         | public | 10.0.x.x (BE IP) | (empty) = plain HTTP | (empty)     |
#  |   no domain -> plain HTTP        |        |                  | yourdomain.com =     |             |
#  |   domain   -> Let's Encrypt HTTPS|        |                  | Let's Encrypt HTTPS  |             |
#  |   (Route53 A record -> public IP |        |                  | (set Route53 first)  |             |
#  |    must exist before launch)     |        |                  |                      |             |
#  +----------------------------------+--------+------------------+----------------------+-------------+
#  | Single-server + private + ALB    | alb    | localhost        | (empty)              | "yourpass"  |
#  |   DB+Backend auto-installed      |        |                  |                      |             |
#  +----------------------------------+--------+------------------+----------------------+-------------+
#  | Single-server + public IP        | public | localhost        | (empty) = plain HTTP | "yourpass"  |
#  |   no domain -> plain HTTP        |        |                  | yourdomain.com =     |             |
#  |   domain   -> Let's Encrypt HTTPS|        |                  | Let's Encrypt HTTPS  |             |
#  |   (Route53 A record -> public IP |        |                  | (set Route53 first)  |             |
#  |    must exist before launch)     |        |                  |                      |             |
#  +----------------------------------+--------+------------------+----------------------+-------------+
#
#  Logs  -> /var/log/bmi-frontend-setup.log
#  Done  -> /etc/bmi-frontend-setup.done
# =============================================================================

# ============================================================
#  CONFIGURE HERE — change these variables before deploying
# ============================================================
MODE="alb"                   # alb  OR  public
BACKEND_HOST="localhost"     # localhost  OR  10.0.x.x (backend private IP)
DOMAIN=""                    # empty = plain HTTP
                             # yourdomain.com = Let's Encrypt HTTPS
                             #   (create Route53 A record -> EC2 public IP first)
CERT_EMAIL="you@example.com" # email for Let's Encrypt registration (ignored if DOMAIN empty)
DB_PASSWORD=""               # empty    = multi-server (frontend EC2 only)
                             # "secret" = single-server: DB + Backend + Frontend
                             #            all installed on this EC2.
                             #            Only used when BACKEND_HOST=localhost.
# ============================================================

SCRIPT_URL="https://raw.githubusercontent.com/sarowar-alam/multi-server-three-tier-app/main/userdata-setup-scripts/tier1-frontend.sh"

# Build argument list
ARGS="-Mode=${MODE} -BackendHost=${BACKEND_HOST}"
[ -n "${DOMAIN}"      ] && ARGS="${ARGS} -Domain=${DOMAIN}"
[ -n "${CERT_EMAIL}"  ] && ARGS="${ARGS} -CertEmail=${CERT_EMAIL}"
[ -n "${DB_PASSWORD}" ] && ARGS="${ARGS} -DbPassword=${DB_PASSWORD}"

echo "[bootstrap] Downloading tier1-frontend.sh from GitHub..."
curl -fsSL "${SCRIPT_URL}" -o /tmp/tier1-frontend.sh
chmod +x /tmp/tier1-frontend.sh

echo "[bootstrap] Running setup with args: ${ARGS}"
# shellcheck disable=SC2086
bash /tmp/tier1-frontend.sh ${ARGS}

# =============================================================================
#  HOW TO VERIFY (run these after the instance is ready via SSM Session Manager)
#
#  # Check setup completed:
#    cat /etc/bmi-frontend-setup.done
#
#  # View setup log:
#    sudo tail -100 /var/log/bmi-frontend-setup.log
#
#  # Test Nginx (ALB mode OR public mode with no domain -- plain HTTP):
#    curl -s -o /dev/null -w "%{http_code}" http://localhost/
#    # Expected: 200
#
#  # Test Nginx (public mode + domain -- Let's Encrypt HTTPS):
#    curl -s -o /dev/null -w "%{http_code}" https://yourdomain.com/
#    # Expected: 200
#
#  # Test API proxy:
#    curl http://localhost/api/measurements?limit=1
#    # Expected: {"rows":[...]}
#
#  # Test health endpoint proxy:
#    curl http://localhost/health
#    # Expected: {"status":"ok"}
#
#  # View Nginx status:
#    sudo systemctl status nginx
#    sudo nginx -t
#
#  # Single-server only -- verify all three tiers installed:
#    cat /etc/bmi-db-setup.done
#    cat /etc/bmi-backend-setup.done
#    sudo pm2 list
# =============================================================================
