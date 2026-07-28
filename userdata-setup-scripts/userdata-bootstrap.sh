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

# =============================================================================
#  POST-INSTALL VALIDITY CHECKS
#  Results written to /var/log/bmi-db-validation.log and printed to cloud-init
# =============================================================================
VALIDATE_LOG="/var/log/bmi-db-validation.log"
PASS=0
FAIL=0

check() {
  local label="$1"
  local result="$2"   # 0 = pass, non-zero = fail
  if [ "$result" -eq 0 ]; then
    echo "  [PASS] ${label}" | tee -a "$VALIDATE_LOG"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${label}" | tee -a "$VALIDATE_LOG"
    FAIL=$((FAIL + 1))
  fi
}

echo "" | tee -a "$VALIDATE_LOG"
echo "================================================================" | tee -a "$VALIDATE_LOG"
echo " VALIDITY CHECKS — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"            | tee -a "$VALIDATE_LOG"
echo "================================================================" | tee -a "$VALIDATE_LOG"

# 1. Completion marker written by the setup script
check "Setup completion marker exists (/etc/bmi-db-setup.done)" \
  $([ -f /etc/bmi-db-setup.done ] && echo 0 || echo 1)

# 2. PostgreSQL service is active
systemctl is-active --quiet postgresql
check "PostgreSQL service is active" $?

# 3. PostgreSQL is listening on port 5432
ss -tlnp | grep -q ':5432'
check "PostgreSQL listening on port 5432" $?

# 4. Database bmi_health exists
sudo -u postgres psql -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw bmi_health
check "Database 'bmi_health' exists" $?

# 5. Role bmi_user exists
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='bmi_user';" 2>/dev/null | grep -q 1
check "Role 'bmi_user' exists" $?

# 6. measurements table exists with correct columns
sudo -u postgres psql -d bmi_health -tAc \
  "SELECT COUNT(*) FROM information_schema.columns WHERE table_name='measurements';" 2>/dev/null \
  | grep -qE '^1[0-9]$'
check "Table 'measurements' exists with expected columns (≥10)" $?

# 7. Indexes exist
sudo -u postgres psql -d bmi_health -tAc \
  "SELECT COUNT(*) FROM pg_indexes WHERE tablename='measurements';" 2>/dev/null \
  | grep -qE '^[3-9]$'
check "Indexes on 'measurements' table exist (≥3)" $?

# 8. bmi_user can connect and query the table
sudo -u postgres psql -d bmi_health -c \
  "SET ROLE bmi_user; SELECT COUNT(*) FROM measurements;" > /dev/null 2>&1
check "Role 'bmi_user' can SELECT from 'measurements'" $?

# 9. listen_addresses is set to '*' (not localhost-only)
grep -q "listen_addresses = '\*'" /etc/postgresql/15/main/postgresql.conf 2>/dev/null
check "postgresql.conf: listen_addresses = '*'" $?

# 10. pg_hba.conf contains scram-sha-256 entry for bmi_health
grep -q "scram-sha-256" /etc/postgresql/15/main/pg_hba.conf 2>/dev/null
check "pg_hba.conf: scram-sha-256 auth entry present" $?

# ── Summary ──────────────────────────────────────────────────────────────────
echo "" | tee -a "$VALIDATE_LOG"
echo "  Results: ${PASS} passed, ${FAIL} failed" | tee -a "$VALIDATE_LOG"
echo "================================================================" | tee -a "$VALIDATE_LOG"

if [ "$FAIL" -eq 0 ]; then
  echo "  OVERALL: SUCCESS — database tier is fully operational" | tee -a "$VALIDATE_LOG"
  echo "VALIDATION=SUCCESS" >> /etc/bmi-db-setup.done
else
  echo "  OVERALL: FAILED — see ${VALIDATE_LOG} for details"    | tee -a "$VALIDATE_LOG"
  echo "VALIDATION=FAILED (${FAIL} checks failed)"              >> /etc/bmi-db-setup.done
fi
echo "================================================================" | tee -a "$VALIDATE_LOG"