# Three-Tier AWS Deployment — BMI Health Tracker

A BMI & health tracking app (React frontend, Node.js/Express backend, PostgreSQL database) built to demonstrate **one three-tier application deployed several different ways** on Ubuntu EC2 — same app, same tiers, same install logic, regardless of which automation method or server topology you choose.

This README generalizes the deployment process so you can reason about it independent of *how* you provision (shell / Python / Terraform) or *where* each tier lands (one server or three).

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

The tiers **never change**. What changes between scenarios is only:
1. **Topology** — do the 3 tiers live on 1 EC2 instance, or 3 separate EC2 instances?
2. **Access mode** — public IP direct, public IP + Let's Encrypt domain, or behind an ALB with ACM/HTTPS?
3. **Automation method** — manual raw commands, a Python/boto3 CLI, or Terraform.

---

## 2. Deployment Methods (pick one)

| Method | Directory | Best for |
|---|---|---|
| **A. Manual (raw commands)** | [backend/](backend/), [database/](database/), [frontend/](frontend/) | Learning exactly what each tier needs, full hands-on control |
| **B. Python (boto3) CLI** | [infrastructure-shell-scripts/](infrastructure-shell-scripts/) | Repeatable one-command deploy/teardown from your laptop |
| **C. Terraform** | [terraform/](terraform/) | Infrastructure-as-code, state tracking, team workflows |

> Methods B and C automate the *same* install steps shown manually in Section 5 below — VPC/EC2/ALB/Route53 provisioning plus the identical PostgreSQL, Node.js/PM2, and Nginx setup on each tier.

---

## 3. Topology (pick one)

Independent of the method above, choose how many EC2 instances host the 3 tiers:

### Single-server (all 3 tiers on 1 EC2 instance)
- One instance runs DB → Backend → Frontend, installed **in that order**, all pointing at `localhost`.
- Simplest to reason about; good for demos / low-traffic / cost-sensitive setups.

### Multi-server (1 EC2 instance per tier)
- Tier 3 (DB) and Tier 2 (Backend) typically sit in **private subnets**.
- Tier 1 (Frontend) is the only tier reachable from the internet (directly, or behind an ALB).
- Backend is configured to reach the DB's private IP; Frontend is configured to reach the Backend's private IP.

### Access mode (combine with either topology)
| Mode | How traffic reaches Tier 1 | TLS |
|---|---|---|
| Public IP (no domain) | Direct to EC2 public IP | None (plain HTTP) |
| Public IP + domain | Direct to EC2 public IP, Route53 A record → domain | Let's Encrypt (certbot) |
| ALB | Application Load Balancer in front of Tier 1 | ACM certificate on the ALB |

---

## 4. The Generalized Install Order (applies to every method/topology)

Regardless of manual / Python / Terraform, and regardless of 1 server or 3 servers, every deployment follows this same sequence:

1. **Tier 3 — Database**: Install PostgreSQL 15, create the `bmi_user` role + `bmi_health` database, apply the schema migration ([database/migrations/001_create_measurements.sql](database/migrations/001_create_measurements.sql)).
2. **Tier 2 — Backend**: Install Node.js 22 + PM2, install [backend/](backend/) dependencies, configure `DATABASE_URL` pointing at Tier 3, start the API under PM2.
3. **Tier 1 — Frontend**: Install Nginx (+certbot if using a domain), build [frontend/](frontend/) with Vite, deploy the static build, configure Nginx to reverse-proxy `/api/` to Tier 2.

In **single-server** mode all three run on one box against `localhost`. In **multi-server** mode each runs on its own instance, wired together via private IPs.

---

## 5. Method A — Manual Installation (Raw Commands, No Scripts)

This section assumes you only have the application source — [backend/](backend/), [database/](database/), [frontend/](frontend/) — and walks through installing all three tiers **by hand**, with no helper scripts.

### 5.0 Shared prerequisite: connect and get the code

Launch an Ubuntu 22.04/24.04 EC2 instance (one for single-server, three for multi-server) with an IAM instance profile that grants SSM access (`AmazonSSMManagedInstanceCore`), then connect without SSH keys:

```bash
aws ssm start-session --target <instance-id>
```

On each instance, pull the app source:

```bash
sudo apt-get update -y
sudo apt-get install -y git
sudo git clone https://github.com/sarowar-alam/three-tier-aws-deployment.git /opt/bmi-app
cd /opt/bmi-app
```

Only `backend/`, `database/`, `frontend/` are used below.

---

### 5.A Single-server walkthrough (all 3 tiers on 1 instance)

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

### 5.B Multi-server walkthrough (1 tier per instance)

Same commands as above, split across 3 instances, with these differences. Security groups must allow: DB SG accepts 5432 from Backend SG only; Backend SG accepts 3000 from Frontend SG only; Frontend SG accepts 80/443 from the internet (or from the ALB SG only).

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

### 5.C Optional: HTTPS via Let's Encrypt (either topology)

