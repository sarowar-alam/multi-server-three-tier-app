"""
Teardown — destroys all resources recorded in deploy-state.json.
Deletion order is the strict reverse of creation to respect dependencies.
Each step is idempotent: missing resources are silently skipped.
"""
from core.state import DeployState
from core.ec2 import terminate_instances
from core.alb import teardown_alb_stack
from core.security_groups import teardown_sgs
from core.vpc import teardown_vpc_stack
from core import dns


def _log(msg: str) -> None:
    print(f"[teardown] {msg}")


def teardown_all(session, state: DeployState) -> None:
    ec2   = session.client("ec2")
    elbv2 = session.client("elbv2")
    r53   = session.client("route53")

    _log(f"Scenario : {state.scenario}")
    _log(f"Deployed : {state.deployed_at}")
    _log("")

    # ── 1. Route53 record ─────────────────────────────────────────────────────
    if state.route53_domain:
        _log(f"Step 1/9 — Deleting Route53 record: {state.route53_domain}")
        dns.delete_record(
            r53,
            domain=state.route53_domain,
            is_alias=state.route53_is_alias,
            ip=_get_frontend_ip(ec2, state),
            alb_dns=state.alb_dns,
            alb_canonical_zone_id=state.alb_canonical_zone_id,
        )
    else:
        _log("Step 1/9 — No Route53 record to delete.")

    # ── 2–3. ALB listeners + ALB + target group ───────────────────────────────
    if state.alb_arn:
        _log("Step 2/9 — Deleting ALB stack (listeners → ALB → target group)…")
        teardown_alb_stack(elbv2, state)
    else:
        _log("Step 2/9 — No ALB to delete.")

    # ── 4. EC2 instances ──────────────────────────────────────────────────────
    _log("Step 3/9 — Terminating EC2 instances…")
    terminate_instances(ec2, state)

    # ── 5. Security groups ────────────────────────────────────────────────────
    _log("Step 4/9 — Deleting security groups…")
    teardown_sgs(ec2, state)

    # ── 6–9. VPC networking ───────────────────────────────────────────────────
    _log("Step 5/9 — Tearing down VPC networking…")
    teardown_vpc_stack(ec2, state)

    _log("")
    _log("Teardown complete. All resources deleted.")
    _log(f"You may delete the state file manually: {state.scenario}")


def _get_frontend_ip(ec2, state: DeployState) -> str:
    """Try to retrieve the frontend instance's public IP (for Route53 plain A delete)."""
    instance_id = state.instance_frontend
    if not instance_id or instance_id.startswith("i-dryrun"):
        return ""
    try:
        from core.ec2 import get_public_ip
        return get_public_ip(ec2, instance_id)
    except Exception:
        return ""
