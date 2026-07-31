# Userdata Setup Scripts — Scripted Deployment Guide

This folder is the **scripted alternative** to the fully-manual guide in the repo root
[README.md](../README.md). Instead of typing every command by hand, each tier has a
self-contained shell script that installs, configures, and verifies that tier automatically.

Everything here assumes real **AWS EC2 Ubuntu 22.04/24.04** instances — the scripts call the
instance metadata service (`169.254.169.254`, IMDSv2) to detect the region and IPs, so they
will fail on non-EC2 hosts.

## Table of Contents

1. [Script Inventory](#1-script-inventory)
2. [Two Ways to Run a Tier Script](#2-two-ways-to-run-a-tier-script)
3. [Parameter Reference](#3-parameter-reference)
4. [Step-by-Step by Scenario](#4-step-by-step-by-scenario)
5. [Verification](#5-verification)
6. [Re-running / Idempotency](#6-re-running--idempotency)
7. [Security Notes](#7-security-notes)
8. [Repo URL](#8-repo-url)

---

## 1. Script Inventory

| File | Tier | Purpose |
|---|---|---|
| `tier3-database.sh` | Tier 3 — Data | Installs PostgreSQL 15, creates the `bmi_user` role + `bmi_health` database, runs the schema migration, hardens `pg_hba.conf`/`postgresql.conf`. |
| `tier2-backend.sh` | Tier 2 — App | Installs Node.js 22 + PM2, clones the repo, installs backend deps, writes `.env`, starts `bmi-backend` under PM2. |
| `tier1-frontend.sh` | Tier 1 — Web | Installs Nginx (+ certbot if a domain is set), builds the React frontend, writes the Nginx config for `alb` / `public` / `public+domain` mode. In **single-server** mode (`-BackendHost=localhost` with `-DbPassword` set) it downloads and runs `tier3-database.sh` then `tier2-backend.sh` first, automatically. |
| `userdata-database-bootstrap.sh` | wrapper | Paste into EC2 User Data to run `tier3-database.sh` at first boot. |
| `userdata-backend-bootstrap.sh` | wrapper | Paste into EC2 User Data to run `tier2-backend.sh` at first boot. |
| `userdata-frontend-bootstrap.sh` | wrapper | Paste into EC2 User Data to run `tier1-frontend.sh` at first boot. |

Each `userdata-*-bootstrap.sh` is a thin wrapper: it has a `CONFIGURE HERE` block of plain
variables at the top, then downloads the matching `tierN-*.sh` from GitHub raw and executes it
with the equivalent `-Flag=value` arguments.

---

## 2. Two Ways to Run a Tier Script

### A) As EC2 User Data (fresh instance, recommended)

1. Open the matching `userdata-*-bootstrap.sh` in this folder.
2. Edit the variables in its `CONFIGURE HERE` block.
3. Paste the **entire file contents** into the EC2 launch wizard → *Advanced details* → *User data*.
4. Launch the instance — cloud-init runs the script automatically on first boot.

### B) Manually on an already-running Ubuntu instance (re-run, update, troubleshoot)

Connect via SSM Session Manager (or SSH), then download and run the tier script directly with
its native flags:

```bash
aws ssm start-session --target <instance-id>

# Tier 3 — Database
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/three-tier-aws-deployment/main/userdata-setup-scripts/tier3-database.sh -o /tmp/tier3-database.sh
chmod +x /tmp/tier3-database.sh
sudo bash /tmp/tier3-database.sh -Password="yourpassword"

# Tier 2 — Backend
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/three-tier-aws-deployment/main/userdata-setup-scripts/tier2-backend.sh -o /tmp/tier2-backend.sh
chmod +x /tmp/tier2-backend.sh
sudo bash /tmp/tier2-backend.sh -DbPassword="yourpassword" -DbHost="10.0.x.x" -FrontendUrl="http://<frontend-ip>"

# Tier 1 — Frontend
curl -fsSL https://raw.githubusercontent.com/sarowar-alam/three-tier-aws-deployment/main/userdata-setup-scripts/tier1-frontend.sh -o /tmp/tier1-frontend.sh
chmod +x /tmp/tier1-frontend.sh
sudo bash /tmp/tier1-frontend.sh -Mode=public -BackendHost="10.0.x.x"
```

Re-running a script on the same instance is safe — see [Re-running / Idempotency](#6-re-running--idempotency).

---

## 3. Parameter Reference

### `tier3-database.sh`

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `-Password` | No | *(none)* | `bmi_user` password. If omitted, the script fetches it from AWS SSM SecureString `/bmi/db-password` (requires an IAM instance profile with `ssm:GetParameter`). |

### `tier2-backend.sh`

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `-DbPassword` | **Yes** | — | Must match the password used for Tier 3. |
| `-DbHost` | **Yes** | — | Private IP/hostname of the Tier 3 DB server (or `localhost` for single-server). |
| `-FrontendUrl` | No | `*` | Origin allowed by CORS; set to the frontend's public IP/domain. |
| `-Port` | No | `3000` | API port. |

### `tier1-frontend.sh`

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `-Mode` | **Yes** | — | `alb` (ALB terminates HTTPS, Nginx stays HTTP:80) or `public` (direct access). |
| `-BackendHost` | No | `localhost` | Private IP of the Tier 2 backend, or `localhost` for single-server. |
| `-BackendPort` | No | `3000` | Backend API port. |
| `-Domain` | No | *(empty)* | Setting this triggers Let's Encrypt (certbot) in `public` mode. Requires a Route 53 A record already pointing at this instance's public IP. |
| `-CertEmail` | No | `admin@example.com` | Let's Encrypt registration email (used only when `-Domain` is set). |
| `-DbPassword` | No | *(empty)* | **Single-server only.** Non-empty + `-BackendHost=localhost` triggers automatic install of Tier 3 then Tier 2 on this same instance before the frontend build. Ignored if `-BackendHost` is not `localhost`. |

---

## 4. Step-by-Step by Scenario

Security group prerequisites match the root [README.md](../README.md#2-internal-architecture--communication):
DB SG allows `5432` from the Backend SG only; Backend SG allows `3000` from the Frontend SG
only; Frontend SG allows `80`/`443` from the ALB SG or the internet, depending on the case.

### Case 1 — Multi-server, private subnet + ALB

Launch **three** instances, in this order, in private subnets:

1. **DB instance** — bootstrap with `userdata-database-bootstrap.sh` (`DB_PASSWORD` set). Note its private IP.
2. **Backend instance** — bootstrap with `userdata-backend-bootstrap.sh`; set `DB_HOST` to the DB private IP and `FRONTEND_URL` to the domain the ALB will serve (e.g. `https://yourdomain.com`). Note its private IP.
3. **Frontend instance** — bootstrap with `userdata-frontend-bootstrap.sh`; set `MODE="alb"` and `BACKEND_HOST` to the backend private IP. Leave `DOMAIN` empty (the ALB terminates TLS, Nginx only needs HTTP:80).
4. Create the ALB/target group/ACM listener pointing at the frontend instance (see root README's [Case 1](../README.md#case-1--multi-server-private-subnet--alb) for the AWS CLI commands), then point DNS at the ALB.

### Case 2 — Multi-server, public IP, no domain

1. **DB instance** — `userdata-database-bootstrap.sh`, `DB_PASSWORD` set. Note private IP.
2. **Backend instance** — `userdata-backend-bootstrap.sh`, `DB_HOST` = DB private IP, `FRONTEND_URL` = `http://<frontend-public-ip>`. Note private IP.
3. **Frontend instance** — `userdata-frontend-bootstrap.sh`, `MODE="public"`, `BACKEND_HOST` = backend private IP, `DOMAIN=""`.

### Case 3 — Multi-server, public IP + domain

Same as Case 2 for the DB and Backend instances. For the Frontend instance, set
`MODE="public"`, `BACKEND_HOST` = backend private IP, and `DOMAIN="yourdomain.com"`
(`CERT_EMAIL` too) — a Route 53 A record must already point at the frontend's public IP
**before** launch, so certbot's HTTP-01 challenge can succeed.

### Case 4 — Single-server, private subnet + ALB

One instance, one bootstrap: `userdata-frontend-bootstrap.sh` with
`MODE="alb"`, `BACKEND_HOST="localhost"`, `DB_PASSWORD="yourpassword"`, `DOMAIN=""`.
`tier1-frontend.sh` automatically runs `tier3-database.sh` then `tier2-backend.sh` before
building the frontend. Create the ALB pointing at this instance (root README's
[Case 4](../README.md#case-4--single-server-private-subnet--alb)).

### Case 5 — Single-server, public IP, no domain

One instance, one bootstrap: `userdata-frontend-bootstrap.sh` with
`MODE="public"`, `BACKEND_HOST="localhost"`, `DB_PASSWORD="yourpassword"`, `DOMAIN=""`.

### Case 6 — Single-server, public IP + domain

Same as Case 5, plus `DOMAIN="yourdomain.com"` and `CERT_EMAIL` set. The Route 53 A record must
point at this instance's public IP before launch.

---

## 5. Verification

Each script writes a log file and a `.done` completion marker. After launch (or after a manual
run), connect via SSM and check:

**Tier 3 — Database**
```bash
cat /etc/bmi-db-setup.done
sudo tail -100 /var/log/bmi-db-setup.log
systemctl status postgresql@15-main.service
sudo -u postgres psql -d bmi_health -c '\dt'
ss -tlnp | grep 5432
```

**Tier 2 — Backend**
```bash
cat /etc/bmi-backend-setup.done
sudo tail -100 /var/log/bmi-backend-setup.log
sudo pm2 list --no-color
curl http://localhost:3000/health
curl http://localhost:3000/api/measurements?limit=1
sudo pm2 logs bmi-backend --lines 50 --nostream
```

**Tier 1 — Frontend**
```bash
cat /etc/bmi-frontend-setup.done
sudo tail -100 /var/log/bmi-frontend-setup.log
sudo systemctl status nginx
sudo nginx -t
curl -s -o /dev/null -w "%{http_code}" http://localhost/          # expect 200 (alb / public no-domain)
curl -s -o /dev/null -w "%{http_code}" https://yourdomain.com/    # expect 200 (public + domain)
curl http://localhost/api/measurements?limit=1
curl http://localhost/health
```

For single-server deployments, also check the DB and backend markers/PM2 on that same instance:
```bash
cat /etc/bmi-db-setup.done
cat /etc/bmi-backend-setup.done
sudo pm2 list
```

---

## 6. Re-running / Idempotency

All three tier scripts are safe to run more than once on the same instance:

- **Repo**: clones to `/opt/bmi-app` on first run; on subsequent runs it `git pull --ff-only` instead.
- **Tier 3**: the DB role is created with `CREATE ROLE ... IF NOT EXISTS` logic — if it already
  exists, its password is refreshed with `ALTER ROLE ... PASSWORD` instead. The database and
  schema migration use `IF NOT EXISTS`/`CREATE DATABASE ... WHERE NOT EXISTS`.
- **Tier 2**: if the PM2 process `bmi-backend` already exists, the script does `pm2 reload
  --update-env` instead of `pm2 start`.
- **Tier 1**: the Nginx config file and React `dist/` output are fully overwritten on every run.

This makes the manual re-run path (section [2B](#b-manually-on-an-already-running-ubuntu-instance-re-run-update-troubleshoot))
usable both to deploy app updates and to fix a misconfigured instance without terminating it.

---

## 7. Security Notes

- **User Data is not a secret store.** Any value pasted into `DB_PASSWORD` / `CERT_EMAIL` in a
  `userdata-*-bootstrap.sh` file is stored in plaintext as the instance's User Data attribute,
  readable by anyone in the account with `ec2:DescribeInstanceAttribute` permission.
- For `tier3-database.sh`, prefer leaving `-Password` **empty** and instead storing the password
  in AWS SSM Parameter Store as a SecureString at `/bmi/db-password`, with an IAM instance
  profile granting `ssm:GetParameter` — the script already falls back to this automatically.
- If you do paste a password into the EC2 console/User Data field for testing, rotate it
  afterwards.
- The backend's default CORS origin (`FRONTEND_URL="*"`) is permissive — always set it to the
  actual frontend origin (`http://<ip>` or `https://<domain>`) for production deployments.

---

## 8. Repo URL

All six scripts hardcode the source repo as:
```
https://github.com/sarowar-alam/three-tier-aws-deployment.git
https://raw.githubusercontent.com/sarowar-alam/three-tier-aws-deployment/main/userdata-setup-scripts/...
```
This already matches this repository's `origin` remote, so no changes are needed as-is. If you
fork this repository, update the URL consistently in **all six files**:
`tier1-frontend.sh`, `tier2-backend.sh`, `tier3-database.sh`, `userdata-frontend-bootstrap.sh`,
`userdata-backend-bootstrap.sh`, `userdata-database-bootstrap.sh`.
