#!/bin/bash
# =============================================================================
#  EC2 User Data Bootstrap — Tier 3: Database Server
#
#  Paste this entire file into the EC2 "User data" field.
#  Change DB_PASSWORD below before launching the instance.
#
#  With -Password set here:
#    - No IAM instance profile needed for SSM
#    - Runs on ANY Ubuntu 22.04/24.04 EC2 with outbound internet (NAT/public)
# =============================================================================

# ── Set password here (or leave empty to fetch from SSM /bmi/db-password) ────
DB_PASSWORD="0stad2025"
# ─────────────────────────────────────────────────────────────────────────────

curl -fsSL https://raw.githubusercontent.com/sarowar-alam/three-tier-aws-deployment/main/userdata-setup-scripts/tier3-database.sh -o /tmp/setup-db.sh
bash /tmp/setup-db.sh -Password="${DB_PASSWORD}"

# =============================================================================
#  VERIFY INSTALLATION — run these after SSM login:
#
#  $ aws ssm start-session --target i-08bdf7bc8b9e860a0 --profile sarowar-ostad --region ap-south-1
#
#  Check setup completed:
#    cat /etc/bmi-db-setup.done
#
#  Check full install log:
#    cat /var/log/bmi-db-setup.log
#
#  Check PostgreSQL is running (real cluster service, not the meta wrapper):
#    systemctl status postgresql@15-main.service
#
#  Check database and table exist:
#    sudo -u postgres psql -d bmi_health -c '\dt'
#
#  Check port is listening:
#    ss -tlnp | grep 5432
# =============================================================================