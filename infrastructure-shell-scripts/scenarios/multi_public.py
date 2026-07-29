"""
Case 2: Multi-server + public IPs, no domain  →  http://FRONTEND_IP
Case 3: Multi-server + public IPs + domain    →  https://DOMAIN  (Let's Encrypt)

Three separate EC2s, each in a public subnet:
  DB       → 5432 from backend SG only
  Backend  → 3000 from frontend SG only
  Frontend → 80 / 443 from internet

Launch order is sequential because each tier's IP feeds the next:
  DB → wait running → Backend (with DB private IP) → wait running → Frontend (with Backend private IP)
"""
import time
import config
from core.state import DeployState
from core.vpc import create_vpc_stack
from core.security_groups import create_sgs
from core.ec2 import launch_instance, wait_running, get_private_ip, get_public_ip
from core import userdata, dns


def deploy(args, session, state: DeployState) -> None:
    ec2 = session.client("ec2")
    r53 = session.client("route53")
    dry = args.dry_run
    domain = args.domain or ""

    print("\n=== Multi-server + public IPs ===")
    print(f"  Domain    : {domain or '(none — plain HTTP)'}")
    print(f"  DB pass   : {'set' if args.db_password else 'NOT SET'}")
    print(f"  Instance  : {args.instance_type}")
    print()

    # ── Networking (public subnets only, no NAT) ──────────────────────────────
    create_vpc_stack(ec2, state, with_nat=False, dry_run=dry)

    # ── Security groups ───────────────────────────────────────────────────────
    create_sgs(ec2, state, is_multi=True, is_alb=False, dry_run=dry)

    # ── [1/3] Launch DB ───────────────────────────────────────────────────────
    print("  [1/3] Launching Database tier…")
    state.instance_db = launch_instance(
        ec2, state,
        name="bmi-db",
        subnet_id=state.public_subnet_ids[0],
        sg_ids=[state.sg_db],
        userdata=userdata.render_database(args.db_password),
        public_ip=True,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_db)
        db_private_ip = get_private_ip(ec2, state.instance_db)
        print(f"  [ec2] DB private IP: {db_private_ip}")
    else:
        db_private_ip = "10.0.1.10"

    # ── [2/3] Launch Backend (needs DB IP) ────────────────────────────────────
    print("  [2/3] Launching Backend tier…")
    cors_url = f"https://{domain}" if domain else "*"
    state.instance_backend = launch_instance(
        ec2, state,
        name="bmi-backend",
        subnet_id=state.public_subnet_ids[0],
        sg_ids=[state.sg_backend],
        userdata=userdata.render_backend(
            db_host=db_private_ip,
            db_password=args.db_password,
            frontend_url=cors_url,
        ),
        public_ip=True,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_backend)
        backend_private_ip = get_private_ip(ec2, state.instance_backend)
        print(f"  [ec2] Backend private IP: {backend_private_ip}")
    else:
        backend_private_ip = "10.0.1.20"

    # ── [3/3] Launch Frontend (needs Backend IP) ──────────────────────────────
    print("  [3/3] Launching Frontend tier…")
    state.instance_frontend = launch_instance(
        ec2, state,
        name="bmi-frontend",
        subnet_id=state.public_subnet_ids[0],
        sg_ids=[state.sg_frontend],
        userdata=userdata.render_frontend(
            mode="public",
            backend_host=backend_private_ip,
            domain=domain,
            cert_email=args.cert_email,
        ),
        public_ip=True,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_frontend)
        frontend_public_ip = get_public_ip(ec2, state.instance_frontend)
        print(f"  [ec2] Frontend public IP: {frontend_public_ip}")
    else:
        frontend_public_ip = "13.0.0.1"

    # ── Route53 A record (Let's Encrypt case) ─────────────────────────────────
    if domain:
        if not dry:
            dns.upsert_a_record(r53, domain, frontend_public_ip)
            state.route53_domain   = domain
            state.route53_is_alias = False
            print(f"  [dns] Waiting 30s for DNS propagation before certbot runs…")
            time.sleep(30)
        else:
            print(f"  [dns] [DRY RUN] Would create A record: {domain} → {frontend_public_ip}")
            state.route53_domain   = domain
            state.route53_is_alias = False
        state.access_url = f"https://{domain}"
    else:
        state.access_url = f"http://{frontend_public_ip}"
