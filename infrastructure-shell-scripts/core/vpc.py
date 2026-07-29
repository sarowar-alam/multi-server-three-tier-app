"""
VPC stack — creates full networking infrastructure for a deployment.

Public scenarios  (single-public, multi-public):
  VPC + public subnets + IGW only.  No NAT (instances get public IPs).

ALB scenarios     (single-alb, multi-alb):
  VPC + public subnets + private subnets + IGW + NAT Gateway.
  Private instances use NAT for outbound internet (apt, git, npm).
"""
import time
import config
from core.state import DeployState, make_tags, tag_spec


# ── helpers ───────────────────────────────────────────────────────────────────

def _tag(ec2, resource_id: str, scenario: str, name: str) -> None:
    ec2.create_tags(
        Resources=[resource_id],
        Tags=make_tags(scenario, name),
    )


def _log(msg: str) -> None:
    print(f"  [vpc] {msg}")


# ── create ────────────────────────────────────────────────────────────────────

def create_vpc_stack(ec2, state: DeployState, with_nat: bool = False, dry_run: bool = False) -> None:
    """
    Creates VPC, subnets, IGW, route tables, and optionally a NAT Gateway.
    All resource IDs are written to `state` in-place.
    """
    s = state.scenario
    prefix = "[DRY RUN] " if dry_run else ""

    # ── VPC ───────────────────────────────────────────────────────────────────
    _log(f"{prefix}Creating VPC ({config.VPC_CIDR})…")
    if not dry_run:
        vpc = ec2.create_vpc(
            CidrBlock=config.VPC_CIDR,
            TagSpecifications=tag_spec("vpc", s, "bmi-vpc"),
        )["Vpc"]
        state.vpc_id = vpc["VpcId"]
        ec2.modify_vpc_attribute(VpcId=state.vpc_id, EnableDnsSupport={"Value": True})
        ec2.modify_vpc_attribute(VpcId=state.vpc_id, EnableDnsHostnames={"Value": True})
        _log(f"VPC created: {state.vpc_id}")
    else:
        state.vpc_id = "vpc-dryrun"
        _log(f"Would create VPC 10.0.0.0/16")

    # ── Public subnets ────────────────────────────────────────────────────────
    _log(f"{prefix}Creating public subnets…")
    for cfg in config.PUBLIC_SUBNETS:
        if not dry_run:
            sn = ec2.create_subnet(
                VpcId=state.vpc_id,
                CidrBlock=cfg["cidr"],
                AvailabilityZone=cfg["az"],
                TagSpecifications=tag_spec("subnet", s, cfg["name"]),
            )["Subnet"]
            # Auto-assign public IP for instances launched in these subnets
            ec2.modify_subnet_attribute(
                SubnetId=sn["SubnetId"],
                MapPublicIpOnLaunch={"Value": True},
            )
            state.public_subnet_ids.append(sn["SubnetId"])
            _log(f"  Public subnet {cfg['cidr']} ({cfg['az']}): {sn['SubnetId']}")
        else:
            state.public_subnet_ids.append(f"subnet-pub-{cfg['az'][-2:]}-dryrun")
            _log(f"  Would create public subnet {cfg['cidr']} ({cfg['az']})")

    # ── Private subnets (ALB scenarios only) ──────────────────────────────────
    if with_nat:
        _log(f"{prefix}Creating private subnets…")
        for cfg in config.PRIVATE_SUBNETS:
            if not dry_run:
                sn = ec2.create_subnet(
                    VpcId=state.vpc_id,
                    CidrBlock=cfg["cidr"],
                    AvailabilityZone=cfg["az"],
                    TagSpecifications=tag_spec("subnet", s, cfg["name"]),
                )["Subnet"]
                state.private_subnet_ids.append(sn["SubnetId"])
                _log(f"  Private subnet {cfg['cidr']} ({cfg['az']}): {sn['SubnetId']}")
            else:
                state.private_subnet_ids.append(f"subnet-priv-{cfg['az'][-2:]}-dryrun")
                _log(f"  Would create private subnet {cfg['cidr']} ({cfg['az']})")

    # ── Internet Gateway ──────────────────────────────────────────────────────
    _log(f"{prefix}Creating Internet Gateway…")
    if not dry_run:
        igw = ec2.create_internet_gateway(
            TagSpecifications=tag_spec("internet-gateway", s, "bmi-igw"),
        )["InternetGateway"]
        state.igw_id = igw["InternetGatewayId"]
        ec2.attach_internet_gateway(InternetGatewayId=state.igw_id, VpcId=state.vpc_id)
        _log(f"IGW created + attached: {state.igw_id}")
    else:
        state.igw_id = "igw-dryrun"
        _log("Would create + attach Internet Gateway")

    # ── Public route table ────────────────────────────────────────────────────
    _log(f"{prefix}Creating public route table…")
    if not dry_run:
        rt = ec2.create_route_table(
            VpcId=state.vpc_id,
            TagSpecifications=tag_spec("route-table", s, "bmi-public-rt"),
        )["RouteTable"]
        state.public_rt_id = rt["RouteTableId"]
        ec2.create_route(
            RouteTableId=state.public_rt_id,
            DestinationCidrBlock="0.0.0.0/0",
            GatewayId=state.igw_id,
        )
        for subnet_id in state.public_subnet_ids:
            ec2.associate_route_table(RouteTableId=state.public_rt_id, SubnetId=subnet_id)
        _log(f"Public route table: {state.public_rt_id}")
    else:
        state.public_rt_id = "rtb-pub-dryrun"
        _log("Would create public route table (0.0.0.0/0 → IGW)")

    # ── NAT Gateway + private route table (ALB scenarios only) ───────────────
    if with_nat:
        _log(f"{prefix}Allocating Elastic IP for NAT Gateway…")
        if not dry_run:
            eip = ec2.allocate_address(Domain="vpc")
            state.nat_eip_alloc_id = eip["AllocationId"]
            _log(f"EIP allocated: {state.nat_eip_alloc_id}")

            _log("Creating NAT Gateway in first public subnet…")
            nat = ec2.create_nat_gateway(
                SubnetId=state.public_subnet_ids[0],
                AllocationId=state.nat_eip_alloc_id,
                TagSpecifications=tag_spec("natgateway", s, "bmi-nat-gw"),
            )["NatGateway"]
            state.nat_gw_id = nat["NatGatewayId"]
            _log(f"NAT GW created: {state.nat_gw_id} — waiting until available…")

            waiter = ec2.get_waiter("nat_gateway_available")
            waiter.wait(NatGatewayIds=[state.nat_gw_id],
                        WaiterConfig={"Delay": 15, "MaxAttempts": 40})
            _log(f"NAT GW available.")

            # Private route table
            prt = ec2.create_route_table(
                VpcId=state.vpc_id,
                TagSpecifications=tag_spec("route-table", s, "bmi-private-rt"),
            )["RouteTable"]
            state.private_rt_id = prt["RouteTableId"]
            ec2.create_route(
                RouteTableId=state.private_rt_id,
                DestinationCidrBlock="0.0.0.0/0",
                NatGatewayId=state.nat_gw_id,
            )
            for subnet_id in state.private_subnet_ids:
                ec2.associate_route_table(RouteTableId=state.private_rt_id, SubnetId=subnet_id)
            _log(f"Private route table: {state.private_rt_id}")
        else:
            state.nat_eip_alloc_id = "eipalloc-dryrun"
            state.nat_gw_id = "nat-dryrun"
            state.private_rt_id = "rtb-priv-dryrun"
            _log("Would create EIP + NAT GW + private route table (0.0.0.0/0 → NAT)")

    _log("VPC stack ready.")


