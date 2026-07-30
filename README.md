# Three-Tier AWS Deployment — BMI Health Tracker

## 1. What This App Is

A BMI & health tracking app split into three independent tiers:

| Tier | Component | Technology | Responsibility |
|---|---|---|---|
| **Tier 1 — Web** | Frontend | React (Vite build) served by Nginx | Renders the UI, calls the API for data |
| **Tier 2 — App** | Backend | Node.js 22 + Express, managed by PM2 | Business logic (BMI/BMR/calorie calculations), exposes a REST API |
| **Tier 3 — Data** | Database | PostgreSQL 15 | Stores user measurements (`measurements` table) |

Users enter weight/height/age/sex/activity level in the browser; the app calculates BMI, BMI category, BMR, and daily calorie needs, stores each measurement, and charts trends over time.

---

## 2. Internal Architecture & Communication

```mermaid
flowchart LR
    U["Browser"] -->|"HTTP/HTTPS :80 or :443"| T1["Tier 1: Nginx\n(serves React build)"]
    T1 -->|"reverse proxy\n/api/* and /health"| T2["Tier 2: Node.js/Express\n(PM2, port 3000)"]
    T2 -->|"postgresql:// (pg pool)\nport 5432"| T3["Tier 3: PostgreSQL\n(measurements table)"]
```

How the tiers talk to each other:
- **Browser → Tier 1**: The browser loads the static React app from Nginx and never talks to the backend or database directly.
- **Tier 1 → Tier 2**: Nginx reverse-proxies any request under `/api/` (and `/health`) to the Node.js backend on port `3000`. This is the *only* path the frontend ever uses to reach the backend — the React code just calls relative `/api/...` URLs.
- **Tier 2 → Tier 3**: The backend holds a connection pool (`pg`) to PostgreSQL, built from a single `DATABASE_URL` (`postgresql://bmi_user:<password>@<db-host>:5432/bmi_health`). All reads/writes to `measurements` go through this pool.
- **Isolation**: Tier 3 never talks to Tier 1 directly, and the browser never talks to Tier 2 or Tier 3 directly — every request is funneled through Nginx → backend → database, in that order.
- **Same-host vs different-host**: The *only* thing that changes between a single-server and a three-server layout is which hostname/IP each tier uses for the hop above (`localhost` vs. a private IP) — the request path itself never changes.

| Hop | Protocol | Port | Notes |
|---|---|---|---|
| Browser → Tier 1 | HTTP or HTTPS | 80 / 443 | HTTPS only if certbot/TLS is configured |
| Tier 1 → Tier 2 | HTTP (internal) | 3000 | Nginx `proxy_pass`, never exposed publicly |
| Tier 2 → Tier 3 | PostgreSQL wire protocol | 5432 | Restricted to the app tier via `pg_hba.conf` + security groups |

---

## 3. Manual Implementation Guideline

This guide assumes the git repository only contains three folders: `backend/`, `database/`, `frontend/`. No scripts or automation — every command below is run by hand.

### 3.0 Shared prerequisite: connect and clone

Launch Ubuntu 22.04/24.04 EC2 instance(s) — one instance for the single-server cases, three for the multi-server cases — then connect (e.g. via AWS SSM Session Manager: `aws ssm start-session --target <instance-id>`).

On each instance:

```bash
sudo apt-get update -y
sudo apt-get install -y git
sudo git clone https://github.com/sarowar-alam/three-tier-aws-deployment.git /opt/bmi-app
cd /opt/bmi-app
```

### 3.1 Pick a case

