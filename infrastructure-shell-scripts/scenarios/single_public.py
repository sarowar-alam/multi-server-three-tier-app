"""
Case 5: Single-server + public IP, no domain  →  http://PUBLIC_IP
Case 6: Single-server + public IP + domain    →  https://DOMAIN  (Let's Encrypt)

One EC2 in a public subnet runs all three tiers (DB + Backend + Frontend).
No ALB.  Route53 plain A record is created when --domain is given.
"""
import time
import config
from core.state import DeployState
from core.vpc import create_vpc_stack
from core.security_groups import create_sgs
from core.ec2 import launch_instance, wait_running, get_public_ip
from core import userdata, dns


def deploy(args, session, state: DeployState) -> None:
    ec2 = session.client("ec2")
    r53 = session.client("route53")
    dry = args.dry_run
    domain = args.domain or ""

    print("\n=== Single-server + public IP ===")
    print(f"  Domain    : {domain or '(none — plain HTTP)'}")
    print(f"  DB pass   : {'set' if args.db_password else 'NOT SET'}")
    print(f"  Instance  : {args.instance_type}")
    print()

    # ── Networking ────────────────────────────────────────────────────────────
    create_vpc_stack(ec2, state, with_nat=False, dry_run=dry)

    # ── Security group ────────────────────────────────────────────────────────
    create_sgs(ec2, state, is_multi=False, is_alb=False, dry_run=dry)

    # ── Build userdata ────────────────────────────────────────────────────────
    # FRONTEND_URL for backend CORS:
    #   - domain given → https://domain
    #   - no domain → wildcard (*); EC2 public IP not known yet at launch time
    cors_url = f"https://{domain}" if domain else "*"
    ud = userdata.render_frontend(
        mode="public",
        backend_host="localhost",
        domain=domain,
        cert_email=args.cert_email,
        db_password=args.db_password,
    )

    # ── Launch instance ───────────────────────────────────────────────────────
    state.instance_frontend = launch_instance(
        ec2, state,
        name="bmi-single",
        subnet_id=state.public_subnet_ids[0],
        sg_ids=[state.sg_frontend],
        userdata=ud,
        public_ip=True,
        instance_type=args.instance_type,
        key_name=args.key_name,
        dry_run=dry,
    )

    if not dry:
        wait_running(ec2, state.instance_frontend)
        public_ip = get_public_ip(ec2, state.instance_frontend)
        print(f"  [ec2] Public IP: {public_ip}")
    else:
        public_ip = "1.2.3.4"

    # ── Route53 A record (Let's Encrypt case) ─────────────────────────────────
    if domain:
        if not dry:
            dns.upsert_a_record(r53, domain, public_ip)
            state.route53_domain   = domain
            state.route53_is_alias = False
            print(f"  [dns] Waiting 30s for DNS propagation before certbot runs…")
            time.sleep(30)
        else:
            print(f"  [dns] [DRY RUN] Would create A record: {domain} → {public_ip}")
            state.route53_domain   = domain
            state.route53_is_alias = False
        state.access_url = f"https://{domain}"
    else:
        state.access_url = f"http://{public_ip}"