# ── teardown ──────────────────────────────────────────────────────────────────

def teardown_vpc_stack(ec2, state: DeployState) -> None:
    """Tears down all VPC networking in safe reverse order."""
    from botocore.exceptions import ClientError

    def safe(fn, *a, not_found=(), **kw):
        try:
            fn(*a, **kw)
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code in not_found:
                _log(f"  Already gone ({code})")
            else:
                _log(f"  WARNING: {code} — {e.response['Error']['Message']}")

    # Route tables — disassociate and delete custom ones
    for rt_id in [state.private_rt_id, state.public_rt_id]:
        if not rt_id:
            continue
        try:
            assocs = ec2.describe_route_tables(RouteTableIds=[rt_id])["RouteTables"][0][
                "Associations"
            ]
            for a in assocs:
                if not a.get("Main"):
                    safe(
                        ec2.disassociate_route_table,
                        AssociationId=a["RouteTableAssociationId"],
                    )
            safe(
                ec2.delete_route_table,
                RouteTableId=rt_id,
                not_found=("InvalidRouteTableID.NotFound",),
            )
            _log(f"Route table deleted: {rt_id}")
        except ClientError as e:
            if e.response["Error"]["Code"] != "InvalidRouteTableID.NotFound":
                _log(f"  Route table {rt_id}: {e.response['Error']['Message']}")

    # NAT Gateway
    if state.nat_gw_id:
        _log(f"Deleting NAT Gateway {state.nat_gw_id}…")
        safe(
            ec2.delete_nat_gateway,
            NatGatewayId=state.nat_gw_id,
            not_found=("NatGatewayNotFound",),
        )
        _log("Waiting for NAT Gateway to be deleted…")
        for _ in range(40):
            try:
                gws = ec2.describe_nat_gateways(NatGatewayIds=[state.nat_gw_id])["NatGateways"]
                if not gws or gws[0]["State"] in ("deleted", "failed"):
                    break
            except ClientError:
                break
            time.sleep(15)
        _log("NAT Gateway deleted.")

    # Release EIP
    if state.nat_eip_alloc_id:
        safe(
            ec2.release_address,
            AllocationId=state.nat_eip_alloc_id,
            not_found=("InvalidAllocationID.NotFound",),
        )
        _log(f"EIP released: {state.nat_eip_alloc_id}")

    # Subnets
    for subnet_id in state.private_subnet_ids + state.public_subnet_ids:
        safe(
            ec2.delete_subnet,
            SubnetId=subnet_id,
            not_found=("InvalidSubnetID.NotFound",),
        )
        _log(f"Subnet deleted: {subnet_id}")

    # IGW — detach then delete
    if state.igw_id and state.vpc_id:
        safe(
            ec2.detach_internet_gateway,
            InternetGatewayId=state.igw_id,
            VpcId=state.vpc_id,
            not_found=("InvalidInternetGatewayID.NotFound",),
        )
        safe(
            ec2.delete_internet_gateway,
            InternetGatewayId=state.igw_id,
            not_found=("InvalidInternetGatewayID.NotFound",),
        )
        _log(f"IGW deleted: {state.igw_id}")

    # VPC
    if state.vpc_id:
        safe(
            ec2.delete_vpc,
            VpcId=state.vpc_id,
            not_found=("InvalidVpcID.NotFound",),
        )
        _log(f"VPC deleted: {state.vpc_id}")