| Case | Topology | Access | TLS |
|---|---|---|---|
| [1](#case-1--multi-server--private-subnet--alb) | Multi-server | Behind an ALB, instances in private subnets | ACM cert on the ALB |
| [2](#case-2--multi-server--public-ip-no-domain) | Multi-server | Direct public IP | None (plain HTTP) |
| [3](#case-3--multi-server--public-ip--domain) | Multi-server | Direct public IP + domain | Let's Encrypt (certbot) |
| [4](#case-4--single-server--private-subnet--alb) | Single-server | Behind an ALB, instance in a private subnet | ACM cert on the ALB |
| [5](#case-5--single-server--public-ip-no-domain) | Single-server | Direct public IP | None (plain HTTP) |
| [6](#case-6--single-server--public-ip--domain) | Single-server | Direct public IP + domain | Let's Encrypt (certbot) |

---

### Case 1 — Multi-server, private subnet + ALB

Three instances (DB, Backend, Frontend) in private subnets, built **in that order**, with an Application Load Balancer (ALB) in front of the Frontend tier terminating TLS. Security groups: DB SG allows 5432 from Backend SG only; Backend SG allows 3000 from Frontend SG only; Frontend SG allows 80 from the ALB SG only (not the internet); ALB SG allows 443 (and optionally 80) from the internet.

**On the DB instance and Backend instance:** run exactly the same commands as [Case 2](#case-2--multi-server-public-ip-no-domain) below, except set `FRONTEND_URL` in the backend's `.env` to the domain the ALB will serve (e.g. `https://yourdomain.com`) instead of a public IP.

**On the Frontend instance:** same as Case 2's frontend steps, but the Nginx config stays **plain HTTP on port 80 only** — the ALB handles HTTPS, so no certbot is installed here:
```bash
BACKEND_HOST="<backend-private-ip>"

sudo apt-get install -y nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

sudo rm -f /etc/nginx/sites-enabled/default
cat <<NGINXEOF | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name _;
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://${BACKEND_HOST}:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
    location /health {
        proxy_pass http://${BACKEND_HOST}:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx
```
Verify locally on the instance: `curl http://localhost/api/measurements`.

**AWS-side: create the ALB (once, with the AWS CLI, requires an existing ACM certificate):**
```bash
VPC_ID="vpc-xxxxxxxx"
SUBNET_A="subnet-aaaaaaa"
SUBNET_B="subnet-bbbbbbb"
ALB_SG_ID="sg-xxxxxxxx"           # allows 443 (and 80) from the internet
ACM_CERT_ARN="arn:aws:acm:region:account-id:certificate/xxxxxxxx"

TG_ARN=$(aws elbv2 create-target-group \
  --name bmi-frontend-tg --protocol HTTP --port 80 \
  --vpc-id "${VPC_ID}" --target-type instance --health-check-path /health \
  --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 register-targets --target-group-arn "${TG_ARN}" --targets Id=<frontend-instance-id>

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name bmi-alb --type application --scheme internet-facing \
  --subnets "${SUBNET_A}" "${SUBNET_B}" --security-groups "${ALB_SG_ID}" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

aws elbv2 create-listener --load-balancer-arn "${ALB_ARN}" \
  --protocol HTTPS --port 443 --certificates CertificateArn="${ACM_CERT_ARN}" \
  --default-actions Type=forward,TargetGroupArn="${TG_ARN}"
```
Point your domain's DNS at the ALB's DNS name (`aws elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" --query "LoadBalancers[0].DNSName"`), e.g. a Route53 alias record. Verify: open `https://yourdomain.com/` in a browser.

---

### Case 2 — Multi-server, public IP, no domain

Three instances (DB, Backend, Frontend), built **in that order**. Security groups: DB SG allows 5432 from Backend SG only; Backend SG allows 3000 from Frontend SG only; Frontend SG allows 80 from the internet.

**On the DB instance:**
```bash
DB_PASS="ChangeMe123!"

sudo apt-get install -y gnupg curl lsb-release
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y
sudo apt-get install -y postgresql-15 postgresql-contrib-15
sudo systemctl enable --now postgresql

sudo -u postgres psql -c "CREATE ROLE bmi_user WITH LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE bmi_health OWNER bmi_user;"
sudo -u postgres psql -d bmi_health -f /opt/bmi-app/database/migrations/001_create_measurements.sql
sudo -u postgres psql -d bmi_health -c "GRANT SELECT, INSERT, UPDATE, DELETE ON measurements TO bmi_user;"
sudo -u postgres psql -d bmi_health -c "GRANT USAGE, SELECT ON SEQUENCE measurements_id_seq TO bmi_user;"

echo "host    bmi_health  bmi_user  <backend-private-ip>/32    scram-sha-256" | sudo tee -a /etc/postgresql/15/main/pg_hba.conf
sudo sed -i "s/^#*listen_addresses\s*=.*/listen_addresses = '*'/" /etc/postgresql/15/main/postgresql.conf
sudo systemctl restart postgresql
```
Note this instance's **private IP** — needed on the backend instance below.

**On the Backend instance:**
```bash
DB_PASS="ChangeMe123!"
DB_HOST="<db-private-ip>"

curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g pm2

cd /opt/bmi-app/backend
npm ci --omit=dev

cat <<EOF | sudo tee .env
PORT=3000
NODE_ENV=production
DATABASE_URL=postgresql://bmi_user:${DB_PASS}@${DB_HOST}:5432/bmi_health
FRONTEND_URL=http://<frontend-public-ip>
DB_POOL_SIZE=20
EOF

pm2 start src/server.js --name bmi-backend --env production
pm2 save
sudo env PATH="$PATH:/usr/bin" pm2 startup systemd -u root --hp /root
```
Verify: `curl http://localhost:3000/health`. Note this instance's **private IP** — needed on the frontend instance below.

**On the Frontend instance:**
```bash
BACKEND_HOST="<backend-private-ip>"

sudo apt-get install -y nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

sudo rm -f /etc/nginx/sites-enabled/default
cat <<NGINXEOF | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name _;
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://${BACKEND_HOST}:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
    location /health {
        proxy_pass http://${BACKEND_HOST}:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx
```
Verify: open `http://<frontend-public-ip>/` in a browser.

---

### Case 3 — Multi-server, public IP + domain

Same as **Case 2**, but a domain's DNS A record must already point at the frontend instance's public IP, and the frontend SG must also allow 443.

Run the **DB instance** and **Backend instance** steps exactly as in Case 2. For the **Frontend instance**, use this variant:

```bash
BACKEND_HOST="<backend-private-ip>"
DOMAIN="yourdomain.com"

sudo apt-get install -y nginx certbot python3-certbot-nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

sudo rm -f /etc/nginx/sites-enabled/default
cat <<NGINXEOF | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name ${DOMAIN};
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://${BACKEND_HOST}:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
    location /health {
        proxy_pass http://${BACKEND_HOST}:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx

sudo certbot --nginx -d "${DOMAIN}" --agree-tos -m you@example.com --redirect --non-interactive
```
Verify: open `https://yourdomain.com/` in a browser, and check `pm2 status` on the backend instance.

---

### Case 4 — Single-server, private subnet + ALB

All three tiers on one instance in a private subnet, with an ALB in front terminating TLS. Instance SG allows 80 from the ALB SG only (not the internet); ALB SG allows 443 (and optionally 80) from the internet.

Run **Step 1 — Database** and **Step 2 — Backend** exactly as in [Case 5](#case-5--single-server-public-ip-no-domain) below (set `FRONTEND_URL` in the backend `.env` to the domain the ALB will serve). For **Step 3 — Frontend**, keep Nginx **plain HTTP on port 80 only** — no certbot, the ALB handles HTTPS:
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
Verify locally on the instance: `curl http://localhost/api/measurements`.

**AWS-side: create the ALB (once, with the AWS CLI, requires an existing ACM certificate):**
```bash
VPC_ID="vpc-xxxxxxxx"
SUBNET_A="subnet-aaaaaaa"
SUBNET_B="subnet-bbbbbbb"
ALB_SG_ID="sg-xxxxxxxx"           # allows 443 (and 80) from the internet
ACM_CERT_ARN="arn:aws:acm:region:account-id:certificate/xxxxxxxx"

TG_ARN=$(aws elbv2 create-target-group \
  --name bmi-single-tg --protocol HTTP --port 80 \
  --vpc-id "${VPC_ID}" --target-type instance --health-check-path /health \
  --query "TargetGroups[0].TargetGroupArn" --output text)

aws elbv2 register-targets --target-group-arn "${TG_ARN}" --targets Id=<instance-id>

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name bmi-alb --type application --scheme internet-facing \
  --subnets "${SUBNET_A}" "${SUBNET_B}" --security-groups "${ALB_SG_ID}" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text)

aws elbv2 create-listener --load-balancer-arn "${ALB_ARN}" \
  --protocol HTTPS --port 443 --certificates CertificateArn="${ACM_CERT_ARN}" \
  --default-actions Type=forward,TargetGroupArn="${TG_ARN}"
```
Point your domain's DNS at the ALB's DNS name, e.g. a Route53 alias record. Verify: open `https://yourdomain.com/` in a browser.

---

### Case 5 — Single-server, public IP, no domain

All three tiers on one instance, plain HTTP.

**Step 1 — Database**
```bash
DB_PASS="ChangeMe123!"

sudo apt-get install -y gnupg curl lsb-release
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y
sudo apt-get install -y postgresql-15 postgresql-contrib-15
sudo systemctl enable --now postgresql

sudo -u postgres psql -c "CREATE ROLE bmi_user WITH LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE bmi_health OWNER bmi_user;"
sudo -u postgres psql -d bmi_health -f /opt/bmi-app/database/migrations/001_create_measurements.sql
sudo -u postgres psql -d bmi_health -c "GRANT SELECT, INSERT, UPDATE, DELETE ON measurements TO bmi_user;"
sudo -u postgres psql -d bmi_health -c "GRANT USAGE, SELECT ON SEQUENCE measurements_id_seq TO bmi_user;"

echo "host    bmi_health  bmi_user  127.0.0.1/32    scram-sha-256" | sudo tee -a /etc/postgresql/15/main/pg_hba.conf
sudo systemctl restart postgresql
```
Verify: `sudo -u postgres psql -d bmi_health -c "\dt"`

**Step 2 — Backend**
```bash
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
Verify: `curl http://localhost:3000/health`

**Step 3 — Frontend**
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
Verify: open `http://<instance-public-ip>/` in a browser.

---

### Case 6 — Single-server, public IP + domain

Identical to **Case 5**, but a domain's DNS A record must already point at this instance's public IP before the last step.

Run **Step 1 — Database** and **Step 2 — Backend** exactly as in Case 5. For **Step 3 — Frontend**, use this Nginx config instead (plain HTTP first, so certbot's ACME challenge can complete), then request the certificate:

```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

DOMAIN="yourdomain.com"

sudo rm -f /etc/nginx/sites-enabled/default
cat <<NGINXEOF | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name ${DOMAIN};
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
    location /health {
        proxy_pass http://localhost:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx

sudo certbot --nginx -d "${DOMAIN}" --agree-tos -m you@example.com --redirect --non-interactive
```
Certbot rewrites the Nginx config to listen on 443 with the certificate and redirects HTTP → HTTPS, and sets up auto-renewal. Verify: open `https://yourdomain.com/` in a browser.

---

### Case 2 — Multi-server, public IP, no domain

Three instances (DB, Backend, Frontend), built **in that order**. Security groups: DB SG allows 5432 from Backend SG only; Backend SG allows 3000 from Frontend SG only; Frontend SG allows 80 from the internet.

**On the DB instance:**
```bash
DB_PASS="ChangeMe123!"

sudo apt-get install -y gnupg curl lsb-release
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y
sudo apt-get install -y postgresql-15 postgresql-contrib-15
sudo systemctl enable --now postgresql

sudo -u postgres psql -c "CREATE ROLE bmi_user WITH LOGIN PASSWORD '${DB_PASS}';"
sudo -u postgres psql -c "CREATE DATABASE bmi_health OWNER bmi_user;"
sudo -u postgres psql -d bmi_health -f /opt/bmi-app/database/migrations/001_create_measurements.sql
sudo -u postgres psql -d bmi_health -c "GRANT SELECT, INSERT, UPDATE, DELETE ON measurements TO bmi_user;"
sudo -u postgres psql -d bmi_health -c "GRANT USAGE, SELECT ON SEQUENCE measurements_id_seq TO bmi_user;"

echo "host    bmi_health  bmi_user  <backend-private-ip>/32    scram-sha-256" | sudo tee -a /etc/postgresql/15/main/pg_hba.conf
sudo sed -i "s/^#*listen_addresses\s*=.*/listen_addresses = '*'/" /etc/postgresql/15/main/postgresql.conf
sudo systemctl restart postgresql
```
Note this instance's **private IP** — needed on the backend instance below.

**On the Backend instance:**
```bash
DB_PASS="ChangeMe123!"
DB_HOST="<db-private-ip>"

curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g pm2

cd /opt/bmi-app/backend
npm ci --omit=dev

cat <<EOF | sudo tee .env
PORT=3000
NODE_ENV=production
DATABASE_URL=postgresql://bmi_user:${DB_PASS}@${DB_HOST}:5432/bmi_health
FRONTEND_URL=http://<frontend-public-ip>
DB_POOL_SIZE=20
EOF

pm2 start src/server.js --name bmi-backend --env production
pm2 save
sudo env PATH="$PATH:/usr/bin" pm2 startup systemd -u root --hp /root
```
Verify: `curl http://localhost:3000/health`. Note this instance's **private IP** — needed on the frontend instance below.

**On the Frontend instance:**
```bash
BACKEND_HOST="<backend-private-ip>"

sudo apt-get install -y nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

sudo rm -f /etc/nginx/sites-enabled/default
cat <<NGINXEOF | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name _;
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://${BACKEND_HOST}:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
    location /health {
        proxy_pass http://${BACKEND_HOST}:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx
```
Verify: open `http://<frontend-public-ip>/` in a browser.

---

### Case 3 — Multi-server, public IP + domain

Same as **Case 2**, but a domain's DNS A record must already point at the frontend instance's public IP, and the frontend SG must also allow 443.

Run the **DB instance** and **Backend instance** steps exactly as in Case 2. For the **Frontend instance**, use this variant:

```bash
BACKEND_HOST="<backend-private-ip>"
DOMAIN="yourdomain.com"

sudo apt-get install -y nginx certbot python3-certbot-nginx

cd /opt/bmi-app/frontend
npm ci
npm run build

sudo mkdir -p /var/www/bmi-app/dist
sudo cp -r dist/. /var/www/bmi-app/dist/

sudo rm -f /etc/nginx/sites-enabled/default
cat <<NGINXEOF | sudo tee /etc/nginx/sites-available/bmi-app
server {
    listen 80 default_server;
    server_name ${DOMAIN};
    root  /var/www/bmi-app/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /api/ {
        proxy_pass         http://${BACKEND_HOST}:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
    location /health {
        proxy_pass http://${BACKEND_HOST}:3000/health;
    }
}
NGINXEOF

sudo ln -sf /etc/nginx/sites-available/bmi-app /etc/nginx/sites-enabled/bmi-app
sudo nginx -t
sudo systemctl restart nginx

sudo certbot --nginx -d "${DOMAIN}" --agree-tos -m you@example.com --redirect --non-interactive
```
Verify: open `https://yourdomain.com/` in a browser, and check `pm2 status` on the backend instance.

---

## 4. Repository Structure

```
backend/                     Node.js/Express API source
database/migrations/          SQL schema migrations, applied to Tier 3
frontend/                     React frontend source
```

## 5. Prerequisites

- Ubuntu 22.04 or 24.04 LTS EC2 instance(s)
- Outbound internet access (clone the repo, install packages, reach Let's Encrypt for Cases 3/6)
- Console/SSM access to each instance
- A PostgreSQL password of your choosing, used consistently across the Database and Backend steps
- For Cases 3/6: a domain name with its DNS A record already pointed at the relevant instance's public IP before running certbot
- For Cases 1/4 (ALB): an existing ACM certificate for your domain, a VPC with at least 2 subnets in different AZs, and AWS CLI access to create the target group, load balancer, and listener
