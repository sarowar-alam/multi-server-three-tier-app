# Three-Tier AWS Deployment — BMI Health Tracker

A BMI & health tracking app (React frontend, Node.js/Express backend, PostgreSQL database) deployed as a three-tier architecture on Ubuntu EC2.

This README gives a generalized, step-by-step manual installation guide — independent of *where* each tier lands (one server or three).

---

## 1. The Three Tiers

| Tier | Component | Technology | Port |
|---|---|---|---|
| **Tier 1 — Web** | React frontend (built static files) served by Nginx, reverse-proxies `/api` | Nginx + React (Vite build) | 80 / 443 |
| **Tier 2 — App** | REST API | Node.js 22 + Express + PM2 | 3000 |
| **Tier 3 — Data** | Relational database | PostgreSQL 15 | 5432 |

```mermaid
flowchart LR
    U["Client Browser"] --> T1["Tier 1: Nginx + React\n(port 80/443)"]
    T1 -->|"/api/* reverse proxy"| T2["Tier 2: Node.js + PM2\n(port 3000)"]
    T2 -->|"postgresql://"| T3["Tier 3: PostgreSQL 15\n(port 5432)"]
```

The tiers **never change**. What changes between scenarios is only the **topology** — do the 3 tiers live on 1 EC2 instance, or 3 separate EC2 instances?

---

## 2. Topology (pick one)

### Single-server (all 3 tiers on 1 EC2 instance)
- One instance runs DB → Backend → Frontend, installed **in that order**, all pointing at `localhost`.
- Simplest to reason about; good for demos / low-traffic / cost-sensitive setups.

### Multi-server (1 EC2 instance per tier)
- Tier 3 (DB) and Tier 2 (Backend) typically sit in **private subnets**.
- Tier 1 (Frontend) is the only tier reachable from the internet (directly, or behind a load balancer).
- Backend is configured to reach the DB's private IP; Frontend is configured to reach the Backend's private IP.

### Access mode (combine with either topology)
| Mode | How traffic reaches Tier 1 | TLS |
|---|---|---|
| Public IP (no domain) | Direct to EC2 public IP | None (plain HTTP) |
| Public IP + domain | Direct to EC2 public IP, DNS A record → domain | Let's Encrypt (certbot) |
| Load balancer | ALB/ELB in front of Tier 1 | ACM certificate on the load balancer |

---

## 3. The Generalized Install Order (applies to either topology)

Regardless of 1 server or 3 servers, every deployment follows this same sequence:

1. **Tier 3 — Database**: Install PostgreSQL 15, create the `bmi_user` role + `bmi_health` database, apply the schema migration ([database/migrations/001_create_measurements.sql](database/migrations/001_create_measurements.sql)).
2. **Tier 2 — Backend**: Install Node.js 22 + PM2, install [backend/](backend/) dependencies, configure `DATABASE_URL` pointing at Tier 3, start the API under PM2.
3. **Tier 1 — Frontend**: Install Nginx (+certbot if using a domain), build [frontend/](frontend/) with Vite, deploy the static build, configure Nginx to reverse-proxy `/api/` to Tier 2.

In **single-server** mode all three run on one box against `localhost`. In **multi-server** mode each runs on its own instance, wired together via private IPs.

---

## 4. Manual Installation (Raw Commands)

This section assumes you only have the application source — [backend/](backend/), [database/](database/), [frontend/](frontend/) — and walks through installing all three tiers **by hand**.

### 4.0 Shared prerequisite: connect and get the code

Launch an Ubuntu 22.04/24.04 EC2 instance (one for single-server, three for multi-server) with an IAM instance profile that grants SSM access (`AmazonSSMManagedInstanceCore`), then connect without SSH keys:

```bash
aws ssm start-session --target <instance-id>
```

On each instance, pull the app source:

```bash
sudo apt-get update -y
sudo apt-get install -y git
sudo git clone <your-repo-url> /opt/bmi-app
cd /opt/bmi-app
```

Only `backend/`, `database/`, `frontend/` are used below.

---

### 4.A Single-server walkthrough (all 3 tiers on 1 instance)

#### Step 1 — Database tier

