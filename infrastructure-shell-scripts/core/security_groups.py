"""
Security group factory — creates the right SGs for each scenario
and stores their IDs in DeployState.

Multi-server (public or ALB):
  sg_alb      — 80/443 from internet              (ALB only)
  sg_frontend — 80 from alb-sg or internet
  sg_backend  — 3000 from sg_frontend only
  sg_db       — 5432 from sg_backend only

Single-server (public or ALB):
  sg_alb      — 80/443 from internet              (ALB only)
  sg_frontend — 80[/443] from alb-sg or internet  (used for the combined instance)
"""
from botocore.exceptions import ClientError
from core.state import DeployState, tag_spec


def _log(msg: str) -> None:
    print(f"  [sg] {msg}")


def _create_sg(ec2, vpc_id: str, name: str, desc: str, scenario: str) -> str:
    sg = ec2.create_security_group(
        GroupName=name,
        Description=desc,
        VpcId=vpc_id,
        TagSpecifications=tag_spec("security-group", scenario, name),
    )
    sg_id = sg["GroupId"]
    # Remove the default "allow all outbound" rule — we add explicit egress below
    # Actually: keep default outbound (instances need internet for apt/npm/git)
    _log(f"SG created: {name} ({sg_id})")
    return sg_id


def _allow_ingress(ec2, sg_id: str, permissions: list) -> None:
    """Add ingress rules to a security group."""
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=permissions,
    )


def _ingress_cidr(protocol: str, port: int, cidr: str) -> dict:
    return {
        "IpProtocol": protocol,
        "FromPort": port,
        "ToPort": port,
        "IpRanges": [{"CidrIp": cidr, "Description": f"{protocol}/{port} from {cidr}"}],
    }


def _ingress_sg(protocol: str, port: int, source_sg_id: str, desc: str) -> dict:
    return {
        "IpProtocol": protocol,
        "FromPort": port,
        "ToPort": port,
        "UserIdGroupPairs": [{"GroupId": source_sg_id, "Description": desc}],
    }


# ── Public helpers ────────────────────────────────────────────────────────────

def _internet_http_https() -> list:
    return [
        _ingress_cidr("tcp", 80,  "0.0.0.0/0"),
        _ingress_cidr("tcp", 443, "0.0.0.0/0"),
    ]


# ── Main factory ──────────────────────────────────────────────────────────────

def create_sgs(ec2, state: DeployState, is_multi: bool, is_alb: bool, dry_run: bool = False) -> None:
    """
    Creates security groups for the given scenario and writes IDs into state.

    is_multi : True for multi-server (DB + Backend + Frontend), False for single-server
    is_alb   : True if traffic enters via ALB (frontend SG locks to ALB SG)
    """
    s = state.scenario
    vpc = state.vpc_id

    if dry_run:
        state.sg_alb      = "sg-alb-dryrun"
        state.sg_frontend = "sg-frontend-dryrun"
        state.sg_backend  = "sg-backend-dryrun"
        state.sg_db       = "sg-db-dryrun"
        _log(f"[DRY RUN] Would create SGs for scenario '{s}'")
        return

    # ── ALB SG (internet → ALB) ───────────────────────────────────────────────
    if is_alb:
        state.sg_alb = _create_sg(ec2, vpc, "bmi-alb-sg", "BMI ALB: 80/443 from internet", s)
        _allow_ingress(ec2, state.sg_alb, _internet_http_https())

    # ── Frontend / Single-server SG ───────────────────────────────────────────
    state.sg_frontend = _create_sg(ec2, vpc, "bmi-frontend-sg",
                                   "BMI Frontend/Single: 80[/443] inbound", s)
    if is_alb:
        # Only accept traffic from ALB SG
        _allow_ingress(ec2, state.sg_frontend, [
            _ingress_sg("tcp", 80, state.sg_alb, "HTTP from ALB"),
        ])
    else:
        # Public — accept from internet
        _allow_ingress(ec2, state.sg_frontend, _internet_http_https())

    # ── Backend SG (multi-server only) ────────────────────────────────────────
    if is_multi:
        state.sg_backend = _create_sg(ec2, vpc, "bmi-backend-sg",
                                      "BMI Backend: 3000 from frontend SG only", s)
        _allow_ingress(ec2, state.sg_backend, [
            _ingress_sg("tcp", 3000, state.sg_frontend, "API from frontend"),
        ])

    # ── DB SG (multi-server only) ─────────────────────────────────────────────
    if is_multi:
        state.sg_db = _create_sg(ec2, vpc, "bmi-db-sg",
                                 "BMI DB: 5432 from backend SG only", s)
        _allow_ingress(ec2, state.sg_db, [
            _ingress_sg("tcp", 5432, state.sg_backend, "Postgres from backend"),
        ])

    _log("All security groups ready.")


def teardown_sgs(ec2, state: DeployState) -> None:
    """Delete all security groups created for this deployment."""
    from botocore.exceptions import ClientError

    def safe_delete(sg_id: str) -> None:
        if not sg_id:
            return
        try:
            ec2.delete_security_group(GroupId=sg_id)
            _log(f"SG deleted: {sg_id}")
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code in ("InvalidGroupID.NotFound", "InvalidGroup.NotFound"):
                _log(f"SG already gone: {sg_id}")
            else:
                _log(f"WARNING deleting {sg_id}: {e.response['Error']['Message']}")

    # Delete in reverse dependency order
    for sg_id in [state.sg_db, state.sg_backend, state.sg_frontend, state.sg_alb]:
        safe_delete(sg_id)
