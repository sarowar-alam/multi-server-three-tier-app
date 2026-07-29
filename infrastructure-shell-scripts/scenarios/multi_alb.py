"""
Case 1: Multi-server + private subnets + ALB  →  https://bmi.ostaddevops.click
                                                  (ACM certificate on ALB)

Three EC2s in private subnets; ALB in public subnets terminates HTTPS.
Port 80 on the ALB redirects to 443.
Route53 alias A record → ALB DNS.

Launch order (each depends on the previous IP):
  DB → wait running → Backend (with DB private IP) → wait running → Frontend (with Backend private IP)
  → ALB → Route53
"""
import config
from core.state import DeployState
from core.vpc import create_vpc_stack
from core.security_groups import create_sgs
from core.ec2 import launch_instance, wait_running, get_private_ip
from core.alb import create_alb_stack
from core import userdata, dns


def deploy(args, session, state: DeployState) -> None:
    ec2   = session.client("ec2")
    elbv2 = session.client("elbv2")
    r53   = session.client("route53")
    dry   = args.dry_run
    domain = args.domain or config.DEFAULT_DOMAIN

    print("\n=== Multi-server + private subnets + ALB ===")
    print(f"  Domain    : {domain}")
    print(f"  ACM cert  : {config.ACM_CERT_ARN}")
    print(f"  DB pass   : {'set' if args.db_password else 'NOT SET'}")
    print(f"  Instance  : {args.instance_type}")
    print()

    # ── Networking (private subnets + NAT) ────────────────────────────────────
    create_vpc_stack(ec2, state, with_nat=True, dry_run=dry)

    # ── Security groups ───────────────────────────────────────────────────────
    create_sgs(ec2, state, is_multi=True, is_alb=True, dry_run=dry)

    # ── [1/3] Launch DB ───────────────────────────────────────────────────────
    print("  [1/3] Launching Database tier…")
    state.instance_db = launch_instance(
        ec2, state,
        name="bmi-db",
        subnet_id=state.private_subnet_ids[0],
        sg_ids=[state.sg_db],
        userdata=userdata.render_database(args.db_password),
        public_ip=False,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_db)
        db_private_ip = get_private_ip(ec2, state.instance_db)
        print(f"  [ec2] DB private IP: {db_private_ip}")
    else:
        db_private_ip = "10.0.11.10"

    # ── [2/3] Launch Backend (needs DB IP) ────────────────────────────────────
    print("  [2/3] Launching Backend tier…")
    state.instance_backend = launch_instance(
        ec2, state,
        name="bmi-backend",
        subnet_id=state.private_subnet_ids[0],
        sg_ids=[state.sg_backend],
        userdata=userdata.render_backend(
            db_host=db_private_ip,
            db_password=args.db_password,
            frontend_url=f"https://{domain}",   # CORS: ALB domain is known up-front
        ),
        public_ip=False,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_backend)
        backend_private_ip = get_private_ip(ec2, state.instance_backend)
        print(f"  [ec2] Backend private IP: {backend_private_ip}")
    else:
        backend_private_ip = "10.0.11.20"

    # ── [3/3] Launch Frontend (needs Backend IP) ──────────────────────────────
    print("  [3/3] Launching Frontend tier…")
    state.instance_frontend = launch_instance(
        ec2, state,
        name="bmi-frontend",
        subnet_id=state.private_subnet_ids[0],
        sg_ids=[state.sg_frontend],
        userdata=userdata.render_frontend(
            mode="alb",
            backend_host=backend_private_ip,
        ),
        public_ip=False,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_frontend)

    # ── ALB stack ─────────────────────────────────────────────────────────────
    create_alb_stack(
        elbv2, state,
        public_subnet_ids=state.public_subnet_ids,
        alb_sg_id=state.sg_alb,
        target_instance_id=state.instance_frontend,
        dry_run=dry,
    )

    # ── Route53 alias ─────────────────────────────────────────────────────────
    if not dry:
        dns.upsert_alias(r53, domain, state.alb_dns, state.alb_canonical_zone_id)
    else:
        print(f"  [dns] [DRY RUN] Would create alias: {domain} → ALB")

    state.route53_domain   = domain
    state.route53_is_alias = True
    state.access_url       = f"https://{domain}"