```bash
DB_PASS="ChangeMe123!"

# Install PostgreSQL 15 from the official PGDG apt repo
sudo apt-get install -y gnupg curl lsb-release
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y
sudo apt-get install -y postgresql-15 postgresql-contrib-15
sudo systemctl enable --now postgresql

# Create role + database
sudo -u postgres psql -c "CREATE ROLE bmi_user WITH LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE bmi_health OWNER bmi_user;"

# Apply schema migration directly from the repo
sudo -u postgres psql -d bmi_health -f /opt/bmi-app/database/migrations/001_create_measurements.sql
sudo -u postgres psql -d bmi_health -c "GRANT SELECT, INSERT, UPDATE, DELETE ON measurements TO bmi_user;"
sudo -u postgres psql -d bmi_health -c "GRANT USAGE, SELECT ON SEQUENCE measurements_id_seq TO bmi_user;"

# Allow local TCP connections (Node.js on the same box)
echo "host    bmi_health  bmi_user  127.0.0.1/32    scram-sha-256" | sudo tee -a /etc/postgresql/15/main/pg_hba.conf
sudo systemctl restart postgresql
```

Verify: `sudo -u postgres psql -d bmi_health -c "\dt"` should list the `measurements` table.

#### Step 2 — Backend tier

```bash
# Node.js 22 LTS + PM2
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g pm2

cd /opt/bmi-app/backend
npm ci --omit=dev

cat <<EOF | sudo tee .env
PORT=3000
NODE_ENV=production
DATABASE_URL=postgresql://bmi_user:${DB_PASS}@localhost:5432/bmi_health
FRONTEND_URL=http://localhost
DB_POOL_SIZE=20
EOF

pm2 start src/server.js --name bmi-backend --env production
pm2 save
sudo env PATH="$PATH:/usr/bin" pm2 startup systemd -u root --hp /root
```

Verify: `curl http://localhost:3000/health` → `{"status":"ok"}`.

#### Step 3 — Frontend tier

```bash
sudo apt-get install -y nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

sudo rm -f /etc/nginx/sites-enabled/default
cat <<'NGINXEOF' | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name _;
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
    location /health {
        proxy_pass http://localhost:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx
```

Verify: open `http://<instance-public-ip>/` in a browser, and `curl http://localhost/api/measurements`.

---

### 4.B Multi-server walkthrough (1 tier per instance)

Same commands as above, split across 3 instances, with these differences. Security groups must allow: DB SG accepts 5432 from Backend SG only; Backend SG accepts 3000 from Frontend SG only; Frontend SG accepts 80/443 from the internet (or from the load balancer SG only).

#### DB instance
Run Step 1 exactly as above, but bind `pg_hba.conf` to the backend's private IP (or the VPC CIDR) instead of `127.0.0.1`, and allow Postgres to listen on all interfaces:

```bash
echo "host    bmi_health  bmi_user  <backend-private-ip>/32    scram-sha-256" | sudo tee -a /etc/postgresql/15/main/pg_hba.conf
sudo sed -i "s/^#*listen_addresses\s*=.*/listen_addresses = '*'/" /etc/postgresql/15/main/postgresql.conf
sudo systemctl restart postgresql
```

Note this instance's private IP — it's needed by the backend instance.

#### Backend instance
Run Step 2 exactly as above, but point `DATABASE_URL` at the DB instance's private IP instead of `localhost`:

```bash
DATABASE_URL=postgresql://bmi_user:${DB_PASS}@<db-private-ip>:5432/bmi_health
```

Note this instance's private IP — it's needed by the frontend instance.

Verify: `curl http://localhost:3000/health` on this instance.

#### Frontend instance
Run Step 3 exactly as above, but point the Nginx `proxy_pass` targets at the backend instance's private IP instead of `localhost`:

```nginx
location /api/ {
    proxy_pass http://<backend-private-ip>:3000;
    ...
}
location /health {
    proxy_pass http://<backend-private-ip>:3000/health;
}
```

Verify: open `http://<frontend-public-ip>/` in a browser.

---

### 4.C Optional: HTTPS via Let's Encrypt (either topology)

Only needed on the frontend instance, once the base HTTP setup above is working and a domain's DNS A record already points at it:

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com --agree-tos -m you@example.com --redirect --non-interactive
```

---

## 5. Repository Structure

```
backend/                     Node.js/Express API source
frontend/                     React frontend source (deployed/live theme)
frontend_navy_sidebar/        Alternate UI theme (reference copy, not deployed)
frontend_clinical_minimal/    Alternate UI theme (reference copy, not deployed)
database/migrations/          SQL schema migrations, applied to Tier 3
```

---

## 6. Prerequisites

- Ubuntu 22.04 or 24.04 LTS EC2 instances
- Outbound internet access (to clone the repo, install packages, reach Let's Encrypt if used)
- An AWS account with console/SSM access to the EC2 instance(s)
- A PostgreSQL password of your choosing, supplied consistently to Tier 2 and Tier 3

Whichever topology you pick, the app tiers, ports, install order, and verification steps are identical — only the wiring between tiers differs.
