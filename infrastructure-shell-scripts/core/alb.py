"""
ALB stack — Application Load Balancer with:
  Listener 80  → HTTP 301 redirect to HTTPS:443
  Listener 443 → ACM certificate + forward to target group
  Health check → GET /health on port 80 (Nginx proxies to Node.js)
"""
import config
from core.state import DeployState, make_tags


def _log(msg: str) -> None:
    print(f"  [alb] {msg}")


def create_alb_stack(
    elbv2,
    state: DeployState,
    public_subnet_ids: list,
    alb_sg_id: str,
    target_instance_id: str,
    dry_run: bool = False,
) -> None:
    """
    Creates ALB, target group, registers instance, sets up listeners.
    Writes ARNs and DNS into state.
    """
    s = state.scenario
    tags = make_tags(s, "bmi-alb")

    if dry_run:
        state.alb_arn               = "arn:aws:elasticloadbalancing::dryrun/alb"
        state.alb_dns               = "bmi-alb-dryrun.elb.amazonaws.com"
        state.alb_canonical_zone_id = "ZDRYRUN"
        state.tg_arn                = "arn:aws:elasticloadbalancing::dryrun/tg"
        state.listener_80_arn       = "arn:aws:elasticloadbalancing::dryrun/listener-80"
        state.listener_443_arn      = "arn:aws:elasticloadbalancing::dryrun/listener-443"
        _log("[DRY RUN] Would create ALB, TG, redirect listener 80, HTTPS listener 443")
        return

    # ── Load Balancer ─────────────────────────────────────────────────────────
    _log("Creating Application Load Balancer…")
    alb = elbv2.create_load_balancer(
        Name="bmi-alb",
        Subnets=public_subnet_ids,
        SecurityGroups=[alb_sg_id],
        Scheme="internet-facing",
        Type="application",
        IpAddressType="ipv4",
        Tags=tags,
    )["LoadBalancers"][0]

    state.alb_arn               = alb["LoadBalancerArn"]
    state.alb_dns               = alb["DNSName"]
    state.alb_canonical_zone_id = alb["CanonicalHostedZoneId"]
    _log(f"ALB created: {state.alb_dns}")

    # ── Target Group ──────────────────────────────────────────────────────────
    _log("Creating target group…")
    tg = elbv2.create_target_group(
        Name="bmi-tg",
        Protocol="HTTP",
        Port=80,
        VpcId=state.vpc_id,
        HealthCheckProtocol="HTTP",
        HealthCheckPath="/health",
        HealthCheckIntervalSeconds=30,
        HealthCheckTimeoutSeconds=10,
        HealthyThresholdCount=2,
        UnhealthyThresholdCount=3,
        TargetType="instance",
        Tags=tags,
    )["TargetGroups"][0]
    state.tg_arn = tg["TargetGroupArn"]
    _log(f"Target group: {state.tg_arn}")

    # ── Register instance ─────────────────────────────────────────────────────
    _log(f"Registering instance {target_instance_id}…")
    elbv2.register_targets(
        TargetGroupArn=state.tg_arn,
        Targets=[{"Id": target_instance_id, "Port": 80}],
    )

    # ── Listener 443 (HTTPS + ACM cert → forward) ─────────────────────────────
    _log("Creating HTTPS:443 listener with ACM certificate…")
    l443 = elbv2.create_listener(
        LoadBalancerArn=state.alb_arn,
        Protocol="HTTPS",
        Port=443,
        SslPolicy="ELBSecurityPolicy-TLS13-1-2-2021-06",
        Certificates=[{"CertificateArn": config.ACM_CERT_ARN}],
        DefaultActions=[{
            "Type": "forward",
            "TargetGroupArn": state.tg_arn,
        }],
        Tags=make_tags(s, "bmi-listener-443"),
    )["Listeners"][0]
    state.listener_443_arn = l443["ListenerArn"]

    # ── Listener 80 (HTTP → redirect to HTTPS) ────────────────────────────────
    _log("Creating HTTP:80 listener (301 redirect to HTTPS)…")
    l80 = elbv2.create_listener(
        LoadBalancerArn=state.alb_arn,
        Protocol="HTTP",
        Port=80,
        DefaultActions=[{
            "Type": "redirect",
            "RedirectConfig": {
                "Protocol": "HTTPS",
                "Port": "443",
                "StatusCode": "HTTP_301",
            },
        }],
        Tags=make_tags(s, "bmi-listener-80"),
    )["Listeners"][0]
    state.listener_80_arn = l80["ListenerArn"]

    # ── Wait for ALB to be active ─────────────────────────────────────────────
    _log("Waiting for ALB to become active…")
    waiter = elbv2.get_waiter("load_balancer_available")
    waiter.wait(
        LoadBalancerArns=[state.alb_arn],
        WaiterConfig={"Delay": 15, "MaxAttempts": 40},
    )
    _log(f"ALB active: https://{state.alb_dns}")


def teardown_alb_stack(elbv2, state: DeployState) -> None:
    """Delete listeners → ALB → target group."""
    from botocore.exceptions import ClientError

    def safe(fn, *a, **kw):
        try:
            fn(*a, **kw)
        except ClientError as e:
            _log(f"  WARNING: {e.response['Error']['Message']}")

    for listener_arn in [state.listener_80_arn, state.listener_443_arn]:
        if listener_arn:
            safe(elbv2.delete_listener, ListenerArn=listener_arn)
            _log(f"Listener deleted: {listener_arn}")

    if state.alb_arn:
        safe(elbv2.delete_load_balancer, LoadBalancerArn=state.alb_arn)
        _log(f"ALB delete requested: {state.alb_arn}")
        _log("Waiting for ALB to be deleted…")
        try:
            waiter = elbv2.get_waiter("load_balancers_deleted")
            waiter.wait(
                LoadBalancerArns=[state.alb_arn],
                WaiterConfig={"Delay": 15, "MaxAttempts": 40},
            )
        except Exception:
            pass
        _log("ALB deleted.")

    if state.tg_arn:
        safe(elbv2.delete_target_group, TargetGroupArn=state.tg_arn)
        _log(f"Target group deleted: {state.tg_arn}")
