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

curl -fsSL https://raw.githubusercontent.com/sarowar-alam/multi-server-three-tier-app/main/userdata-setup-scripts/tier3-database.sh -o /tmp/setup-db.sh
bash /tmp/setup-db.sh -Password="${DB_PASSWORD}"