Only needed on the frontend instance, once the base HTTP setup above is working and a domain's DNS A record already points at it:

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d yourdomain.com --agree-tos -m you@example.com --redirect --non-interactive
```

### 5.D Prefer automation?

The exact steps above are also available as ready-to-run scripts in [userdata-setup-scripts/](userdata-setup-scripts/) (`tier1-frontend.sh`, `tier2-backend.sh`, `tier3-database.sh`) if you'd rather not type them by hand.

---

## 6. Method B — Python (boto3) CLI

Use [infrastructure-shell-scripts/deploy.py](infrastructure-shell-scripts/deploy.py) to create the full AWS stack (VPC, subnets, security groups, EC2 instances, optional ALB/Route53) and pass the same tier scripts as user-data automatically.

```bash
cd infrastructure-shell-scripts
pip install -r requirements.txt

# Single-server, public IP, no domain
python deploy.py --scenario single-public --db-password yourpass

# Single-server, private + ALB (HTTPS via ACM)
python deploy.py --scenario single-alb --db-password yourpass

# Multi-server, public IP, no domain
python deploy.py --scenario multi-public --db-password yourpass

# Multi-server, private + ALB (HTTPS via ACM)
python deploy.py --scenario multi-alb --db-password yourpass

# Add --domain + --cert-email to any "public" scenario for Let's Encrypt HTTPS
python deploy.py --scenario multi-public --db-password yourpass \
  --domain your.domain.com --cert-email you@example.com

# Preview only, zero AWS calls
python deploy.py --scenario single-public --db-password x --dry-run

# Tear down everything the last deploy created
python deploy.py --teardown
```

Config defaults (AWS profile, region, AMI, VPC CIDR, ACM/Route53 IDs) live in [infrastructure-shell-scripts/config.py](infrastructure-shell-scripts/config.py) — edit these for your own AWS account before running.

Scenario logic lives in [infrastructure-shell-scripts/scenarios/](infrastructure-shell-scripts/scenarios/); shared building blocks (VPC, security groups, ALB, DNS, EC2, teardown) live in [infrastructure-shell-scripts/core/](infrastructure-shell-scripts/core/).

---

## 7. Method C — Terraform

Use [terraform/](terraform/) for a declarative, state-tracked deployment. The directory mirrors the same 6 scenarios:

```
terraform/
  single-server/{alb,public-http,public-ssl}/   # all 3 tiers on 1 instance
  multi-server/{alb,public-http,public-ssl}/    # 1 instance per tier
  s3-backend-bootstrap/                          # optional: remote state bucket
```

```bash
cd terraform/single-server/public-http   # or any other scenario folder
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init
terraform plan
terraform apply
```

Each scenario's `userdata-*.tftpl` templates embed the same tier scripts (fetched from GitHub raw at boot) seen in [userdata-setup-scripts/](userdata-setup-scripts/) — Terraform just templates the parameters (`db_password`, `domain`, instance private IPs, etc.) into the user-data before passing it to the `aws_instance` resource.

```bash
terraform destroy   # tear down this scenario's resources
```

---

## 8. Choosing a Method + Topology

```mermaid
flowchart TD
    A["Want to learn every install step, by hand?"] -->|Yes| B["Method A: Manual raw commands"]
    A -->|No| C["Want a scriptable CLI you can re-run?"]
    C -->|Yes| D["Method B: Python/boto3"]
    C -->|No| E["Want IaC with state + team workflows?"]
    E -->|Yes| F["Method C: Terraform"]
    B --> G["1 EC2 or 3 EC2?"]
    D --> G
    F --> G
    G -->|1 EC2| H["Single-server scenario"]
    G -->|3 EC2| I["Multi-server scenario"]
    H --> J["Public IP or ALB?"]
    I --> J
```

---

## 9. Repository Structure

```
backend/                     Node.js/Express API source
frontend/                     React frontend source (deployed/live theme)
frontend_navy_sidebar/        Alternate UI theme (reference copy, not deployed)
frontend_clinical_minimal/    Alternate UI theme (reference copy, not deployed)
database/migrations/          SQL schema migrations, applied to Tier 3
userdata-setup-scripts/        Automated equivalent of Section 5's manual steps, run as EC2 user-data
infrastructure-shell-scripts/  Method B: Python/boto3 deploy + teardown CLI
terraform/                     Method C: Terraform modules for all 6 scenarios
```

---

## 10. Prerequisites (all methods)

- Ubuntu 22.04 or 24.04 LTS EC2 instances
- Outbound internet access (to clone GitHub, install packages, reach Let's Encrypt if used)
- An AWS account with permissions for EC2 / VPC / IAM (Methods B & C) or console/SSM access (Method A)
- A PostgreSQL password of your choosing, supplied consistently to Tier 2 and Tier 3

Whichever method or topology you pick, the app tiers, ports, install order, and verification steps are identical — only the provisioning mechanics differ.
