"""
Case 4: Single-server + private subnet + ALB  →  https://bmi.ostaddevops.click
                                                  (ACM certificate on ALB)

One EC2 in a private subnet runs all three tiers.
ALB in public subnets terminates HTTPS with the ACM certificate.
Port 80 on the ALB redirects to 443.
Route53 alias A record → ALB DNS.
"""
import config
from core.state import DeployState
from core.vpc import create_vpc_stack
from core.security_groups import create_sgs
from core.ec2 import launch_instance, wait_running
from core.alb import create_alb_stack
from core import userdata, dns


def deploy(args, session, state: DeployState) -> None:
    ec2   = session.client("ec2")
    elbv2 = session.client("elbv2")
    r53   = session.client("route53")
    dry   = args.dry_run
    domain = args.domain or config.DEFAULT_DOMAIN

    print("\n=== Single-server + private subnet + ALB ===")
    print(f"  Domain    : {domain}")
    print(f"  ACM cert  : {config.ACM_CERT_ARN}")
    print(f"  DB pass   : {'set' if args.db_password else 'NOT SET'}")
    print(f"  Instance  : {args.instance_type}")
    print()

    # ── Networking (private subnets + NAT required) ───────────────────────────
    create_vpc_stack(ec2, state, with_nat=True, dry_run=dry)

    # ── Security groups ───────────────────────────────────────────────────────
    create_sgs(ec2, state, is_multi=False, is_alb=True, dry_run=dry)

    # ── Userdata ──────────────────────────────────────────────────────────────
    # ALB mode: Nginx listens on HTTP:80 only; ALB handles HTTPS.
    # FRONTEND_URL for CORS → the public HTTPS domain.
    ud = userdata.render_frontend(
        mode="alb",
        backend_host="localhost",
        domain="",           # no Let's Encrypt needed — ALB handles SSL
        cert_email="",
        db_password=args.db_password,
    )

    # ── Launch instance (private subnet — no public IP) ───────────────────────
    state.instance_frontend = launch_instance(
        ec2, state,
        name="bmi-single",
        subnet_id=state.private_subnet_ids[0],
        sg_ids=[state.sg_frontend],
        userdata=ud,
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
